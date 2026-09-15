{
  config,
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

  llamaCppPackage = pkgs.callPackage ../../packages/llama-cpp-strix-halo.nix { inherit pkgs; };

  nodeName = horizon.node.name;

  configPath = inputs.criomos-lib + "/data/largeAI/llm.json";
  cfg = fromJSON (readFile configPath);

  # Proposal-only catalog.  The external llm.json remains authoritative until
  # its owner opts into `enableProposalModels`; the default is false, so this
  # branch cannot fetch or start any of these weights.  Hashes are the Hub's
  # content hashes for the pinned files, not a permission to prefetch them.
  proposalModels = [
    {
      modelId = "laguna-s-2.1-ud-q4-k-m";
      descriptor = "Laguna S 2.1 UD-Q4_K_M (Prometheus proposal)";
      ctxSize = 262144;
      source = {
        kind = "multi-shard";
        shards = [
          { filename = "Laguna-S-2.1-UD-Q4_K_M-00001-of-00003.gguf"; url = "https://huggingface.co/unsloth/Laguna-S-2.1-GGUF/resolve/750f92f90cf54159c4d7a610cb7b3e74498e75c6/UD-Q4_K_M/Laguna-S-2.1-UD-Q4_K_M-00001-of-00003.gguf"; sha256 = "sha256-DPr0aRcmDSU3c+Xi+rZDKfpcnGD98NsPWfMSBbX13TI="; size = 3683648; }
          { filename = "Laguna-S-2.1-UD-Q4_K_M-00002-of-00003.gguf"; url = "https://huggingface.co/unsloth/Laguna-S-2.1-GGUF/resolve/750f92f90cf54159c4d7a610cb7b3e74498e75c6/UD-Q4_K_M/Laguna-S-2.1-UD-Q4_K_M-00002-of-00003.gguf"; sha256 = "sha256-lPB1d0ypk1X2FGrPYpL2ifvpLRrf0GBZ9uurwObrinE="; size = 49930584576; }
          { filename = "Laguna-S-2.1-UD-Q4_K_M-00003-of-00003.gguf"; url = "https://huggingface.co/unsloth/Laguna-S-2.1-GGUF/resolve/750f92f90cf54159c4d7a610cb7b3e74498e75c6/UD-Q4_K_M/Laguna-S-2.1-UD-Q4_K_M-00003-of-00003.gguf"; sha256 = "sha256-DXMLkZoFkXOQkfE1zeU8KGMcidAiFIJ3j2/HCjEB60k="; size = 23184915328; }
        ];
      };
    }
    {
      modelId = "qwen3.8-27b-q8-0";
      descriptor = "Qwen3.8 27B Q8_0 (Prometheus proposal)";
      ctxSize = 131072;
      source = {
        kind = "fetchurl";
        filename = "Qwen3.8-27B-Q8_0.gguf";
        url = "https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF/resolve/0669b98607d47046c7c2b3f801011d54a08cfccf/Qwen3.8-27B-Q8_0.gguf";
        sha256 = "sha256-9ccC2IINNvtVmFuyOPyD7joxPpIPS3UqQ3w6ap4U5Mg=";
        size = 28595763552;
      };
    }
    # Disabled: the requested Laguna XS Q8 revision and immutable file hash
    # were not verified in the bounded source lookup.
    {
      modelId = "laguna-s-2.1-xs-q8-disabled";
      descriptor = "Laguna S 2.1 XS Q8 (DISABLED: source revision unresolved)";
      disabled = true;
    }
    # Disabled: Ouranos' requested XS IQ4 source revision/hash is likewise
    # unresolved; keep the inventory visible without a fake fetcher.
    {
      modelId = "laguna-s-2.1-xs-iq4-disabled";
      descriptor = "Laguna S 2.1 XS IQ4 (DISABLED: source revision unresolved)";
      disabled = true;
    }
    # Disabled: no verified GGUF source was found for the requested Motif 2.
    {
      modelId = "motif-2-disabled";
      descriptor = "Motif 2 (DISABLED: verified GGUF source pending)";
      disabled = true;
    }
    # Motif 3 remains a living choice and is intentionally not enabled here;
    # llama.cpp support and a verified source are still open.
  ];

  modelCatalog = cfg.models ++ lib.optionals (cfg.enableProposalModels or false) (lib.filter (model: !(model.disabled or false)) proposalModels);

  serverPort = cfg.serverPort;

  runtimeUser = "llama";
  runtimeHome = "/var/lib/llama";
  apiKeyFile = config.sops.secrets.localLlmApiToken.path;

  # Resolve model source to a store path (file or directory of shards)
  mkModelStorePath =
    spec:
    let
      source = spec.source;
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
      pkgs.runCommand "model-${spec.modelId}" { } (
        "mkdir -p $out\n" + concatStringsSep "\n" (map (s: "ln -s ${s.drv} $out/${s.filename}") fetched)
      )
    else if source.kind == "fetchurl" then
      # Single-file model — place in a directory so router sees it by filename
      let
        drv = pkgs.fetchurl {
          url = source.url;
          sha256 = source.sha256;
        };
      in
      pkgs.runCommand "model-${spec.modelId}" { } ''
        mkdir -p $out
        ln -s ${drv} $out/${source.filename}
      ''
    else
      throw "Unknown source kind: ${source.kind}";

  # Vision projector (mmproj) for multimodal models — fetched as a
  # standalone file and referenced by absolute path in the model's
  # preset (`mmproj = <path>`), so the weights directory stays a clean
  # set of shards the router loads by name.
  mkMmprojFile =
    spec:
    pkgs.fetchurl {
      url = spec.mmproj.url;
      sha256 = spec.mmproj.sha256;
    };

  # Build the models-dir: a directory of subdirectories, one per model
  # Router mode uses subdirectory name as model name
  modelsDir = pkgs.runCommand "llm-models-dir" { } (
    "mkdir -p $out\n"
    + concatStringsSep "\n" (
      map (spec: "ln -s ${mkModelStorePath spec} $out/${spec.modelId}") modelCatalog
    )
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

  mkModelPreset =
    spec:
    let
      lines = [
        "[${spec.modelId}]"
        "ctx-size = ${toString spec.ctxSize}"
      ]
      ++ lib.optional (spec ? mmproj) "mmproj = ${mkMmprojFile spec}"
      ++ lib.optional (spec.loadOnStartup or false) "load-on-startup = true";
    in
    concatStringsSep "\n" lines + "\n";

  presetsIni = pkgs.writeText "llm-presets.ini" (
    globalPreset + concatStringsSep "\n" (map mkModelPreset modelCatalog)
  );

  serviceName = "${nodeName}-llama-router";

  llamaStart = pkgs.writeShellScript "llama-router-start" ''
    set -eu

    api_key_args=()
    if [ -s ${apiKeyFile} ]; then
      api_key_args=(--api-key-file ${apiKeyFile})
    fi

    exec ${llamaCppPackage}/bin/llama-server \
      --host :: \
      --port ${toString serverPort} \
      "''${api_key_args[@]}" \
      --models-dir ${modelsDir} \
      --models-preset ${presetsIni} \
      --models-max ${toString cfg.router.modelsMax} \
      --no-webui \
      ${lib.optionalString (
        cfg.router ? sleepIdleSeconds
      ) "--sleep-idle-seconds ${toString cfg.router.sleepIdleSeconds}"}
  '';

in
mkIf behavesAs.largeAi {
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

  # API token delivered via sops-nix: minted into gopass, encrypted to
  # this host's age key in the cluster secrets repository, decrypted to /run/secrets
  # only on activation. The llama runtime user reads it; the start
  # script passes it via --api-key-file when present.
  sops.secrets.localLlmApiToken = {
    format = "binary";
    sopsFile = inputs.secrets.sopsFiles.localLlmApiToken;
    owner = runtimeUser;
    mode = "0400";
    restartUnits = [ "${serviceName}.service" ];
  };

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

      ExecStart = llamaStart;

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
