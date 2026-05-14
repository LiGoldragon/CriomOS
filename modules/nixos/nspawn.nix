{
  config,
  horizon,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkAfter mkIf;
  inherit (horizon.node) behavesAs size;

  enable = size.large && behavesAs.center && !config.boot.isContainer && !behavesAs.iso;
  trustedGroup = "nixdev";
  stableCommandPath = "/run/current-system/sw/bin/criomos-nspawn";
  nixosContainer = pkgs.nixos-container;

  criomosNspawn = pkgs.writeShellApplication {
    name = "criomos-nspawn";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.sudo
      nixosContainer
    ];
    text = ''
      export SYSTEMD_PAGER=cat
      export SYSTEMD_PAGERSECURE=1

      usage() {
        cat <<'USAGE'
      criomos-nspawn create <name> <system-path>
      criomos-nspawn update <name> <system-path>
      criomos-nspawn start <name>
      criomos-nspawn stop <name>
      criomos-nspawn restart <name>
      criomos-nspawn terminate <name>
      criomos-nspawn shell <name> [command ...]
      criomos-nspawn status <name>
      criomos-nspawn remove <name>
      criomos-nspawn list
      criomos-nspawn ip <name>

      <name> must match [a-z0-9][a-z0-9-]{0,10}.
      <system-path> is a built NixOS system path whose init is <system-path>/init.
      USAGE
      }

      fail() {
        printf 'criomos-nspawn: %s\n' "$*" >&2
        exit 64
      }

      require_root() {
        if [ "$(id -u)" != 0 ]; then
          exec sudo ${stableCommandPath} "$@"
        fi
      }

      require_machine_name() {
        local machine_name="$1"

        if ! [[ "$machine_name" =~ ^[a-z0-9][a-z0-9-]{0,10}$ ]]; then
          fail "machine name must match [a-z0-9][a-z0-9-]{0,10}, got: $machine_name"
        fi
      }

      require_system_path() {
        local system_path="$1"

        if ! [[ "$system_path" == /nix/store/* ]]; then
          fail "system path must be a Nix store path"
        fi
        if [ ! -x "$system_path/init" ]; then
          fail "system path does not contain an executable init: $system_path/init"
        fi
        if [ ! -e "$system_path/etc/os-release" ]; then
          fail "system path does not contain os-release: $system_path/etc/os-release"
        fi
      }

      create_machine() {
        local machine_name="$1"
        local system_path="$2"

        require_machine_name "$machine_name"
        require_system_path "$system_path"
        exec nixos-container create "$machine_name" --system-path "$system_path"
      }

      update_machine() {
        local machine_name="$1"
        local system_path="$2"

        require_machine_name "$machine_name"
        require_system_path "$system_path"
        exec nixos-container update "$machine_name" --system-path "$system_path"
      }

      machine() {
        local machine_name="$1"

        require_machine_name "$machine_name"
        shift
        exec nixos-container "$@" "$machine_name"
      }

      shell_machine() {
        local machine_name="$1"
        shift

        require_machine_name "$machine_name"
        if [ "$#" -eq 0 ]; then
          exec nixos-container root-login "$machine_name"
        fi

        exec nixos-container run "$machine_name" -- "$@"
      }

      action="''${1:-}"

      case "$action" in
        help|--help|-h)
          usage
          ;;
        list)
          require_root "$@"
          exec nixos-container list
          ;;
        create)
          [ "$#" -eq 3 ] || fail "usage: criomos-nspawn create <name> <system-path>"
          require_root "$@"
          create_machine "$2" "$3"
          ;;
        update)
          [ "$#" -eq 3 ] || fail "usage: criomos-nspawn update <name> <system-path>"
          require_root "$@"
          update_machine "$2" "$3"
          ;;
        start|stop|restart|terminate|status)
          [ "$#" -eq 2 ] || fail "usage: criomos-nspawn $action <name>"
          require_root "$@"
          machine "$2" "$action"
          ;;
        shell)
          [ "$#" -ge 2 ] || fail "usage: criomos-nspawn shell <name> [command ...]"
          require_root "$@"
          shift
          shell_machine "$@"
          ;;
        remove)
          [ "$#" -eq 2 ] || fail "usage: criomos-nspawn remove <name>"
          require_root "$@"
          machine "$2" destroy
          ;;
        ip)
          [ "$#" -eq 2 ] || fail "usage: criomos-nspawn ip <name>"
          require_root "$@"
          machine "$2" show-ip
          ;;
        *)
          usage >&2
          exit 64
          ;;
      esac
    '';
  };
in
mkIf enable {
  boot.enableContainers = true;

  environment.systemPackages = [ criomosNspawn ];

  security.sudo.extraRules = mkAfter [
    {
      groups = [ trustedGroup ];
      commands = [
        {
          command = stableCommandPath;
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.services.systemd-machined.wantedBy = [ "multi-user.target" ];

  systemd.tmpfiles.rules = [
    "d /etc/nixos-containers 0755 root root - -"
    "d /var/lib/nixos-containers 0700 root root - -"
    "d /nix/var/nix/profiles/per-container 0700 root root - -"
    "d /nix/var/nix/gcroots/per-container 0755 root root - -"
  ];
}
