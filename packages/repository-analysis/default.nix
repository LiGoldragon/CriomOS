{ inputs, system, ... }:
let
  source = inputs.repository-analysis-flow;
  context = source.inputs.base.lib.contexts.${system};
  inherit (context) pkgs toolchain;
  inherit (pkgs) lib;
  trial = builtins.fromJSON (builtins.readFile ./trial.json);
  crates = (import (source + "/Cargo.nix") { inherit pkgs; }).internal.crates;
  gitCrates = lib.filter (crate: crate ? src && crate.src ? rev) (lib.attrValues crates);
  vendor = (pkgs.rustPlatform.importCargoLock.override {
    fetchurl = arguments: pkgs.fetchurl (arguments // {
      name = lib.removePrefix "crate-" arguments.name;
    });
  }) {
    lockFile = source + "/Cargo.lock";
    outputHashes = lib.listToAttrs (map (crate: {
      name = "${crate.crateName}-${crate.version}";
      value = crate.src.outputHash;
    }) gitCrates);
  };
  configuration = pkgs.writeText "repository-analysis-config.json" (builtins.toJSON (
    trial.analysis // {
      cargo = trial.analysis.cargo // {
        buildScripts = trial.analysis.cargo.buildScripts // {
          # SCIP's loader requests build-script output independently of the
          # editor enable switch. An explicit empty successful producer keeps
          # this limited-coverage trial from compiling the workspace again.
          overrideCommand = [ "${pkgs.coreutils}/bin/true" ];
        };
      };
    }
  ));
in
assert lib.assertMsg (source.rev == trial.revision)
  "repository-analysis: the locked source must match trial.json's revision";
pkgs.runCommand "flow-semantic-index-${source.shortRev}"
  {
    nativeBuildInputs = [ toolchain pkgs.rust-analyzer-unwrapped pkgs.scip pkgs.time ];
    CARGO_NET_OFFLINE = "true";
    passthru = {
      inherit source vendor configuration;
      queryTools = [ pkgs.scip pkgs.jq ];
    };
  }
  ''
    export HOME="$NIX_BUILD_TOP/home" CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
    mkdir -p "$HOME" "$CARGO_HOME" "$out"
    substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" \
      --replace-fail 'directory = "cargo-vendor-dir"' 'directory = "${vendor}"'
    # The original checkout is immutable. Cargo reads a private writable
    # copy while all source and dependency identities remain declared inputs.
    cp -r ${source} "$NIX_BUILD_TOP/source"
    chmod -R u+w "$NIX_BUILD_TOP/source"
    cd "$NIX_BUILD_TOP/source"
    export CARGO_TARGET_DIR="$NIX_BUILD_TOP/compilation-refused"
    export RUST_SRC_PATH="${toolchain}/lib/rustlib/src/rust/library"
    # Compiler observation is permitted; code generation is not. Log every
    # invocation, including Cargo's version/print probes, and fail closed on
    # any invocation without a print-only or version request. Both RUSTC and
    # PATH point here so the metadata loader cannot bypass this evidence.
    mkdir "$NIX_BUILD_TOP/observed-toolchain"
    cat > "$NIX_BUILD_TOP/observed-toolchain/rustc" <<'GUARD'
    #!${pkgs.runtimeShell}
    printf '%q ' "$@" >> "$out/compiler-invocations.txt"
    printf '\n' >> "$out/compiler-invocations.txt"
    observation=false
    for argument in "$@"; do
      case "$argument" in
        --emit*|-o|--out-dir*) echo "Compilation refused" >&2; exit 1 ;;
        --print*|-vV|--version) observation=true ;;
      esac
    done
    if [ "$observation" != true ]; then
      echo "Compilation refused" >&2
      exit 1
    fi
    exec ${toolchain}/bin/rustc "$@"
    GUARD
    chmod +x "$NIX_BUILD_TOP/observed-toolchain/rustc"
    export out RUSTC="$NIX_BUILD_TOP/observed-toolchain/rustc"
    export PATH="$NIX_BUILD_TOP/observed-toolchain:$PATH"
    cp ${configuration} "$out/analysis.json"
    cp ${./trial.json} "$out/trial.json"
    rust-analyzer --version > "$out/analyzer-version.txt"
    rustc --version > "$out/toolchain-version.txt"
    cargo metadata --locked --offline --format-version 1 > "$out/metadata.json"
    printf '%s\n' "$CARGO_TARGET_DIR" > "$out/target-directory.txt"
    printf '%s\n' 'Build-script cfg/env/OUT_DIR and procedural-macro expansions are omitted.' \
      > "$out/coverage-limitations.txt"
    ${lib.getExe' pkgs.time "time"} -v -o "$out/index-time.txt" \
      rust-analyzer scip . --config-path ${configuration} \
      --num-threads ${toString trial.threads} --output "$out/index.scip" \
      ${lib.optionalString trial.excludeVendoredLibraries "--exclude-vendored-libraries"} \
      > "$out/index-stdout.txt" 2> "$out/index-stderr.txt"
    scip print --json "$out/index.scip" > "$out/index.json"
    scip stats --from "$out/index.scip" > "$out/index-stats.txt"
    # No source edit, lock rewrite or compilation is part of this derivation.
    cmp Cargo.lock ${source}/Cargo.lock
    test ! -d target
    test ! -d "$CARGO_TARGET_DIR"
  ''
