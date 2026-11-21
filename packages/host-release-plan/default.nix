{ inputs, pkgs, system, ... }:

pkgs.writeShellApplication {
  name = "host-release-plan";
  runtimeInputs = [
    inputs.lojix.inputs.horizon.packages.${system}.default
    pkgs.jq
  ];
  text = ''
    usage() {
      printf '%s\n' 'Usage: host-release-plan <horizon-definition.datom> <viewpoint-node> All|Explicit [node ...]' >&2
      exit 2
    }

    (( $# >= 3 )) || usage
    proposal=$1
    viewpoint=$2
    selection=$3
    shift 3
    case "$selection" in
      All) (( $# == 0 )) || usage ;;
      Explicit) (( $# > 0 )) || usage ;;
      *) usage ;;
    esac

    if [[ $proposal != /*/horizon-definition.datom || ! -f $proposal || -L $proposal ]]; then
      printf '%s\n' 'Supply an absolute path to a regular, non-symlink horizon-definition.datom.' >&2
      exit 2
    fi

    projection=$(horizon-cli --node="$viewpoint" < "$proposal")
    jq --exit-status --arg selection "$selection" --from-file ${./select-hosts.jq} \
      --args -- "$@" <<< "$projection"
  '';
}
