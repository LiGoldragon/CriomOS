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
          cat > "$out/bin/${command}" <<'SCRIPT'
          #!${pkgs.runtimeShell}
          printf '%s\n' '${generation}:${command}'
          SCRIPT
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
  lojixConfiguration = selected: {
    services.lojix = {
      enable = true;
      daemonPackage = selected.daemon;
      ordinaryClientPackage = selected.ordinary;
      metaClientPackage = selected.meta;
      offlineToolsPackage = selected.offline;
      bootstrapPackage = selected.bootstrap;
      user = "lojix";
      group = "lojix";
      nexusHost = "lojix-command-boundary";
    };
  };
  configuration =
    selected: commandDirectoryPath:
    lib.nixosSystem {
      inherit system;
      modules = [
        ../../modules/nixos/lojix.nix
        (lojixConfiguration selected)
        {
          system.stateVersion = "26.05";
          users.groups.lojix = { };
          users.users.lojix = {
            isSystemUser = true;
            group = "lojix";
          };
          services.lojix = { inherit commandDirectoryPath; };
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
pkgs.testers.nixosTest {
  name = "lojix-command-boundary";
  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../../modules/nixos/lojix.nix ];
      system.stateVersion = "26.05";
      networking.hostName = "lojix-command-boundary";
      users.groups.lojix = { };
      users.users.lojix = {
        isSystemUser = true;
        group = "lojix";
      };
      services.lojix = (lojixConfiguration generationA).services.lojix;

      # The fixture executes the daemon launcher directly with the other seven.
      # Keeping the synthetic daemon out of the boot target avoids assigning it
      # a second service-lifecycle behavior solely for this proof.
      systemd.services.lojix.wantedBy = lib.mkForce [ ];

      specialisation."generation-b".configuration = {
        services.lojix = {
          daemonPackage = lib.mkForce generationB.daemon;
          ordinaryClientPackage = lib.mkForce generationB.ordinary;
          metaClientPackage = lib.mkForce generationB.meta;
          offlineToolsPackage = lib.mkForce generationB.offline;
          bootstrapPackage = lib.mkForce generationB.bootstrap;
        };
      };
    };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    commands = ${builtins.toJSON commandNames}
    selected_packages = ${builtins.toJSON (map toString selectedPackagePaths)}
    default_launcher = "${defaultLauncher}"
    custom_launcher = "${customLauncher}"
    custom_command_source = "${customCommandSource customConfigurationA}"

    for command in commands:
        machine.succeed(
            f"grep -F /etc/lojix/commands/{command} {default_launcher}/bin/{command}"
        )
        machine.succeed(
            f"grep -F /etc/lojix-selected/commands/{command} {custom_launcher}/bin/{command}"
        )
        assert machine.succeed(f"{custom_command_source}/{command}").strip() == f"a:{command}"
        for selected_package in selected_packages:
            machine.fail(f"grep -F {selected_package} {default_launcher}/bin/{command}")

    def observe(expected):
        command_directory = machine.succeed("readlink -f /etc/lojix/commands").strip()
        targets = {}
        outputs = {}
        for command in commands:
            launcher = machine.succeed(f"command -v {command}").strip()
            assert launcher == f"/run/current-system/sw/bin/{command}", (
                f"{command} resolved outside the active system PATH: {launcher!r}"
            )
            targets[command] = machine.succeed(
                f"readlink -f /etc/lojix/commands/{command}"
            ).strip()
            outputs[command] = machine.succeed(command).strip()
            assert outputs[command] == f"{expected}:{command}", (
                f"{command} executed the wrong generation: {outputs[command]!r}"
            )
        assert outputs["lojix"] == f"{expected}:lojix"
        assert outputs["lojix-meta"] == f"{expected}:lojix-meta"
        return command_directory, targets

    base_system = machine.succeed("readlink -f /run/current-system").strip()
    a_directory, a_targets = observe("a")

    generation_b = machine.succeed(
        "readlink -f /run/current-system/specialisation/generation-b"
    ).strip()
    machine.succeed(f"{generation_b}/bin/switch-to-configuration test")
    b_directory, b_targets = observe("b")
    assert b_directory != a_directory, "the real /etc command-directory link did not switch A to B"
    for command in commands:
        assert b_targets[command] != a_targets[command], (
            f"the real /etc target for {command} did not switch A to B"
        )

    machine.succeed(f"{base_system}/bin/switch-to-configuration test")
    rollback_directory, rollback_targets = observe("a")
    assert rollback_directory == a_directory, "the real /etc command-directory link did not roll back to A"
    assert rollback_targets == a_targets, "the eight real /etc targets did not roll back together"
  '';
}
