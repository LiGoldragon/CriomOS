# Prometheus service SOPS policy receipt

This proposal preserves disabled behavior, explicit certificate/key runtime paths, and the default generated self-signed fallback. A non-null `criomos.prometheusServiceProvider.tls.sopsFileKey` selects two runtime SOPS declarations from `inputs.secrets.sopsFiles`; it does not read or decrypt a secret during evaluation.

The public fixture is synthetic, encrypted-shaped, and evaluation-only. It is not a certificate, key, deployment secret, or production material. The focused policy check forces disabled, direct-path, self-signed, and SOPS enabled `system.build.toplevel` derivations; it uses `tryEval` to require failure for missing-map and explicit-path conflict configurations, and checks Prosody PEP/MAM/carbons/smacks options. These settings do not establish an OMEMO 2 client or bot end-to-end proof.

Validation is appended after the remote focused policy check.

Validation: the authorized isolated evaluator imported this committed check with pinned public nixpkgs `f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1` and sops-nix `a8627b21b9107c5711c96b84f32a9a4b3d45295f`. Remote-only Nix built the focused `prometheus-service-provider-policy` derivation on Prometheus with `--max-jobs 0 --no-link` and exited 0. This is a module-policy evaluation, not a full host build, activation, SOPS decryption, or runtime service proof.
