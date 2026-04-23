{
  lib,
  horizon,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf optionals;
  inherit (horizon.node.methods) sizedAtLeast;

  minPackages = optionals sizedAtLeast.min (
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
    graphics.enable32Bit = sizedAtLeast.max;
  };

  environment = {
    systemPackages =
      with pkgs;
      minPackages ++ (optionals sizedAtLeast.med medPackages ++ (optionals sizedAtLeast.max maxPackages));

    gnome.excludePackages = with pkgs; [
      gnome-software
    ];
  };

  programs = {
    browserpass.enable = sizedAtLeast.max;

    dconf.enable = true;
    droidcam.enable = sizedAtLeast.max;
    evolution.enable = true;

    firejail.enable = sizedAtLeast.med;

    regreet = {
      enable = sizedAtLeast.min;
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
    avahi.enable = sizedAtLeast.min;

    blueman.enable = sizedAtLeast.min;

    power-profiles-daemon.enable = false;
    upower.enable = sizedAtLeast.min;

    dbus.packages = mkIf sizedAtLeast.min [ pkgs.gcr ];

    gvfs.enable = sizedAtLeast.min;

    gnome = {
      at-spi2-core.enable = sizedAtLeast.min;
      core-apps.enable = sizedAtLeast.min;
      evolution-data-server.enable = sizedAtLeast.min;
      gnome-keyring.enable = sizedAtLeast.min;
      gnome-online-accounts.enable = sizedAtLeast.min;
      gnome-settings-daemon.enable = sizedAtLeast.min;
    };

    tumbler.enable = sizedAtLeast.med;

    pulseaudio.enable = false;

    keyd = {
      enable = sizedAtLeast.min;
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
