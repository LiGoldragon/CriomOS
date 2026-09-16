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

if [ -s "$certificate" ] && [ -s "$key" ]; then
  exit 0
fi

umask 027
mkdir -p "$(dirname "$certificate")"
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 30 \
  -keyout "$key" -out "$certificate" \
  -subj "/CN=$xmpp_domain" \
  -addext "subjectAltName=DNS:$xmpp_domain,DNS:$forgejo_domain"
chown root:prometheus-service-tls "$certificate" "$key"
chmod 0640 "$certificate" "$key"
