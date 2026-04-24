{
  lib,
  horizon,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf optionals;
  inherit (horizon.node) size;

  minPackages = optionals size.is.min (
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
{

  hardware = {
    bluetooth.enable = true;
    graphics.enable32Bit = size.is.max;
  };

  environment = {
    systemPackages =
      with pkgs;
      minPackages ++ (optionals size.is.med medPackages ++ (optionals size.is.max maxPackages));

    gnome.excludePackages = with pkgs; [
      gnome-software
    ];
  };

  programs = {
    browserpass.enable = size.is.max;

    dconf.enable = true;
    droidcam.enable = size.is.max;
    evolution.enable = true;

    firejail.enable = size.is.med;

    regreet = {
      enable = size.is.min;
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
    avahi.enable = size.is.min;

    blueman.enable = size.is.min;

    power-profiles-daemon.enable = false;
    upower.enable = size.is.min;

    dbus.packages = mkIf size.is.min [ pkgs.gcr ];

    gvfs.enable = size.is.min;

    gnome = {
      at-spi2-core.enable = size.is.min;
      core-apps.enable = size.is.min;
      evolution-data-server.enable = size.is.min;
      gnome-keyring.enable = size.is.min;
      gnome-online-accounts.enable = size.is.min;
      gnome-settings-daemon.enable = size.is.min;
    };

    tumbler.enable = size.is.med;

    pulseaudio.enable = false;

    keyd = {
      enable = size.is.min;
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
