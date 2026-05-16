{
  config,
  lib,
  pkgs,
  inputs,
  horizon,
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

  # Step 6: every server-side AI provisioning field comes from
  # horizon. The previous module read from CriomOS-lib's largeAI/llm.json
  # (serverPort, models[].source/sha256/ctxSize/loadOnStartup,
  # presetDefaults, router{modelsMax,sleepIdleSeconds}). All of that
  # now lives on horizon.cluster.aiProviders[<name>].models[i].serving
  # (per-model: source + runtime_context_size + load_on_startup) and
  # .serving_config (per-provider router defaults). llm.json is deleted.
  providers = horizon.cluster.aiProviders or [ ];

  # The provider hosted on THIS node. There must be exactly one for
  # this module to enable; if there are zero, the module is inert.
  ownProviders =
    filter (p: p.servingNode == nodeName && p.servingConfig != null) providers;
  ownProvider =
    if ownProviders == [ ] then null
    else if length ownProviders > 1 then
      throw "llm.nix: more than one AI provider serves on this node (${nodeName}); only one is supported"
    else
      head ownProviders;

  # When a provider is hosted here, every one of its models must have
  # a `serving` (source + runtime_context_size + load_on_startup) so
  # the server can fetch and configure them.
  requireServing = model:
    if model.serving == null then
      throw "llm.nix: model ${model.id} on provider ${ownProvider.name} (servingNode=${nodeName}) has serving=null; locally-served models require a serving record"
    else
      model.serving;

  runtimeUser = "llama";
  runtimeHome = "/var/lib/llama";

  # SecretReference for the local serving endpoint's API key. Resolved
  # through the same sops infrastructure that wires nordvpn-credentials
  # and the router Wi-Fi password: `inputs.secrets.sopsFiles.<name>` is
  # staged from the cluster repo's secrets/ directory and decrypted at
  # activation time by sops-install-secrets; the runtime path lives at
  # /run/secrets/<name>.
  #
  # `apiKey` is `Option<SecretReference>` on the schema — `null` for
  # endpoints that need no key (the canonical local llama.cpp router
  # being keyless today). When `null`, the llama-server is launched
  # without `--api-key-file` and `apiKeyFile` stays `null`.
  apiKeyRef =
    if ownProvider == null then null else ownProvider.apiKey or null;
  apiKeyName =
    if apiKeyRef == null then null else apiKeyRef.name;
  sopsFiles = inputs.secrets.sopsFiles or { };
  apiKeySopsFile =
    if apiKeyName == null then null
    else sopsFiles.${apiKeyName} or null;
  apiKeyFile =
    if apiKeyName == null then null
    else config.sops.secrets.${apiKeyName}.path;

  # Loud-fail when the provider authors an apiKey SecretReference but
  # no encrypted credential is staged in the secrets input. Matches the
  # nordvpn.nix shape for symmetric operator-friendly errors.
  apiKeyMissingSops =
    apiKeyRef != null && apiKeySopsFile == null;

  # Resolve a model's source (from horizon's typed AiModelSource) to
  # a /nix/store path containing the GGUF file(s).
  mkModelStorePath =
    model:
    let
      serving = requireServing model;
      source = serving.source;
    in
    if source ? AiModelMultiShard then
      let
        fetched = map (shard: {
          drv = pkgs.fetchurl {
            url = shard.url;
            sha256 = shard.sha256;
          };
          inherit (shard) filename;
        }) source.AiModelMultiShard.shards;
      in
      pkgs.runCommand "model-${model.id}" { } (
        "mkdir -p $out\n"
        + concatStringsSep "\n" (map (s: "ln -s ${s.drv} $out/${s.filename}") fetched)
      )
    else if source ? AiModelFetchurl then
      let
        single = source.AiModelFetchurl;
        drv = pkgs.fetchurl {
          url = single.url;
          sha256 = single.sha256;
        };
      in
      pkgs.runCommand "model-${model.id}" { } ''
        mkdir -p $out
        ln -s ${drv} $out/${single.filename}
      ''
    else
      throw "llm.nix: model ${model.id} has unknown AiModelSource shape: ${builtins.toJSON source}";

  # Models directory: one subdirectory per model, named by id (the
  # llama.cpp router takes subdir name as model name).
  modelsDir =
    if ownProvider == null then null
    else pkgs.runCommand "llm-models-dir" { } (
      "mkdir -p $out\n"
      + concatStringsSep "\n" (
        map (m: "ln -s ${mkModelStorePath m} $out/${m.id}") ownProvider.models
      )
    );

  # presets.ini: global defaults from servingConfig + per-model overrides.
  globalPresetLines = sc: [
    "[*]"
    "n-gpu-layers = ${toString sc.gpuLayers}"
    "no-mmap = ${if sc.noMmap then "true" else "false"}"
    "no-warmup = ${if sc.noWarmup then "true" else "false"}"
    "fit = ${if sc.fit == "On" then "on" else "off"}"
    "parallel = ${toString sc.parallel}"
    ""
  ];

  mkModelPresetLines = m:
    let serving = requireServing m; in
    [
      "[${m.id}]"
      "ctx-size = ${toString serving.runtimeContextSize}"
    ]
    ++ lib.optional serving.loadOnStartup "load-on-startup = true";

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
    {
      assertions = [
        {
          assertion = !apiKeyMissingSops;
          message = "llm.nix: provider ${ownProvider.name}.apiKey.name=${apiKeyName} but inputs.secrets.sopsFiles.${apiKeyName} is missing (no encrypted credential staged from the cluster repo's secrets/)";
        }
      ];
    }
    (lib.mkIf (apiKeyName != null && apiKeySopsFile != null) {
      sops.secrets.${apiKeyName} = {
        format = "binary";
        sopsFile = apiKeySopsFile;
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
