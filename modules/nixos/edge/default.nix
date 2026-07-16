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

  bluetoothPowerWitness = pkgs.writeShellApplication {
    name = "bluetooth-power-witness";
    runtimeInputs = with pkgs; [
      coreutils
      dbus
      gawk
      systemd
    ];
    text = ''
      set -euo pipefail

      printf '%s\n' 'event=witness-started scope=bluez-adapter-power duration=11h55m'

      set +e
      timeout --signal=TERM --kill-after=5s 11h55m \
        dbus-monitor --system \
          "type='method_call',destination='org.bluez',path='/org/bluez/hci0',interface='org.freedesktop.DBus.Properties',member='Set'" \
          "type='signal',sender='org.bluez',path='/org/bluez/hci0',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'" \
          "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'" \
        | gawk '
          function flush(    sender, state, kind) {
            if (event ~ /member=NameOwnerChanged/ && event ~ /string "org.bluez"/) {
              print "bluez-owner-changed unavailable unavailable"
            } else if (event ~ /string "Powered"/) {
              sender = "unavailable"
              if (match(event, /sender=[^ ]+/)) {
                sender = substr(event, RSTART + 7, RLENGTH - 7)
              }
              state = event ~ /boolean true/ ? "true" : (event ~ /boolean false/ ? "false" : "unavailable")
              kind = event ~ /^method call / ? "power-request" : "adapter-powered"
              printf "%s %s %s\n", kind, sender, state
            }
            event = ""
          }

          /^(method call|signal) / {
            flush()
            event = $0
            next
          }

          {
            event = event ORS $0
          }

          END {
            flush()
          }
        ' \
        | while read -r eventKind sender state; do
            writerPid="$(busctl --system call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s "$sender" 2>/dev/null | gawk '{ print $2 }' || true)"
            printf '%s\n' "event=$eventKind powered=$state sender=$sender pid=''${writerPid:-unavailable}"
          done
      monitorStatus="''${PIPESTATUS[0]}"
      set -e

      case "$monitorStatus" in
        0 | 124 | 143) printf '%s\n' 'event=witness-ended' ;;
        *) exit "$monitorStatus" ;;
      esac
    '';
  };

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

  # `powerOnBoot` is BlueZ's startup and hotplug policy.  A controller that
  # remains present across suspend can still return with Powered=false, so
  # reassert power after systemd-suspend has returned.  This oneshot deliberately
  # does not remain active: every suspend target transition gets a fresh D-Bus
  # request, and a missing controller or rejected request is reported as a unit
  # failure in the journal rather than hidden behind a retry loop.
  systemd.services = {
    bluetooth-resume-power = {
      description = "Restore Bluetooth adapter power after resume";
      after = [
        "systemd-suspend.service"
        "bluetooth.service"
      ];
      requires = [ "bluetooth.service" ];
      wantedBy = [ "suspend.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bluez}/bin/bluetoothctl --timeout 10 power on";
      };
    };

    # Existing journals establish an Adapter1 power-down but not the D-Bus caller.
    # This temporary observer is event-driven and emits only adapter power state,
    # sender identity, and a process ID for journal correlation; it never records
    # device objects, names, addresses, or other connection metadata.
    bluetooth-power-witness = {
      description = "Observe BlueZ adapter power writers for one diagnostic window";
      after = [
        "dbus.service"
        "bluetooth.service"
      ];
      requires = [ "dbus.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${bluetoothPowerWitness}/bin/bluetooth-power-witness";
        RuntimeMaxSec = "12h";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
  };

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
