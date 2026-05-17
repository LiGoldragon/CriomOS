{
  config,
  lib,
  pkgs,
  horizon,
  resolveSecret,
  criomos-lib,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;
  inherit (builtins)
    concatStringsSep
    elemAt
    filter
    head
    length
    map
    toString
    ;

  llamaCppPackage = pkgs.callPackage ../../packages/llama-cpp-strix-halo.nix { inherit pkgs; };

  nodeName = horizon.node.name;

  # Horizon selects provider profiles and serving nodes. CriomOS owns
  # the local llama catalog and runtime defaults.
  localLlamaCatalog = criomos-lib.catalogs.ai.localLlama;
  localLlamaDefaults = criomos-lib.constants.ai.localLlama;
  providers = horizon.cluster.aiProviders or [ ];

  enrichLocalLlamaProvider = provider: provider // {
    protocol = localLlamaDefaults.protocol;
    port = localLlamaCatalog.serverPort;
    basePath = localLlamaDefaults.basePath;
    models = localLlamaCatalog.models;
    servingConfig = {
      maxLoadedModels = localLlamaCatalog.router.modelsMax;
      idleUnloadSeconds = localLlamaCatalog.router.sleepIdleSeconds;
      gpuLayers = localLlamaCatalog.presetDefaults."n-gpu-layers";
      noMmap = localLlamaCatalog.presetDefaults."no-mmap";
      noWarmup = localLlamaCatalog.presetDefaults."no-warmup";
      fit = localLlamaCatalog.presetDefaults.fit;
      parallel = localLlamaCatalog.presetDefaults.parallel;
      gpuOverride = localLlamaDefaults.gpuOverride;
      memoryMaxGb = localLlamaDefaults.memoryMaxGb;
      memoryHighGb = localLlamaDefaults.memoryHighGb;
    };
  };

  # The provider hosted on THIS node. There must be exactly one for
  # this module to enable; if there are zero, the module is inert.
  ownProviders =
    map enrichLocalLlamaProvider (
      filter (p: p.servingNode == nodeName && p.profile == "CriomosLocalLlama") providers
    );
  ownProvider =
    if ownProviders == [ ] then null
    else if length ownProviders > 1 then
      throw "llm.nix: more than one AI provider serves on this node (${nodeName}); only one is supported"
    else
      head ownProviders;

  runtimeUser = "llama";
  runtimeHome = "/var/lib/llama";

  # SecretReference for the local serving endpoint's API key. Dispatch
  # through the cluster secret-binding resolver instead of reconstructing
  # the SOPS path locally. The binding table is the single place that
  # decides which backend owns a given secret name.
  #
  # `apiKey` is `Option<SecretReference>` on the schema — `null` for
  # endpoints that need no key (the canonical local llama.cpp router
  # being keyless today). When `null`, the llama-server is launched
  # without `--api-key-file` and `apiKeyFile` stays `null`.
  apiKeyRef =
    if ownProvider == null then null else ownProvider.apiKey or null;
  resolvedApiKey =
    if apiKeyRef == null then null else resolveSecret apiKeyRef;
  apiKeyFile =
    if resolvedApiKey == null then null else resolvedApiKey.runtimePath;

  # Resolve a model's source (from horizon's typed AiModelSource) to
  # a /nix/store path containing the GGUF file(s).
  mkModelStorePath =
    model:
    let
      source = model.source;
    in
    if source.kind == "multi-shard" then
      let
        fetched = map (shard: {
          drv = pkgs.fetchurl {
            url = shard.url;
            sha256 = shard.sha256;
          };
          inherit (shard) filename;
        }) source.shards;
      in
      pkgs.runCommand "model-${model.modelId}" { } (
        "mkdir -p $out\n"
        + concatStringsSep "\n" (map (s: "ln -s ${s.drv} $out/${s.filename}") fetched)
      )
    else if source.kind == "fetchurl" then
      let
        drv = pkgs.fetchurl {
          url = source.url;
          sha256 = source.sha256;
        };
      in
      pkgs.runCommand "model-${model.modelId}" { } ''
        mkdir -p $out
        ln -s ${drv} $out/${source.filename}
      ''
    else
      throw "llm.nix: model ${model.modelId} has unknown model source shape: ${builtins.toJSON source}";

  # Models directory: one subdirectory per model, named by id (the
  # llama.cpp router takes subdir name as model name).
  modelsDir =
    if ownProvider == null then null
    else pkgs.runCommand "llm-models-dir" { } (
      "mkdir -p $out\n"
      + concatStringsSep "\n" (
        map (model: "ln -s ${mkModelStorePath model} $out/${model.modelId}") ownProvider.models
      )
    );

  # presets.ini: global defaults from servingConfig + per-model overrides.
  globalPresetLines = sc: [
    "[*]"
    "n-gpu-layers = ${toString sc.gpuLayers}"
    "no-mmap = ${if sc.noMmap then "true" else "false"}"
    "no-warmup = ${if sc.noWarmup then "true" else "false"}"
    "fit = ${sc.fit}"
    "parallel = ${toString sc.parallel}"
    ""
  ];

  mkModelPresetLines = m:
    [
      "[${m.modelId}]"
      "ctx-size = ${toString m.ctxSize}"
    ]
    ++ lib.optional m.loadOnStartup "load-on-startup = true";

  presetsIni =
    if ownProvider == null then null
    else pkgs.writeText "llm-presets.ini" (
      concatStringsSep "\n" (globalPresetLines ownProvider.servingConfig)
      + concatStringsSep "\n\n" (map (m: concatStringsSep "\n" (mkModelPresetLines m)) ownProvider.models)
      + "\n"
    );

  # Pull the bare port off the provider for firewall + llama-server args.
  serverPort = if ownProvider == null then null else ownProvider.port;

  serviceName = "${nodeName}-llama-router";

  llamaStart =
    if ownProvider == null then null
    else
      let
        sc = ownProvider.servingConfig;
        apiKeyArg =
          if apiKeyFile == null then ""
          else "--api-key-file ${apiKeyFile} ";
      in
      pkgs.writeShellScript "llama-router-start" ''
        set -eu

        exec ${llamaCppPackage}/bin/llama-server \
          --host :: \
          --port ${toString serverPort} \
          ${apiKeyArg}\
          --models-dir ${modelsDir} \
          --models-preset ${presetsIni} \
          --models-max ${toString sc.maxLoadedModels} \
          --no-webui \
          --sleep-idle-seconds ${toString sc.idleUnloadSeconds}
      '';

