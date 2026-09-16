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

if "$nix_binary" build --refresh --no-link --print-out-paths --max-jobs 0 "${source}/${revision}${check_attribute}"; then
  exit_code=0
  status=passed
else
  exit_code=$?
  status=failed
fi

trap - INT TERM
write_result "$status" "$exit_code"
exit "$exit_code"
