set -u

if [ "$#" -ne 4 ]; then
  printf '%s\n' "usage: prometheus-nix-review-runner NIX RESULT_PATH SOURCE REVISION" >&2
  exit 64
fi

nix_binary=$1
result_path=$2
source=$3
revision=$4
check_attribute='#checks.x86_64-linux.prometheus-service-provider-policy'
nixpkgs_revision='f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1'
sops_nix_revision='a8627b21b9107c5711c96b84f32a9a4b3d45295f'

case "$source" in
  github:LiGoldragon/CriomOS) ;;
  *)
    printf '%s\n' "unsupported review source" >&2
    exit 64
    ;;
esac

case "$revision" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *)
    printf '%s\n' "review revision must be a lowercase 40-character Git revision" >&2
    exit 64
    ;;
esac

result_directory=$(dirname "$result_path")
mkdir -p "$result_directory"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

write_result() {
  status=$1
  exit_code=$2
  temporary_result=$(mktemp "$result_directory/.result.XXXXXX")
  trap 'rm -f "$temporary_result"' EXIT

  printf '%s\n' '{' >"$temporary_result"
  printf '  "runId": "%s",\n' "$run_id" >>"$temporary_result"
  printf '  "source": "%s",\n' "$source" >>"$temporary_result"
  printf '  "revision": "%s",\n' "$revision" >>"$temporary_result"
  printf '  "check": "%s",\n' "$check_attribute" >>"$temporary_result"
  printf '  "status": "%s",\n' "$status" >>"$temporary_result"
  printf '  "exitCode": %s\n' "$exit_code" >>"$temporary_result"
  printf '%s\n' '}' >>"$temporary_result"
  mv "$temporary_result" "$result_path"
  trap - EXIT
}

interrupted() {
  write_result interrupted 130
  exit 130
}

trap interrupted INT TERM
write_result running null

# CriomOS's public flake requires Lojix-materialized inputs. This expression
# deliberately evaluates only the fixed policy fixture with the same pinned
# nixpkgs and sops-nix inputs; it never constructs the host target.
review_expression="let source = builtins.fetchGit { url = \"https://github.com/LiGoldragon/CriomOS.git\"; rev = \"$revision\"; }; inputs = { nixpkgs = builtins.getFlake \"github:NixOS/nixpkgs/$nixpkgs_revision\"; sops-nix = builtins.getFlake \"github:Mic92/sops-nix/$sops_nix_revision\"; }; pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux; in import (source + \"/checks/prometheus-service-provider-policy\") { inherit inputs pkgs; }"

if "$nix_binary" build --refresh --no-link --print-out-paths --max-jobs 0 --impure --expr "$review_expression"; then
  exit_code=0
  status=passed
else
  exit_code=$?
  status=failed
fi

trap - INT TERM
write_result "$status" "$exit_code"
exit "$exit_code"