in
{
  # sops options come from ./secrets.nix; declare the dependency
  # locally so the sops.secrets reference below resolves even when
  # this module is loaded in isolation (matches the shape network/
  # nordvpn.nix and router/default.nix already use).
  imports = [ ./secrets.nix ];

  config = mkIf (behavesAs.largeAi && ownProvider != null) (lib.mkMerge [
    (lib.mkIf (resolvedApiKey != null && resolvedApiKey.kind == "Sops") {
      sops.secrets.${resolvedApiKey.name} = resolvedApiKey.sopsConfig // {
        mode = "0400";
        owner = runtimeUser;
        restartUnits = [ "${serviceName}.service" ];
      };
    })
    {
      users.users.llama = {
        isSystemUser = true;
        description = "llama runtime user";
        home = runtimeHome;
        createHome = false;
        group = "llama";
        extraGroups = [
          "video"
          "render"
        ];
        password = "*";
      };
      users.groups.llama = { };

      networking.firewall.allowedTCPPorts = [ serverPort ];

      systemd.tmpfiles.rules = [
        "d /var/lib/llama 0755 llama llama - -"
      ];

      systemd.services.${serviceName} = {
        description = "${nodeName} llama.cpp router — multi-model on-demand serving (horizon-driven)";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        serviceConfig = {
          Type = "simple";
          User = runtimeUser;
          WorkingDirectory = runtimeHome;
          Environment = [
            "HOME=${runtimeHome}"
          ] ++ lib.optional (ownProvider.servingConfig.gpuOverride or null != null)
            "HSA_OVERRIDE_GFX_VERSION=${ownProvider.servingConfig.gpuOverride}";

          ExecStart = llamaStart;

          Restart = "on-failure";
          RestartSec = 5;
          StateDirectory = "llama";

          # Operating envelope from horizon — keeps llama from OOM-killing
          # system services (hostapd, SSH).
          MemoryMax = "${toString ownProvider.servingConfig.memoryMaxGb}G";
          MemoryHigh = "${toString ownProvider.servingConfig.memoryHighGb}G";
        };

        wantedBy = [ "multi-user.target" ];
      };
    }
  ]);
}
