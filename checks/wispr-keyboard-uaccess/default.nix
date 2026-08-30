{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  testPkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  horizon = {
    node = {
      behavesAs = {
        bareMetal = true;
        center = false;
        edge = false;
        iso = false;
        largeAi = false;
        router = false;
      };
      chipIsIntel = false;
      computerIs.rpi3b = false;
      handleLidSwitch = "ignore";
      handleLidSwitchDocked = "ignore";
      handleLidSwitchExternalPower = "ignore";
      machine = {
        chipGen = null;
        model = "all-x86-64";
      };
      modelIsThinkpad = false;
      size = {
        min = false;
        medium = true;
        large = false;
        max = false;
      };
      useColemak = false;
      wantsHwVideoAccel = false;
      wantsPrinting = false;
    };
  };

  configuration =
    (lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs horizon; };
      modules = [
        ../../modules/nixos/metal/default.nix
        { system.stateVersion = "26.05"; }
      ];
    }).config;

  uinputKeyboard = testPkgs.runCommand "wispr-keyboard-uaccess-test-uinput" {
    nativeBuildInputs = [ testPkgs.stdenv.cc ];
  } ''
    mkdir -p "$out/bin"
    "$CC" -O2 -Wall -Werror -x c -o "$out/bin/wispr-test-uinput" - <<'EOF'
    #include <fcntl.h>
    #include <linux/input.h>
    #include <linux/uinput.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>

    int main(int argc, char **argv) {
      int fd;
      struct uinput_setup setup = {0};

      if (argc != 3) {
        fprintf(stderr, "usage: %s NAME PHYS\n", argv[0]);
        return 2;
      }

      fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
      if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
      }
      if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(fd, UI_SET_KEYBIT, KEY_A) < 0) {
        perror("configure uinput keyboard");
        return 1;
      }

      strncpy(setup.name, argv[1], UINPUT_MAX_NAME_SIZE - 1);
      setup.id.bustype = BUS_USB;
      setup.id.vendor = 1;
      setup.id.product = 1;
      setup.id.version = 1;
      if (argv[2][0] != '\0' && ioctl(fd, UI_SET_PHYS, argv[2]) < 0) {
        perror("set physical path");
        return 1;
      }
      if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("create uinput keyboard");
        return 1;
      }

      for (;;) pause();
    }
    EOF
  '';
in
assert lib.assertMsg (configuration.systemd.services ? "wispr-keyboard-uaccess-refresh")
  "physical keyboard uaccess must be refreshed by an activation-owned service";
assert lib.assertMsg (
  configuration.systemd.services."wispr-keyboard-uaccess-refresh".wantedBy == [ "multi-user.target" ]
) "the physical keyboard uaccess refresh must run on system activation";
testPkgs.testers.runNixOSTest {
  name = "wispr-keyboard-uaccess";

  nodes.machine =
    { ... }:
    {
      _module.args = {
        inherit inputs horizon;
        deployment = {
          includeHome = true;
          includeAllFirmware = true;
        };
      };
      imports = [ ../../modules/nixos/metal/default.nix ];

      boot.kernelModules = [ "uinput" ];
      system.stateVersion = "26.05";
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("wispr-keyboard-uaccess-refresh.service")

    machine.succeed("${uinputKeyboard}/bin/wispr-test-uinput wispr-test-physical usb-wispr/input0 >/run/wispr-test-physical.log 2>&1 &")
    machine.succeed("${uinputKeyboard}/bin/wispr-test-uinput wispr-test-virtual \\\"\\\" >/run/wispr-test-virtual.log 2>&1 &")

    def event_named(name):
        return machine.succeed(
            'for event in /sys/class/input/event*; do '
            '[ "$(cat "$event/device/name")" = "%s" ] && basename "$event"; '
            'done' % name
        ).strip()

    machine.wait_until_succeeds('test -n "$(for event in /sys/class/input/event*; do [ "$(cat "$event/device/name")" = wispr-test-physical ] && basename "$event"; done)"')
    machine.wait_until_succeeds('test -n "$(for event in /sys/class/input/event*; do [ "$(cat "$event/device/name")" = wispr-test-virtual ] && basename "$event"; done)"')
    physical = event_named("wispr-test-physical")
    virtual = event_named("wispr-test-virtual")

    machine.wait_until_succeeds("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % physical)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % virtual)

    physical_db="/run/udev/data/c$(cat /sys/class/input/%s/dev)" % physical
    machine.succeed("sed -i '/^G:uaccess$/d' %s" % physical_db)
    machine.fail("grep -qx 'G:uaccess' %s" % physical_db)
    machine.succeed("systemctl restart wispr-keyboard-uaccess-refresh.service")
    machine.wait_for_unit("wispr-keyboard-uaccess-refresh.service")
    machine.succeed("grep -qx 'G:uaccess' %s" % physical_db)
    machine.succeed("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % physical)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % virtual)
  '';
}
