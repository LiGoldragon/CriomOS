set -eu

if [ "$#" -ne 4 ]; then
  printf '%s\n' 'usage: prometheus-service-tls CERTIFICATE KEY XMPP_DOMAIN FORGEJO_DOMAIN' >&2
  exit 64
fi

certificate=$1
key=$2
xmpp_domain=$3
forgejo_domain=$4

valid_domain() {
  local domain=$1
  local label
  local -a labels

  [[ -n "$domain" && ${#domain} -le 253 && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- && "$label" != *[!A-Za-z0-9-]* ]] || return 1
  done
}

valid_domain "$xmpp_domain" || { printf '%s\n' 'invalid XMPP domain' >&2; exit 64; }
valid_domain "$forgejo_domain" || { printf '%s\n' 'invalid Forgejo domain' >&2; exit 64; }

if [ -e "$certificate" ] || [ -e "$key" ]; then
  [ -s "$certificate" ] && [ -s "$key" ] || { printf '%s\n' 'incomplete existing TLS pair' >&2; exit 1; }
  openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || { printf '%s\n' 'invalid existing TLS certificate' >&2; exit 1; }
  san_output=$(openssl x509 -in "$certificate" -noout -ext subjectAltName)
  [[ "$san_output" == *"DNS:$xmpp_domain, DNS:$forgejo_domain"* ]] || { printf '%s\n' 'existing TLS certificate SANs do not match service domains' >&2; exit 1; }
  cmp <(openssl x509 -in "$certificate" -noout -pubkey | openssl pkey -pubin -outform DER) <(openssl pkey -in "$key" -pubout -outform DER) || { printf '%s\n' 'existing TLS certificate and key do not match' >&2; exit 1; }
  openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 && exit 0
fi

root=$(dirname "$(dirname "$certificate")")
releases="$root/releases"
mkdir -p "$releases"
chown root:prometheus-service-tls "$releases"
chmod 0750 "$releases"
release=$(mktemp -d "$releases/.new.XXXXXX")
trap 'rm -rf "$release" "$root/.next"' EXIT
umask 027
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 30 \
  -keyout "$release/key.pem" -out "$release/certificate.pem" \
  -subj "/CN=$xmpp_domain" \
  -addext "subjectAltName=DNS:$xmpp_domain,DNS:$forgejo_domain"
chown root:prometheus-service-tls "$release" "$release/certificate.pem" "$release/key.pem"
chmod 0750 "$release"
chmod 0640 "$release/certificate.pem" "$release/key.pem"
ln -s "releases/$(basename "$release")" "$root/.next"
mv -Tf "$root/.next" "$root/current"
trap - EXIT
