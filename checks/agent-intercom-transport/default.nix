{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  homeInput = {
    packages = {
      ${system}.agent-intercom = pkgs.hello;
    };
  };

  node = name: services: {
    inherit name services;
    adminSshPubKeys = [ ];
    behavesAs.edge = false;
  };
  localUser = {
    name = "intercom-user";
    trust = {
      min = true;
      medium = false;
    };
    sshPubKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA" ];
    extraGroups = [ ];
    enableLinger = false;
  };

  configurationFor =
    horizon:
    (lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit horizon;
        inputs = inputs // {
          criomos-home = homeInput;
        };
      };
      modules = [
        ../../modules/nixos/users.nix
        ../../modules/nixos/agent-intercom.nix
        {
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          boot.loader.grub.devices = [ "/dev/vda" ];
        }
      ];
    }).config;

  local = node "local" [ { AgentIntercomLocal = { }; } ];
  graphical = node "graphical" [
    { AgentIntercomLocal = { }; }
    { AgentIntercomGraphical = { }; }
  ];
  headless = node "headless" [ ];
  graphicalOnly = node "invalid-graphical" [ { AgentIntercomGraphical = { }; } ];

  localConfiguration = configurationFor {
    node = local;
    users.intercom-user = localUser;
  };
  graphicalConfiguration = configurationFor {
    node = graphical;
    users.intercom-user = localUser;
  };
  headlessConfiguration = configurationFor {
    node = headless;
    users.intercom-user = localUser;
  };
  graphicalOnlyConfiguration = configurationFor {
    node = graphicalOnly;
    users.intercom-user = localUser;
  };
  graphicalToplevel = builtins.tryEval graphicalConfiguration.system.build.toplevel.drvPath;
  graphicalOnlyRejected = builtins.tryEval graphicalOnlyConfiguration.system.build.toplevel.drvPath;

  module = ../../modules/nixos/agent-intercom.nix;
  usersModule = ../../modules/nixos/users.nix;
  moduleSources = [
    module
    usersModule
  ];
  sourceHas = term: builtins.any (source: lib.hasInfix term (builtins.readFile source)) moduleSources;

  # These strings are intentional negative-test witnesses. They must not occur
  # in the evaluated system modules, where old topology and sensitive surfaces
  # are forbidden.
  legacyOrSensitiveSurfaces = [
    "AgentIntercomGateway"
    "AgentIntercomPeer"
    "agentIntercomGatewaySshPubKey"
    "agent-intercom-remote-gateway"
    "AllowStreamLocalForwarding"
    "StreamLocalBindUnlink"
    "credential"
    "oauth"
    "pairing"
    "no-sandbox"
    "disable-sandbox"
  ];
  absentLegacyOrSensitiveSource = builtins.all (term: !sourceHas term) legacyOrSensitiveSurfaces;

  # The previous remote family could have left a system unit or socket behind.
  # These names are intentional negative-test witnesses, checked against the
  # evaluated NixOS unit graph rather than shell-text output.
  retiredUnitNames = [
    "agent-intercom-remote-gateway"
    "agent-intercom-gateway"
    "agent-intercom-peer"
    "agent-intercom-broker"
  ];
  hasNoRetiredUnits =
    configuration:
    builtins.all (
      name:
      !(builtins.hasAttr name configuration.systemd.services)
      && !(builtins.hasAttr name configuration.systemd.sockets)
    ) retiredUnitNames;
  preservesOrdinarySshSurface =
    configuration:
    configuration.services.openssh.extraConfig == headlessConfiguration.services.openssh.extraConfig
    && configuration.services.openssh.settings == headlessConfiguration.services.openssh.settings;
in
assert builtins.elem pkgs.hello localConfiguration.environment.systemPackages;
assert builtins.elem pkgs.hello graphicalConfiguration.environment.systemPackages;
assert !(builtins.elem pkgs.hello headlessConfiguration.environment.systemPackages);
assert !localConfiguration.services.gnome.at-spi2-core.enable;
assert !localConfiguration.hardware.uinput.enable;
assert !localConfiguration.xdg.portal.enable;
assert graphicalConfiguration.services.gnome.at-spi2-core.enable;
assert graphicalConfiguration.hardware.uinput.enable;
assert graphicalConfiguration.xdg.portal.enable;
assert graphicalConfiguration.xdg.portal.wlr.enable;
assert builtins.length graphicalConfiguration.xdg.portal.extraPortals >= 1;
assert graphicalToplevel.success;
assert builtins.elem "uinput" graphicalConfiguration.users.users.intercom-user.extraGroups;
assert builtins.hasAttr "uinput" graphicalConfiguration.users.groups;
assert !headlessConfiguration.services.gnome.at-spi2-core.enable;
assert !headlessConfiguration.hardware.uinput.enable;
assert !headlessConfiguration.xdg.portal.enable;
assert !(builtins.elem "uinput" headlessConfiguration.users.users.intercom-user.extraGroups);
assert !(builtins.hasAttr "uinput" headlessConfiguration.users.groups);
assert !graphicalOnlyRejected.success;
assert
  localConfiguration.users.users.intercom-user.openssh.authorizedKeys.keys == localUser.sshPubKeys;
assert preservesOrdinarySshSurface localConfiguration;
assert preservesOrdinarySshSurface graphicalConfiguration;
assert hasNoRetiredUnits localConfiguration;
assert hasNoRetiredUnits graphicalConfiguration;
assert hasNoRetiredUnits headlessConfiguration;
assert absentLegacyOrSensitiveSource;
pkgs.runCommand "agent-intercom-local-capability-contract" { } ''
  touch "$out"
''
