{
  config,
  horizon,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib)
    mapAttrsToList
    mkOverride
    optional
    optionals
    mkIf
    optionalString
    optionalAttrs
    ;

  concatSep = lib.concatStringsSep;
  inherit (pkgs) mksh;
  inherit (horizon) exNodes;
  inherit (horizon.node)
    behavesAs
    enableNetworkManager
    ;
  hasMagnitude = values: builtins.elem horizon.node.size values;
  isMin = hasMagnitude [
    "Min"
    "Medium"
    "Large"
    "Max"
  ];

  useColemak = horizon.node.keyboard == "Colemak";
  hasAudioOutput = behavesAs.edge;

  jsonHorizonFail = pkgs.writeText "horizon.json" (builtins.toJSON horizon);

  criomosShell = mksh + mksh.shellPath;

  mkNodeKnownHost =
    n: node:
    concatSep " " [
      node.criomeDomainName
      node.sshPublicKeyLine
    ];

  sshKnownHosts = concatSep "\n" (mapAttrsToList mkNodeKnownHost exNodes);

  pipewireFull = pkgs.pipewire.override {
    libpulseaudio = pkgs.pulseaudioFull;
  };

  desktopAudioPolicy = {
    "monitor.bluez.properties" = {
      "bluez5.roles" = [
        "a2dp_sink"
        "a2dp_source"
        "bap_sink"
        "bap_source"
        # CriomOS uses Bluetooth microphones/headsets as peripherals.
        # The host is the audio gateway; advertising hands-free/headset
        # roles makes BlueZ probe the wrong direction on some devices.
        "hsp_ag"
        "hfp_ag"
      ];
      "bluez5.hfphsp-backend" = "native";
    };

    "monitor.alsa.rules" = [
      {
        matches = [
          { "node.name" = "~alsa_output.platform-snd_aloop.*"; }
          { "node.name" = "~alsa_input.platform-snd_aloop.*"; }
        ];
        actions.update-props = {
          "priority.driver" = 1;
          "priority.session" = 1;
        };
      }
    ];
  };

in
{
  boot = {
    kernelParams = [
      "consoleblank=300"
    ];

    kernelPackages = pkgs.linuxPackages_latest;

    supportedFilesystems = mkOverride 50 (
      [
        "xfs"
        "btrfs"
        "ntfs"
      ]
      ++ (optional isMin "exfat")
    );
  };

  documentation = {
    enable = !config.boot.isContainer && !behavesAs.iso;
    nixos.enable = !config.boot.isContainer && !behavesAs.iso;
  };

  environment = {
    # Home Manager owns the legacy user profile for this declarative desktop.
    # NixOS otherwise exports both it and the XDG compatibility profile into
    # PATH, NIX_PROFILES, and XDG resource search paths. Those independent
    # profiles can contain different revisions of the same command or desktop
    # service, so an old ad-hoc profile can shadow or duplicate the declared
    # user environment on every new login. Keep the system profiles plus the
    # one Home Manager-owned user profile; do not mutate or delete an old XDG
    # profile here.
    profiles = lib.mkForce [
      "/run/current-system/sw"
      "/nix/var/nix/profiles/default"
      "/etc/profiles/per-user/$USER"
      "$HOME/.nix-profile"
    ];

    binsh = criomosShell;
    shells = [ "/run/current-system/sw${mksh.shellPath}" ];

    etc = {
      "ssh/ssh_known_hosts".text = sshKnownHosts;
      "horizon.json" = {
        source = jsonHorizonFail;
        mode = "0600";
      };
    };

    systemPackages =
      with pkgs;
      [
        openssh
        ntfs3g
        fuse
      ]
      ++ (
        if behavesAs.iso then
          [
            btrfs-progs
            dosfstools
            parted
            nmap
            vim
            htop
          ]
        else
          [
            tcpdump
            librist
            ifmetric
            networkmanager_strongswan
          ]
      )
      ++ (optionals (isMin && !behavesAs.iso) [
        git
        curl
        jq
        htop
        pciutils
        usbutils
      ]);

    interactiveShellInit = optionalString useColemak "stty -ixon";
    sessionVariables = (
      optionalAttrs useColemak {
        XKB_DEFAULT_LAYOUT = "us";
        XKB_DEFAULT_VARIANT = "";
      }
    );
  };

  # Overlays are bad - force them off
  nixpkgs.overlays = mkOverride 0 [ ];

  networking.networkmanager = {
    enable = enableNetworkManager;
  };

  programs = {
    zsh.enable = true;
  };

  services = {
    openssh = {
      enable = true;
      # Keys only — no password auth, ever. Keys come from the criosphere.
      settings.PasswordAuthentication = false;
      ports = [ 22 ];
    };

    pipewire = mkIf hasAudioOutput {
      enable = true;
      package = pipewireFull;
      alsa.enable = true;
      jack.enable = false;
      pulse.enable = true;
      wireplumber = {
        enable = true;
        extraConfig."10-criomos-desktop-audio" = desktopAudioPolicy;
      };
    };

    # IKEv2 support
    strongswan.enable = !behavesAs.iso;

    udev = {
      extraRules = ''
        ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", GROUP="dialout", MODE="0660"
      '';
    };

  };

  system.stateVersion = "26.05";

  users = {
    defaultUserShell = "/run/current-system/sw/bin/zsh";
    groups.dialout = { };
  };
}
