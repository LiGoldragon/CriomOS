{
  lib,
  horizon,
  config,
  pkgs,
  inputs,
  ...
}:
let
  inherit (lib)
    mkIf
    optional
    optionals
    optionalString
    optionalAttrs
    ;
  inherit (horizon.node.machine) model;
  inherit (horizon.node)
    behavesAs
    size
    chipIsIntel
    modelIsThinkpad
    useColemak
    computerIs
    isLargeEdge
    handleLidSwitch
    handleLidSwitchExternalPower
    handleLidSwitchDocked
    ;

  brightnessCtl = inputs.brightness-ctl.packages.${pkgs.system}.default;

  batteryCtl = pkgs.writeShellScriptBin "battery-ctl" ''
    usage() { echo "usage: battery-ctl care | full | status"; exit 1; }
    bat=/sys/class/power_supply/BAT0
    [ -d "$bat" ] || { echo "no battery found"; exit 1; }
    set_thresholds() {
      # thinkpad_acpi requires start < end at all times.
      # Write whichever direction widens the window first.
      local cur_start cur_end
      cur_start=$(cat "$bat/charge_control_start_threshold")
      cur_end=$(cat "$bat/charge_control_end_threshold")
      if [ "$1" -ge "$cur_start" ]; then
        echo "$2" > "$bat/charge_control_end_threshold"
        echo "$1" > "$bat/charge_control_start_threshold"
      else
        echo "$1" > "$bat/charge_control_start_threshold"
        echo "$2" > "$bat/charge_control_end_threshold"
      fi
    }
    case "''${1:-status}" in
      care)
        set_thresholds 75 80
        echo "battery care: 75–80%"
        ;;
      full)
        set_thresholds 90 95
        echo "full charge: 90–95%"
        ;;
      status)
        echo "start: $(cat "$bat/charge_control_start_threshold")%"
        echo "stop:  $(cat "$bat/charge_control_end_threshold")%"
        echo "level: $(cat "$bat/capacity")%"
        echo "state: $(cat "$bat/status")"
        ;;
      *) usage ;;
    esac
  '';

  lockActiveSessions = pkgs.writeShellScript "lock-active-sessions" ''
    set -eu

    ${pkgs.systemd}/bin/loginctl lock-sessions || true

    for runtime in /run/user/[0-9]*; do
      [ -d "$runtime" ] || continue

      uid="''${runtime##*/}"
      [ "$uid" -ge 1000 ] || continue
      [ -S "$runtime/bus" ] || continue

      user="$(${pkgs.gawk}/bin/awk -F: -v uid="$uid" '$3 == uid { print $1; exit }' /etc/passwd)"
      [ -n "$user" ] || continue

      ${pkgs.util-linux}/bin/runuser -u "$user" -- \
        env XDG_RUNTIME_DIR="$runtime" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
            WAYLAND_DISPLAY=wayland-1 \
            ${pkgs.systemd}/bin/systemctl --user start --wait criomos-lock-session.service \
        || true
    done
  '';

  # TODO
  hasTouchpad = true;

  needsIntelThrottlingFix = model == "ThinkPadT14Gen2Intel";

  modelFirmwareIndex = with pkgs; {
    ThinkPadE15Gen2Intel = [ sof-firmware ];
    ThinkPadT14Gen2Intel = [ sof-firmware ];
    rpi3B = [ raspberrypiWirelessFirmware ];
  };

  modelSpecificFirmware = modelFirmwareIndex."${model}" or [ ];

  modelSpecificPowerTweaks = {
    ThinkPadE15Gen2Intel = {
      powerUpCommands = ''
        echo 0 > /sys/devices/platform/thinkpad_acpi/leds/tpacpi::power/brightness
      '';
      powerDownCommands = "";
    };
  };

  hasModelSpecificPowerTweaks = model != null && builtins.hasAttr model modelSpecificPowerTweaks;

  modelKernelModulesIndex = {
    "GMKtec EVO-X2" = [
      "nvme"
      "mt7925e"
    ];
    ThinkPadE15Gen2Intel = [
      "nvme"
      "thunderbolt"
    ];
    ThinkPadT14Gen2Intel = [
      "nvme"
      "thunderbolt"
      "sd_mod"
    ];
    ThinkPadT14Gen5Intel = [
      "nvme"
      "thunderbolt"
      "sd_mod"
      "xe"
    ];
    ThinkPadX250 = [
      "usb_storage"
      "rtsx_pci_sdmmc"
    ];
  };

  modelSpecificKernelModules = modelKernelModulesIndex."${model}" or [ ];

  waydroidPackages = with pkgs; [
    # Investigate: Clipboard passing still not working reliably
    wl-clipboard
    python3Packages.pyclip
  ];

  # TODO - sort out different `sizedatleast` sets
  printingDriversPkgs = lib.optionals size.atLeastMax (
    with pkgs;
    [
      gutenprint # Drivers for many different printers from many different vendors.
      gutenprintBin # Additional, binary-only drivers for some printers.
      hplip # Drivers for HP printers.
      hplipWithPlugin # Drivers for HP printers, with the proprietary plugin.
      postscript-lexmark # Postscript drivers for Lexmark
      samsung-unified-linux-driver # Proprietary Samsung Drivers
      splix # Drivers for printers supporting SPL (Samsung Printer Language).
      brlaser # Drivers for some Brother printers
      brgenml1lpr # Generic drivers for more Brother printers
      brgenml1cupswrapper # ^^^
      epson-escpr2 # Drivers for Epson AirPrint devices
      epson-escpr # Drivers for some other Epson devices
    ]
  );

  intelUtils = with pkgs; [
    libva-utils
    i7z
  ];

  isGenericModel = model == "all-x86-64";

  unknownIntelGpuError = if isGenericModel then [] else throw "Model ${model} missing in Intel GPU drivers lists";

  intelMediaDriverModels = [
    "ThinkPadT14Gen5Intel"
    "ThinkPadT14Gen2Intel"
    "ThinkPadE15Gen2Intel"
  ];

  gpuUsesMediaDriver = isGenericModel || builtins.elem model intelMediaDriverModels;

  amdGpuModels = [
    "GMKtec EVO-X2"
  ];

  gpuUsesAmdGpu = isGenericModel || builtins.elem model amdGpuModels;

  treatAsIntel = chipIsIntel && !gpuUsesAmdGpu;

  gpuUsesVaapi = isGenericModel || builtins.elem model [
    "ThinkPadX230"
    "ThinkPadX240"
    "ThinkPadX250"
  ];

  intelMediaDrivers = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt
  ];

  intelGpuDrivers =
    if gpuUsesVaapi then
      [ pkgs.intel-vaapi-driver ]
    else if gpuUsesMediaDriver then
      intelMediaDrivers
    else if treatAsIntel then
      unknownIntelGpuError
    else
      [ ];

