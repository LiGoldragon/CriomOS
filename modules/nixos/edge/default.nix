{
  lib,
  horizon,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf optionals;
  inherit (horizon.node) size behavesAs;

  minPackages = optionals size.min (
    with pkgs;
    [
      adwaita-icon-theme
      papirus-icon-theme
      nautilus
      ffmpegthumbnailer
      libinput
      gnome-control-center
      niri
      xdg-utils
    ]
  );

  medPackages = with pkgs; [ ];

  maxPackages = with pkgs; [ ];

in
mkIf behavesAs.edge {

  hardware = {
    bluetooth = {
      enable = true;
      # Keep each adapter powered across BlueZ startup and hotplug events.
      powerOnBoot = true;
    };
    graphics.enable32Bit = size.large;
  };

  environment = {
    systemPackages =
      with pkgs;
      minPackages ++ (optionals size.medium medPackages ++ (optionals size.large maxPackages));

    gnome.excludePackages = with pkgs; [
      gnome-software
    ];
  };

  programs = {
    browserpass.enable = size.large;

    droidcam.enable = size.large;
    # evolution.enable: Max-tier per Li (heavy ~250MB email client).
    evolution.enable = size.max;

    regreet = {
      enable = size.min;
      settings = {
        GTK = {
          application_prefer_dark_theme = true;
          cursor_theme_name = "Adwaita";
          icon_theme_name = lib.mkForce "Papirus-Dark";
          theme_name = "Adwaita";
        };
      };
    };
  };

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
    ];
    config = {
      niri = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Secret" = [ "gnome-keyring" ];
        # darkman dropped — the chroma daemon owns the appearance
        # axis now and writes dconf directly via its apply
        # script. xdg-desktop-portal-gtk reads dconf and serves
        # `org.freedesktop.portal.Settings.color-scheme` to
        # GTK4 / Firefox / Electron / etc.
        "org.freedesktop.impl.portal.Settings" = [
          "gtk"
        ];
      };
      common = {
        default = [ "gtk" ];
      };
    };
  };

  security.polkit.enable = true;
  security.pam.services.swaylock = { };
  security.pam.services.noctalia = { };
  hardware.graphics.enable = lib.mkDefault true;

  services = {
    displayManager.sessionPackages = [ pkgs.niri ];
    avahi.enable = size.min;

    power-profiles-daemon.enable = false;
    upower.enable = size.min;

    dbus.packages = mkIf size.min [ pkgs.gcr ];

    gvfs.enable = size.min;

    gnome = {
      at-spi2-core.enable = size.min;
      core-apps.enable = size.min;
      evolution-data-server.enable = size.min;
      gnome-keyring.enable = size.min;
      gnome-online-accounts.enable = size.min;
      gnome-settings-daemon.enable = size.min;
    };

    tumbler.enable = size.medium;

    pulseaudio.enable = false;

    keyd = {
      enable = size.min;
      keyboards.laptop = {
        ids = [ "0001:0001" ];
        extraConfig = ''
          # Laptop Colemak is per-device here; QMK Colemak boards stay raw.
          # This is keyd's shipped layouts/colemak, inlined for NixOS's /usr-free runtime.
          ${builtins.readFile "${pkgs.keyd}/share/keyd/layouts/colemak"}

          [global]
          default_layout = colemak

          [main]
          leftalt = layer(meta)
          leftmeta = layer(alt)
        '';
      };
    };
  };
}
