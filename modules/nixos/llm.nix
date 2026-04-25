{
  lib,
  pkgs,
  horizon,
  inputs,
  ...
}:
let
  inherit (lib) mkIf;
  inherit (horizon.node) behavesAs;
  inherit (builtins)
    concatStringsSep
    fromJSON
    map
    readFile
    toString
    ;

  llamaCppPackage = pkgs.callPackage ../../packages/llama-cpp-prometheus.nix { inherit pkgs; };

  nodeName = horizon.node.name;

  configPath = inputs.criomos-lib + "/data/largeAI/llm.json";
  cfg = fromJSON (readFile configPath);

  serverPort = cfg.serverPort;
  apiKey = cfg.apiKey;

  runtimeUser = "llama";
  runtimeHome = "/var/lib/llama";

  # Resolve model source to a store path (file or directory of shards)
  mkModelStorePath = spec:
    let source = spec.source; in
    if source.kind == "multi-shard"
    then
      let
        fetched = map (shard: {
          drv = pkgs.fetchurl { url = shard.url; sha256 = shard.sha256; };
          inherit (shard) filename;
        }) source.shards;
      in pkgs.runCommand "model-${spec.modelId}" {} (
        "mkdir -p $out\n"
        + concatStringsSep "\n" (map (s: "ln -s ${s.drv} $out/${s.filename}") fetched)
      )
    else if source.kind == "fetchurl"
    then
      # Single-file model — place in a directory so router sees it by filename
      let drv = pkgs.fetchurl { url = source.url; sha256 = source.sha256; }; in
      pkgs.runCommand "model-${spec.modelId}" {} ''
        mkdir -p $out
        ln -s ${drv} $out/${source.filename}
      ''
    else throw "Unknown source kind: ${source.kind}";

  # Build the models-dir: a directory of subdirectories, one per model
  # Router mode uses subdirectory name as model name
  modelsDir = pkgs.runCommand "llm-models-dir" {} (
    "mkdir -p $out\n"
    + concatStringsSep "\n" (map (spec:
      "ln -s ${mkModelStorePath spec} $out/${spec.modelId}"
    ) cfg.models)
  );

  # Generate presets.ini for per-model config
  presetDefaults = cfg.presetDefaults;

  globalPreset = concatStringsSep "\n" [
    "[*]"
    "n-gpu-layers = ${toString (presetDefaults."n-gpu-layers" or 99)}"
    "no-mmap = ${if presetDefaults."no-mmap" or true then "true" else "false"}"
    "no-warmup = ${if presetDefaults."no-warmup" or true then "true" else "false"}"
    "fit = ${presetDefaults.fit or "off"}"
    "parallel = ${toString (presetDefaults.parallel or 1)}"
    ""
  ];

  mkModelPreset = spec:
    let
      lines = [
        "[${spec.modelId}]"
        "ctx-size = ${toString spec.ctxSize}"
      ] ++ lib.optional (spec.loadOnStartup or false) "load-on-startup = true";
    in concatStringsSep "\n" lines + "\n";

  presetsIni = pkgs.writeText "llm-presets.ini" (
    globalPreset
    + concatStringsSep "\n" (map mkModelPreset cfg.models)
  );

  serviceName = "${nodeName}-llama-router";

in
mkIf behavesAs.largeAi {
  users.users.llama = {
    isSystemUser = true;
    description = "llama runtime user";
    home = runtimeHome;
    createHome = false;
    group = "llama";
    extraGroups = [ "video" "render" ];
    password = "*";
  };
  users.groups.llama = {};

  networking.firewall.allowedTCPPorts = [ serverPort ];

  systemd.tmpfiles.rules = [
    "d /var/lib/llama 0755 llama llama - -"
  ];

  systemd.services.${serviceName} = {
    description = "${nodeName} llama.cpp router — multi-model on-demand serving";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = runtimeUser;
      WorkingDirectory = runtimeHome;
      Environment = [
        "HOME=${runtimeHome}"
        "HSA_OVERRIDE_GFX_VERSION=11.5.1"
      ];

      ExecStart = concatStringsSep " " ([
        "${llamaCppPackage}/bin/llama-server"
        "--host ::"
        "--port ${toString serverPort}"
        "--api-key ${apiKey}"
        "--models-dir ${modelsDir}"
        "--models-preset ${presetsIni}"
        "--models-max ${toString cfg.router.modelsMax}"
        "--no-webui"
      ] ++ lib.optional (cfg.router ? sleepIdleSeconds) "--sleep-idle-seconds ${toString cfg.router.sleepIdleSeconds}");

      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "llama";

      # Prevent OOM from killing system services (hostapd, SSH)
      MemoryMax = "110G";
      MemoryHigh = "100G";
    };

    wantedBy = [ "multi-user.target" ];
  };
}
