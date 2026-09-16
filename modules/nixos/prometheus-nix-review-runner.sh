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
temporary_result=$(mktemp "$result_directory/.result.XXXXXX")
trap 'rm -f "$temporary_result"' EXIT

if "$nix_binary" build --refresh --no-link --print-out-paths --max-jobs 0 "${source}/${revision}${check_attribute}"; then
  status=passed
  exit_code=0
else
  status=failed
  exit_code=$?
fi

printf '%s\n' '{' >"$temporary_result"
printf '  "source": "%s",\n' "$source" >>"$temporary_result"
printf '  "revision": "%s",\n' "$revision" >>"$temporary_result"
printf '  "check": "%s",\n' "$check_attribute" >>"$temporary_result"
printf '  "status": "%s",\n' "$status" >>"$temporary_result"
printf '  "exitCode": %s\n' "$exit_code" >>"$temporary_result"
printf '%s\n' '}' >>"$temporary_result"
mv "$temporary_result" "$result_path"
trap - EXIT

exit "$exit_code"
