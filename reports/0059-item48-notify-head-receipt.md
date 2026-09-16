# Item 48: current Notify proof receipt

Root ran the focused check at CriomOS source 8c3d4aacea5e77feb50a6acd6ac3ec7015645a7c, with pinned producer aec96bf40807f4452aaf3729b7e834eb6182b44f and nixpkgs f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1. Exact command:

```sh
nix build --impure --no-link --print-build-logs --max-jobs 0 --option substituters https://cache.nixos.org/ --option connect-timeout 5 --expr 'let inputs = { signal-message = builtins.getFlake "github:LiGoldragon/signal-message/aec96bf40807f4452aaf3729b7e834eb6182b44f"; }; pkgs = (builtins.getFlake "github:NixOS/nixpkgs/f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1").legacyPackages.x86_64-linux; in import /tmp/criomos-prometheus-poc.i43UcY/checks/prometheus-notify-proof { inherit inputs pkgs; }'
```

Captured terminal exit 0. Nix built `/nix/store/z0a2w1hyrbv3vrn4qh07zs0wvy64r4lv-prometheus-notify-proof.drv` on `ssh-ng://nix-ssh@prometheus.goldragon.criome` and copied output `/nix/store/q4jxbdwvpi1w0g09mysjh2dyvfjqj09z-prometheus-notify-proof`.

Output included `NotifyValidatedOffline.{}`, `NotifyRejected.Malformed`, `NotifyRejected.Body`, and `NotifyRejected.InputTooLarge`. Root read the pinned producer's CLI and ethos: these are serialized `NotifyValidationOutcome` variants, not println literals. The check then ran real OMEMO library roundtrip and tamper rejection using synthetic identities. Device-list warnings from the synthetic managers appeared; no transport was attempted.

This proves current packaged parser behavior and the offline encryption fixture, not a live chime bot. The fixed-output upstream test-helper download makes inputs reproducible but may need network access on a cold store. No account, persistent OMEMO trust/device state, PEP publication, Prosody transport, Cloudflare issuance or consumer activation is established. The adapter remains a proposal pin, not a main integration. Existing TLS renewal and SOPS source receipts are 0057 and 0058; VM activation proof is a separate work item.
