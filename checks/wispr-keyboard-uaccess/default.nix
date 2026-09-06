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
      size = "Medium";
      keyboard = "Qwerty";
      behavesAs = {
        bareMetal = true;
        center = false;
        edge = false;
        iso = false;
        largeAi = false;
        lowPower = false;
        router = false;
      };
      capabilities = [ ];
      machine = {
        kind = "Metal";
        architecture = "x86_64";
        host = null;
        additionalHosts = [ ];
        user = null;
        diskGib = null;
        hardware = {
          cores = 2;
          model = "all-x86-64";
          motherboard = null;
          chipGeneration = null;
          ramGib = 4;
          location = null;
        };
      };
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

  uinputKeyboard =
    testPkgs.runCommand "wispr-keyboard-uaccess-test-uinput"
      {
        nativeBuildInputs = [ testPkgs.stdenv.cc ];
      }
      ''
        mkdir -p "$out/bin"
        "$CC" -O2 -Wall -Werror -x c -o "$out/bin/wispr-test-uinput" - <<'EOF'
        #include <fcntl.h>
        #include <linux/input.h>
        #include <linux/uinput.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
          int fd;
          struct uinput_setup setup = {0};

          if (argc != 5) {
            fprintf(stderr, "usage: %s NAME PHYS VENDOR PRODUCT\n", argv[0]);
            return 2;
          }

          fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
          if (fd < 0) {
            perror("open /dev/uinput");
            return 1;
          }
          if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
              ioctl(fd, UI_SET_KEYBIT, KEY_ESC) < 0 ||
              ioctl(fd, UI_SET_KEYBIT, KEY_1) < 0 ||
              ioctl(fd, UI_SET_KEYBIT, KEY_A) < 0) {
            perror("configure uinput keyboard");
            return 1;
          }

          strncpy(setup.name, argv[1], UINPUT_MAX_NAME_SIZE - 1);
          setup.id.bustype = BUS_VIRTUAL;
          setup.id.vendor = strtoul(argv[3], NULL, 16);
          setup.id.product = strtoul(argv[4], NULL, 16);
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
assert lib.assertMsg (
  configuration.systemd.services ? "wispr-keyboard-uaccess-refresh"
) "physical keyboard uaccess must be refreshed by an activation-owned service";
assert lib.assertMsg (
  configuration.systemd.services."wispr-keyboard-uaccess-refresh".wantedBy == [ "multi-user.target" ]
) "the physical keyboard uaccess refresh must run on system activation";
testPkgs.testers.runNixOSTest {
  name = "wispr-keyboard-uaccess";

  nodes.machine =
    { pkgs, ... }:
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
      # uinput exposes the same event-device shape as the hardware under
      # test, but does not receive input-id's hardware classification.  Give
      # all controlled keyboard fixtures that existing udev property before
      # the production rule is evaluated.  The unrelated virtual keyboard is
      # deliberately classified too, so its exclusion proves the production
      # rule is narrow rather than relying on missing classification.
      services.udev.packages = [
        (pkgs.writeTextFile {
          name = "wispr-keyboard-uaccess-test-classification-rules";
          destination = "/etc/udev/rules.d/69-wispr-keyboard-uaccess-test.rules";
          text = ''
            SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="wispr-test-physical", ENV{ID_INPUT_KEYBOARD}="1"
            SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="keyd virtual keyboard", ENV{ID_INPUT_KEYBOARD}="1"
            SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="wispr unrelated virtual keyboard", ENV{ID_INPUT_KEYBOARD}="1"
          '';
        })
      ];
      system.stateVersion = "26.05";
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("wispr-keyboard-uaccess-refresh.service")

    machine.succeed("${uinputKeyboard}/bin/wispr-test-uinput wispr-test-physical usb-wispr/input0 0001 0001 >/run/wispr-test-physical.log 2>&1 &")
    machine.succeed('${uinputKeyboard}/bin/wispr-test-uinput "keyd virtual keyboard" "" 0fac 0ade >/run/wispr-test-keyd.log 2>&1 &')
    machine.succeed('${uinputKeyboard}/bin/wispr-test-uinput "wispr unrelated virtual keyboard" "" 0fac 0ade >/run/wispr-test-unrelated.log 2>&1 &')

    def event_named(name):
        return machine.succeed(
            'for event in /sys/class/input/event*; do '
            'if [ "$(cat "$event/device/name")" = "%s" ]; then basename "$event"; exit 0; fi; '
            'done; exit 1' % name
        ).strip()

    machine.wait_until_succeeds('test -n "$(for event in /sys/class/input/event*; do [ "$(cat "$event/device/name")" = wispr-test-physical ] && basename "$event"; done)"')
    machine.wait_until_succeeds('test -n "$(for event in /sys/class/input/event*; do [ "$(cat "$event/device/name")" = "keyd virtual keyboard" ] && basename "$event"; done)"')
    machine.wait_until_succeeds('test -n "$(for event in /sys/class/input/event*; do [ "$(cat "$event/device/name")" = "wispr unrelated virtual keyboard" ] && basename "$event"; done)"')
    physical = event_named("wispr-test-physical")
    keyd = event_named("keyd virtual keyboard")
    unrelated = event_named("wispr unrelated virtual keyboard")

    machine.succeed("udevadm settle --timeout=10")
    machine.succeed("test $(cat /sys/class/input/%s/device/phys) = usb-wispr/input0" % physical)
    machine.succeed("properties=$(udevadm info --query=property --name=/dev/input/%s); printf '%%s\\n' \"$properties\" | grep -qx 'ID_INPUT_KEYBOARD=1'; printf '%%s\\n' \"$properties\" | grep -E '^TAGS=.*:seat:'; printf '%%s\\n' \"$properties\" | grep -E '^TAGS=.*:uaccess:'" % physical)
    machine.succeed("properties=$(udevadm info --query=property --name=/dev/input/%s); printf '%%s\\n' \"$properties\" | grep -qx 'ID_INPUT_KEYBOARD=1'; printf '%%s\\n' \"$properties\" | grep -E '^TAGS=.*:seat:'; printf '%%s\\n' \"$properties\" | grep -E '^TAGS=.*:uaccess:'" % keyd)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:seat:'" % unrelated)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % unrelated)

    physical_db="/run/udev/data/c$(cat /sys/class/input/%s/dev)" % physical
    keyd_db="/run/udev/data/c$(cat /sys/class/input/%s/dev)" % keyd
    machine.succeed("sed -i '/^G:uaccess$/d' %s" % physical_db)
    machine.succeed("sed -i '/^G:uaccess$/d' %s" % keyd_db)
    machine.fail("grep -qx 'G:uaccess' %s" % physical_db)
    machine.fail("grep -qx 'G:uaccess' %s" % keyd_db)
    machine.succeed("systemctl restart wispr-keyboard-uaccess-refresh.service")
    machine.wait_for_unit("wispr-keyboard-uaccess-refresh.service")
    machine.succeed("grep -qx 'G:uaccess' %s" % physical_db)
    machine.succeed("grep -qx 'G:uaccess' %s" % keyd_db)
    machine.succeed("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % physical)
    machine.succeed("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % keyd)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:seat:'" % unrelated)
    machine.fail("udevadm info --query=property --name=/dev/input/%s | grep -E '^TAGS=.*:uaccess:'" % unrelated)
  '';
}
