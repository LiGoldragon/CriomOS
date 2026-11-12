{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  commandNames = [
    "lojix"
    "lojix-meta"
    "lojix-nexus"
    "lojix-bootstrap"
    "lojix-write-configuration"
    "lojix-inspect-store"
    "lojix-reset-store"
    "lojix-migrate-configuration"
  ];
  makePackage =
    generation: role: commands:
    pkgs.runCommand "lojix-command-boundary-${generation}-${role}" { } (
      ''
        mkdir -p "$out/bin"
      ''
      + lib.concatStringsSep "\n" (
        map (command: ''
          cat > "$out/bin/${command}" <<'EOF'
          #!${pkgs.runtimeShell}
          printf '%s\n' '${generation}:${command}'
          EOF
          chmod +x "$out/bin/${command}"
        '') commands
      )
    );
  packages = generation: {
    daemon = makePackage generation "daemon" [ "lojix-nexus" ];
    ordinary = makePackage generation "ordinary" [ "lojix" ];
    meta = makePackage generation "meta" [ "lojix-meta" ];
    offline = makePackage generation "offline" [
      "lojix-write-configuration"
      "lojix-inspect-store"
      "lojix-reset-store"
      "lojix-migrate-configuration"
    ];
    bootstrap = makePackage generation "bootstrap" [ "lojix-bootstrap" ];
  };
  generationA = packages "a";
  generationB = packages "b";
  selectedPackagePaths = builtins.attrValues generationA ++ builtins.attrValues generationB;
  configuration =
    selected: commandDirectoryPath:
    lib.nixosSystem {
      inherit system;
      modules = [
        ../../modules/nixos/lojix.nix
        {
          system.stateVersion = "26.05";
          users.groups.lojix = { };
          users.users.lojix = {
            isSystemUser = true;
            group = "lojix";
          };
          services.lojix = {
            enable = true;
            daemonPackage = selected.daemon;
            ordinaryClientPackage = selected.ordinary;
            metaClientPackage = selected.meta;
            offlineToolsPackage = selected.offline;
            bootstrapPackage = selected.bootstrap;
            inherit commandDirectoryPath;
            user = "lojix";
            group = "lojix";
            nexusHost = "lojix-command-boundary";
          };
        }
      ];
    };
  defaultCommandDirectoryPath = "/etc/lojix/commands";
  customCommandDirectoryPath = "/etc/lojix-selected/commands";
  configurationA = configuration generationA defaultCommandDirectoryPath;
  configurationB = configuration generationB defaultCommandDirectoryPath;
  rollbackConfigurationA = configuration generationA defaultCommandDirectoryPath;
  customConfigurationA = configuration generationA customCommandDirectoryPath;
  invalidTraversalConfiguration = configuration generationA "/etc/lojix/../../tmp";
  invalidEmptyComponentConfiguration = configuration generationA "/etc/lojix//commands";
  invalidDotComponentConfiguration = configuration generationA "/etc/./lojix";
  commandSource = relativePath: evaluated: evaluated.config.environment.etc.${relativePath}.source;
  defaultCommandSource = commandSource "lojix/commands";
  customCommandSource = commandSource "lojix-selected/commands";
  systemPackages = evaluated: evaluated.config.environment.systemPackages;
  launcher =
    evaluated:
    lib.findFirst (package: lib.getName package == "lojix-command-launchers") null (
      systemPackages evaluated
    );
  defaultLauncher = launcher configurationA;
  customLauncher = launcher customConfigurationA;
  canonicalPathAssertionMessage = "services.lojix.commandDirectoryPath must name a canonical directory beneath /etc";
  rejectsInvalidPath =
    evaluated:
    builtins.any (
      assertion: !assertion.assertion && assertion.message == canonicalPathAssertionMessage
    ) evaluated.config.assertions;
in
assert defaultLauncher != null;
assert customLauncher != null;
assert systemPackages configurationA == systemPackages configurationB;
assert defaultCommandSource configurationA != defaultCommandSource configurationB;
assert defaultCommandSource configurationA == defaultCommandSource rollbackConfigurationA;
assert rejectsInvalidPath invalidTraversalConfiguration;
assert rejectsInvalidPath invalidEmptyComponentConfiguration;
assert rejectsInvalidPath invalidDotComponentConfiguration;
assert
  configurationA.config.systemd.services.lojix.serviceConfig.ExecStart
  == "${generationA.daemon}/bin/lojix-nexus";
assert
  configurationB.config.systemd.services.lojix.serviceConfig.ExecStart
  == "${generationB.daemon}/bin/lojix-nexus";
assert
  configurationA.config.systemd.services.lojix-reset-store.serviceConfig.ExecStart
  == "${generationA.offline}/bin/lojix-reset-store ResetStore";
assert
  configurationB.config.systemd.services.lojix-reset-store.serviceConfig.ExecStart
  == "${generationB.offline}/bin/lojix-reset-store ResetStore";
pkgs.runCommand "lojix-command-boundary"
  {
    inherit customLauncher defaultLauncher;
    commandSourceA = defaultCommandSource configurationA;
    commandSourceB = defaultCommandSource configurationB;
    customCommandSourceA = customCommandSource customConfigurationA;
  }
  ''
    set -eu

    for command in ${lib.concatMapStringsSep " " lib.escapeShellArg commandNames}; do
      test -x "$defaultLauncher/bin/$command"
      grep -F "/etc/lojix/commands/$command" "$defaultLauncher/bin/$command"
      grep -F "/etc/lojix-selected/commands/$command" "$customLauncher/bin/$command"
      test "$("$commandSourceA/$command")" = "a:$command"
      test "$("$commandSourceB/$command")" = "b:$command"
      test "$("$customCommandSourceA/$command")" = "a:$command"
      if grep -F -e "$commandSourceA" -e "$commandSourceB" "$defaultLauncher/bin/$command"; then
        echo "launcher embeds a selected command directory" >&2
        exit 1
      fi
      for selectedPackage in ${
        lib.concatMapStringsSep " " (package: lib.escapeShellArg "${package}") selectedPackagePaths
      }; do
        if grep -F "$selectedPackage" "$defaultLauncher/bin/$command"; then
          echo "launcher embeds a selected package" >&2
          exit 1
        fi
      done
      test "$(readlink "$commandSourceA/$command")" != "$(readlink "$commandSourceB/$command")"
    done

    test "$(readlink "$commandSourceA/lojix")" = ${lib.escapeShellArg "${generationA.ordinary}/bin/lojix"}
    test "$(readlink "$commandSourceA/lojix-meta")" = ${lib.escapeShellArg "${generationA.meta}/bin/lojix-meta"}
    test "$(readlink "$commandSourceB/lojix")" = ${lib.escapeShellArg "${generationB.ordinary}/bin/lojix"}
    test "$(readlink "$commandSourceB/lojix-meta")" = ${lib.escapeShellArg "${generationB.meta}/bin/lojix-meta"}
    touch "$out"
  ''
