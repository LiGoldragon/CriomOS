# Current TLS renewal and reload receipt

Revision `1bddabcf36c86b0c42f4dfc1ca5c7a6c24655248` passed the remote focused
`prometheus-service-provider-policy` derivation (exit 0), using remote-only
Nix with the pinned CriomOS, nixpkgs, and sops-nix sources on `x86_64-linux`.

The policy fixture covers initial self-signed publication, idempotence,
near-expiry renewal to a different atomically published `current` target, and
rejection paths retaining the published target. It also checks release and
file permissions.

The declarative TLS preparation unit compares the previous and current release
target and requests a nonblocking Prosody/Forgejo reload only when an existing
target changed. Initial creation has no reload request. The focused check
asserts that unit command text. It does not boot systemd or capture a live
`systemctl` invocation, so that runtime reload behavior remains unproven. No
host service was activated or restarted.
