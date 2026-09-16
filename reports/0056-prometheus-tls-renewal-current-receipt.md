# Prometheus TLS renewal focused receipt

Consumer revision `7201e1e161c4a586622a067965d8c49efd0936bd` passed the remote,
focused `prometheus-service-provider-policy` derivation with remote-only Nix
execution (`--max-jobs 0 --no-link`). The check evaluates the pinned CriomOS
source with the pinned nixpkgs and sops-nix inputs and `x86_64-linux`.

The fixture creates a valid self-signed pair, verifies idempotence, creates a
one-day replacement pair, and verifies that renewal atomically changes the
`current` release symlink and leaves a replacement valid for at least seven
days. It also verifies malformed-domain rejection keeps the published link,
and preserves the existing partial-pair refusal. Release directories are mode
0750 and certificate/key files mode 0640.

The `PathChanged` reload declaration is present but this focused shell fixture
does not start systemd or witness that a parent-symlink swap triggers it. This
receipt therefore does not claim a live service reload or full runtime TLS
lifecycle proof. No service was activated or restarted during this check.
