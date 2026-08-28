{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  agentIntercom = inputs.criomos-home.packages.${system}.agent-intercom;

  node = name: edge: {
    inherit name;
    adminSshPubKeys = [ ];
    size = {
      min = edge;
      medium = false;
      large = false;
      max = false;
    };
    behavesAs.edge = edge;
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
          criomos-home = inputs.criomos-home;
        };
      };
      modules = [
        ../../modules/nixos/users.nix
        ../../modules/nixos/agent-intercom.nix
        ../../modules/nixos/edge/default.nix
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

  edge = node "edge" true;
  headless = node "headless" false;

  edgeConfiguration = configurationFor {
    node = edge;
    users.intercom-user = localUser;
  };
  headlessConfiguration = configurationFor {
    node = headless;
    users.intercom-user = localUser;
  };

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
# The package is independent of Horizon node services.
assert builtins.elem agentIntercom edgeConfiguration.environment.systemPackages;
assert builtins.elem agentIntercom headlessConfiguration.environment.systemPackages;

# Edge owns the graphical substrate. A non-Edge node receives none of it.
assert edgeConfiguration.services.gnome.at-spi2-core.enable;
assert edgeConfiguration.xdg.portal.enable;
assert edgeConfiguration.xdg.portal.wlr.enable;
assert edgeConfiguration.xdg.portal.config.common."org.freedesktop.impl.portal.ScreenCast" == "wlr";
assert edgeConfiguration.xdg.portal.config.common."org.freedesktop.impl.portal.Screenshot" == "wlr";
assert edgeConfiguration.xdg.portal.config.niri."org.freedesktop.impl.portal.ScreenCast" == "wlr";
assert edgeConfiguration.xdg.portal.config.niri."org.freedesktop.impl.portal.Screenshot" == "wlr";
assert builtins.elem "uinput" edgeConfiguration.users.users.intercom-user.extraGroups;
assert builtins.hasAttr "uinput" edgeConfiguration.users.groups;
assert !headlessConfiguration.services.gnome.at-spi2-core.enable;
assert !headlessConfiguration.xdg.portal.enable;
assert !(builtins.elem "uinput" headlessConfiguration.users.users.intercom-user.extraGroups);
assert !(builtins.hasAttr "uinput" headlessConfiguration.users.groups);
assert
  headlessConfiguration.users.users.intercom-user.openssh.authorizedKeys.keys == localUser.sshPubKeys;
assert preservesOrdinarySshSurface edgeConfiguration;
assert preservesOrdinarySshSurface headlessConfiguration;
assert hasNoRetiredUnits edgeConfiguration;
assert hasNoRetiredUnits headlessConfiguration;
pkgs.runCommand "agent-intercom-ungated-edge-contract" { } ''
  touch "$out"
''
