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
    size
    useColemak
    behavesAs
    hasVideoOutput
    enableNetworkManager
    ;

  hasAudioOutput = hasVideoOutput;

  jsonHorizonFail = pkgs.writeText "horizon.json" (builtins.toJSON horizon);

  criomosShell = mksh + mksh.shellPath;

  mkNodeKnownHost =
    n: node:
    concatSep " " [
      node.criomeDomainName
      node.sshPubKeyLine
    ];

  sshKnownHosts = concatSep "\n" (mapAttrsToList mkNodeKnownHost exNodes);

  pipewireFull = pkgs.pipewire.override {
    libpulseaudio = pkgs.pulseaudioFull;
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
      ++ (optional size.atLeastMin "exfat")
    );
  };

  documentation = {
    enable = !config.boot.isContainer && !behavesAs.iso;
    nixos.enable = !config.boot.isContainer && !behavesAs.iso;
  };

  environment = {
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
    let criomos-deploy = pkgs.callPackage ../../packages/criomos-deploy { };
    in with pkgs; [
      openssh
      ntfs3g
      fuse
      criomos-deploy
    ]
    ++ (if behavesAs.iso then [
      btrfs-progs
      dosfstools
      parted
      nmap
      vim
      htop
    ] else [
      tcpdump
      librist
      ifmetric
      pulseaudioFull
      networkmanager_strongswan
    ])
    ++ (optionals (size.atLeastMin && !behavesAs.iso) [
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
        XKB_DEFAULT_VARIANT = "colemak";
      }
    );
  };

  # Overlays are bad - force them off
  nixpkgs.overlays = mkOverride 0 [ ];

  # readOnlyPkgs makes `nixpkgs.{config,overlays}` no-ops for the main
  # pkgs (which we supply externally from CriomOS-pkgs with allowUnfree
  # already true), but home-manager's per-user pkgs evaluation still
  # consults the nixos-level `nixpkgs.config` for unfree gating. Forcing
  # allowUnfree here avoids the 'Refusing to evaluate
  # vscode-extension-anthropic-claude-code ... has an unfree license'
  # error that fires inside home-manager-bird's vscode extensions
  # eval — the error message itself points at this option.
  nixpkgs.config.allowUnfree = mkOverride 0 true;

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
      wireplumber.enable = true;
    };

    # IKEv2 support
    strongswan.enable = !behavesAs.iso;

    udev = {
      extraRules = ''
        # What is this for?
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
