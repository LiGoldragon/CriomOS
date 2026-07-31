{
  inputs,
  pkgs,
  ...
}:

let
  inherit (inputs.nixpkgs) lib;

  configurationFor =
    behavesAs:
    lib.nixosSystem {
      inherit pkgs;
      specialArgs.horizon.node = { inherit behavesAs; };
      modules = [
        inputs.nixpkgs.nixosModules.readOnlyPkgs
        ../../modules/nixos/hardware-adjustments
        {
          boot.kernelPackages = pkgs.linuxPackages_latest;
          system.stateVersion = "26.05";
        }
      ];
    };

  baseBehavesAs = {
    bareMetal = false;
    edge = false;
  };

  eligibleConfiguration = configurationFor (
    baseBehavesAs
    // {
      bareMetal = true;
      edge = true;
    }
  );
  nonEdgeConfiguration = configurationFor (baseBehavesAs // { bareMetal = true; });
  virtualEdgeConfiguration = configurationFor (baseBehavesAs // { edge = true; });

  adjustmentFor =
    configuration:
    lib.findFirst (
      entry: entry.name == "uvcvideo-ms2130-restrict-frame-aspect-16-9"
    ) null configuration.config.boot.kernelPatches;

  kernel = eligibleConfiguration.config.boot.kernelPackages.kernel;
  adjustment = adjustmentFor eligibleConfiguration;
in
assert lib.assertMsg (adjustment != null) "MS2130 UVC aspect adjustment must be active";
assert lib.assertMsg (
  adjustmentFor nonEdgeConfiguration == null
) "MS2130 UVC aspect adjustment must be inactive on non-edge hosts";
assert lib.assertMsg (
  adjustmentFor virtualEdgeConfiguration == null
) "MS2130 UVC aspect adjustment must be inactive on non-bare-metal edge hosts";
assert lib.assertMsg (
  kernel.version == "7.0.1"
) "MS2130 UVC patch must be reviewed for the selected kernel";
pkgs.runCommand "ms2130-uvc-aspect-quirk-check"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.patch
      pkgs.xz
    ];
  }
  ''
    set -eu

    test -e ${kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}

    mkdir -p source/drivers/media/usb/uvc
    tar -xJf ${kernel.src} --strip-components=1 -C source \
      linux-7.0.1/drivers/media/usb/uvc/uvc_driver.c \
      linux-7.0.1/drivers/media/usb/uvc/uvc_video.c \
      linux-7.0.1/drivers/media/usb/uvc/uvcvideo.h

    patch -d source -p1 < ${adjustment.patch}

    driver=source/drivers/media/usb/uvc/uvc_driver.c
    video=source/drivers/media/usb/uvc/uvc_video.c
    header=source/drivers/media/usb/uvc/uvcvideo.h
    ms2130_id=ms2130-uvc-id-entry

    sed -n '/MacroSilicon MS2130 HDMI capture/,/Intel D410\/ASR depth camera/p' \
      "$driver" > "$ms2130_id"

    grep -F 'UVC_QUIRK_RESTRICT_FRAME_ASPECT_16_9' "$header"
    grep -F 'frame->wWidth != 0' "$driver"
    grep -F 'frame->wHeight != 0' "$driver"
    grep -F '(u32)frame->wWidth * 9 == (u32)frame->wHeight * 16;' "$driver"
    grep -F 'USB_DEVICE_ID_MATCH_DEV_LO' "$ms2130_id"
    grep -F 'USB_DEVICE_ID_MATCH_DEV_HI' "$ms2130_id"
    grep -F 'USB_DEVICE_ID_MATCH_INT_INFO' "$ms2130_id"
    grep -F '.idVendor' "$ms2130_id" | grep -F '0x345f'
    grep -F '.idProduct' "$ms2130_id" | grep -F '0x2130'
    grep -F '.bcdDevice_lo' "$ms2130_id" | grep -F '0x3100'
    grep -F '.bcdDevice_hi' "$ms2130_id" | grep -F '0x3100'
    grep -F '.bInterfaceClass' "$ms2130_id" | grep -F 'USB_CLASS_VIDEO'
    grep -F '.bInterfaceSubClass' "$ms2130_id" | grep -F '= 1'
    grep -F '.bInterfaceProtocol' "$ms2130_id" | grep -F '= 0'
    grep -F 'format->nframes == 0' "$driver"
    grep -F 'streaming->nformats == 0' "$driver"
    grep -F 'Device returned filtered UVC format' "$video"
    grep -F 'uvc_video_ctrl_validate(stream, probe, "probe")' "$video"
    grep -F 'uvc_video_ctrl_validate(stream, probe, "initial probe")' "$video"
    grep -F 'uvc_video_ctrl_validate(stream, probe, "commit")' "$video"
    grep -F 'return -EPROTO;' "$video"

    touch "$out"
  ''