in
mkIf behavesAs.bareMetal {
  hardware = {
    cpu.intel.updateMicrocode = chipIsIntel;

    # Hack: TODO - tune per model, see `modelSpecificfirmware`
    enableAllFirmware = true;

    firmware = modelSpecificFirmware;

    ledger.enable = behavesAs.edge;

    graphics.enable = true;
    graphics.extraPackages = optionals treatAsIntel intelGpuDrivers;
  };

  location.provider = if size.atLeastMin then "geoclue2" else "manual";

  boot = {
    extraModulePackages =
      [ ]
      ++ (optional modelIsThinkpad config.boot.kernelPackages.acpi_call)
      ++ (optional size.atLeastMax config.boot.kernelPackages.v4l2loopback);

    initrd = {
      availableKernelModules = [
        "xhci_pci"
        "usb_storage"
      ];
    };

    kernelModules = [ "coretemp" ] ++ modelSpecificKernelModules ++ (optional gpuUsesAmdGpu "amdgpu");

    extraModprobeConfig = (
      optionalString size.atLeastMax ''
        options v4l2loopback devices=2 card_label="camera","obs" exclusive_caps=1
      ''
    ) + (
      optionalString (model == "ThinkPadT14Gen5Intel") ''
        blacklist i915
        options xe force_probe=7d45
      ''
    ) + (
      # T14 Gen2 Intel (Tiger Lake) suspend fixes:
      # MHI (Quectel WWAN modem) returns -EBUSY on suspend, aborting sleep.
      # IPU6 camera driver breaks s2idle on kernel 6.16+.
      optionalString (model == "ThinkPadT14Gen2Intel") ''
        blacklist mhi
        blacklist mhi_ep
        blacklist mhi_net
        blacklist mhi_pci_generic
        blacklist mhi_wwan_ctrl
        blacklist mhi_wwan_mbim
        blacklist intel_ipu6
        blacklist intel_ipu6_psys
      ''
    );

    kernelParams =
      lib.concatLists [
        (if computerIs.rpi3b then [
          "cma=32M"
          "console=ttyS0,115200n8"
          "console=ttyAMA0,11520n8"
          "console=tty0"
          "dtparam=audio=on"
        ] else [])
        # RDNA 3.5 (gfx1150/1151/1152) stability — MES hang + PSR2-SU freeze workarounds.
        # cwsr_enable=0: prevents MES "failed to respond" hangs during compute.
        # gpu_recovery=1: auto-recover from GPU hangs instead of hard-lock.
        # dcdebugmask=0x200: disables PSR2-SU (keeps legacy PSR for battery).
        (optionals gpuUsesAmdGpu [
          "amdgpu.cwsr_enable=0"
          "amdgpu.gpu_recovery=1"
          "amdgpu.dcdebugmask=0x200"
        ])
        # largeAI GPU tuning — expose 5/6 of unified RAM to GPU via TTM
        # Without this, Vulkan only sees ~64GB on 128GB Strix Halo.
        (optionals (behavesAs.center) [
          "ttm.page_pool_size=27787264"
          "ttm.pages_limit=27787264"
        ])
        # T14 Gen2 Intel (Tiger Lake) — touchpad and suspend fixes.
        # i8042.nomux: fixes erratic cursor / ghost touches from AUX mux conflict.
        # acpi.ec_no_wakeup: prevents spurious EC wakeups on ThinkPads.
        (optionals (model == "ThinkPadT14Gen2Intel") [
          "i8042.nomux=1"
          "acpi.ec_no_wakeup=1"
        ])
      ];

  };

  # Battery charge thresholds — default to care mode (75–80%).
  # Runs at boot and after resume; ThinkPad EC persists values across reboots
  # but re-applying after suspend is belt-and-suspenders.
  systemd.services.battery-charge-default = mkIf modelIsThinkpad {
    description = "Set battery charge thresholds to care mode";
    after = [ "multi-user.target" "suspend.target" "hibernate.target" ];
    wantedBy = [ "multi-user.target" "suspend.target" "hibernate.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${batteryCtl}/bin/battery-ctl care";
    };
  };

  systemd.services.lock-before-sleep = mkIf behavesAs.edge {
    description = "Lock all sessions before sleep";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lockActiveSessions}";
    };
  };

  # T14 Gen2 Intel (Tiger Lake) — disable ACPI wakeup sources that cause
  # spurious resume from s2idle. GLAN (e1000e with no cable), XHCI, and
  # Thunderbolt controllers (TXHC/TDM/TRP) all trigger immediate wake.
  systemd.services.disable-spurious-wakeups = mkIf (model == "ThinkPadT14Gen2Intel") {
    description = "Disable ACPI wakeup sources that cause spurious resume";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "disable-wakeups" ''
        for src in GLAN TXHC TDM0 TDM1 TRP0 TRP2; do
          if ${pkgs.gnugrep}/bin/grep -q "$src.*enabled" /proc/acpi/wakeup; then
            echo "$src" > /proc/acpi/wakeup
          fi
        done
      '';
    };
  };

  # Headless nodes: set EPP to "power" for aggressive idle downclocking.
  # The sysfs file only exists on CPUs with EPP support (AMD amd-pstate,
  # Intel intel_pstate HWP), so the rule is a no-op on unsupported hardware.
  systemd.tmpfiles.rules =
    optionals behavesAs.center [
      "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - power"
    ]
    # Disable XHCI wakeup at PCI level — belt-and-suspenders with the ACPI toggle.
    ++ optionals (model == "ThinkPadT14Gen2Intel") [
      "w /sys/devices/pci0000:00/0000:00:14.0/power/wakeup - - - - disabled"
    ];

  powerManagement =
    let
      pmBase = {
        powertop.enable = true;
      };
    in pmBase
      // (optionalAttrs hasModelSpecificPowerTweaks modelSpecificPowerTweaks."${model}");

  programs = { };

  console.useXkbConfig = true;

  environment = {
    systemPackages =
      with pkgs;
      [ lm_sensors ]
      ++ optionals chipIsIntel intelUtils
      ++ optionals size.atLeastMax [ v4l-utils ]
      ++ optionals isLargeEdge waydroidPackages
      ++ optional modelIsThinkpad batteryCtl
      ;

  };

  users.groups.plugdev = { };
  users.groups.power = mkIf modelIsThinkpad { };

  services = {
    # TODO
    fwupd.enable = true;

    geoclue2 = {
      enable = size.atLeastMin;
      enableDemoAgent = lib.mkOverride 0 true;
      geoProviderUrl = "https://beacondb.net/v1/geolocate";
      appConfig.redshift = {
        isAllowed = true;
        isSystem = true;
      };
      appConfig.darkman = {
        isAllowed = true;
        isSystem = false;
      };
    };

    localtimed = {
      enable = size.atLeastMin;
    };

    printing = {
      enable = true;
      cups-pdf.enable = size.atLeastMin;
      drivers = printingDriversPkgs;
    };

    throttled.enable = needsIntelThrottlingFix;

    udev.extraRules = ''
      # Battery charge threshold — grant group write so unprivileged users can toggle
      SUBSYSTEM=="power_supply", KERNEL=="BAT*", RUN+="${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/chgrp power /sys%p/charge_control_start_threshold /sys%p/charge_control_end_threshold 2>/dev/null; ${pkgs.coreutils}/bin/chmod g+w /sys%p/charge_control_start_threshold /sys%p/charge_control_end_threshold 2>/dev/null'"
      # USBasp - USB programmer for Atmel AVR controllers
      SUBSYSTEM=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="05dc", GROUP="plugdev"
      # Pro-micro kp-boot-bootloader - Ergodone keyboard
      SUBSYSTEM=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="bb05", GROUP="plugdev"
    '';

    libinput = {
      enable = hasTouchpad;
      touchpad = {
        naturalScrolling = true;
        tapping = true;
      };
    };

    xserver = {
      xkb.variant = optionalString useColemak "colemak";
      xkb.options = "caps:ctrl_modifier, altwin:swap_alt_win";

      autoRepeatDelay = 200;
      autoRepeatInterval = 28;

      digimend.enable = false; # !typeIs.center; # Broken
    };

    logind.settings.Login = {
      HandleLidSwitch = handleLidSwitch;
      HandleLidSwitchExternalPower = handleLidSwitchExternalPower;
      HandleLidSwitchDocked = handleLidSwitchDocked;
    };

    thinkfan = mkIf modelIsThinkpad {
      enable = true;
      sensors = [
        {
          type = "tpacpi";
          query = "/proc/acpi/ibm/thermal";
        }
      ];
    };

    udisks2.enable = true;

    acpid = {
      enable = true;

      handlers = {
        mute = {
          action = ''
            wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
          '';
          event = "button/mute";
        };
        volumeup = {
          action = ''
            wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
          '';
          event = "button/volumeup";
        };
        volumedown = {
          action = ''
            wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
          '';
          event = "button/volumedown";
        };
        mutemic = {
          action = ''
            wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
          '';
          event = "button/f20";
        };
        brightnessup = {
          action = ''
            ${brightnessCtl}/bin/brightness-ctl up
          '';
          event = "video/brightnessup";
        };
        brightnessdown = {
          action = ''
            ${brightnessCtl}/bin/brightness-ctl down
          '';
          event = "video/brightnessdown";
        };
      };

    };
  };

  virtualisation = {
    libvirtd.enable = isLargeEdge;
    waydroid.enable = isLargeEdge;
    spiceUSBRedirection.enable = size.atLeastMax;
  };
}
