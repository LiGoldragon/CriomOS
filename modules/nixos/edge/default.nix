{
  lib,
  horizon,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf optionals;
  inherit (horizon.node) size behavesAs;

  minPackages = optionals size.atLeastMin (
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
    bluetooth.enable = true;
    graphics.enable32Bit = size.atLeastLarge;
  };

  environment = {
    systemPackages =
      with pkgs;
      minPackages ++ (optionals size.atLeastMed medPackages ++ (optionals size.atLeastLarge maxPackages));

    gnome.excludePackages = with pkgs; [
      gnome-software
    ];
  };

  programs = {
    browserpass.enable = size.atLeastLarge;

    droidcam.enable = size.atLeastLarge;
    # evolution.enable: Max-tier per Li (heavy ~250MB email client).
    evolution.enable = size.atLeastMax;

    regreet = {
      enable = size.atLeastMin;
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
        "org.freedesktop.impl.portal.Settings" = [ "darkman" "gtk" ];
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
    avahi.enable = size.atLeastMin;

    blueman.enable = size.atLeastMin;

    power-profiles-daemon.enable = false;
    upower.enable = size.atLeastMin;

    dbus.packages = mkIf size.atLeastMin [ pkgs.gcr ];

    gvfs.enable = size.atLeastMin;

    gnome = {
      at-spi2-core.enable = size.atLeastMin;
      core-apps.enable = size.atLeastMin;
      evolution-data-server.enable = size.atLeastMin;
      gnome-keyring.enable = size.atLeastMin;
      gnome-online-accounts.enable = size.atLeastMin;
      gnome-settings-daemon.enable = size.atLeastMin;
    };

    tumbler.enable = size.atLeastMed;

    pulseaudio.enable = false;

    keyd = {
      enable = size.atLeastMin;
      keyboards.laptop = {
        ids = [ "0001:0001" ];
        extraConfig = ''
          [main]
          leftalt = leftmeta
          leftmeta = leftalt
        '';
      };
    };
  };
}
