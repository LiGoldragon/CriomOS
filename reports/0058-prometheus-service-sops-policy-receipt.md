# Prometheus service SOPS policy receipt

This proposal preserves disabled behavior, explicit certificate/key runtime paths, and the default generated self-signed fallback. A non-null `criomos.prometheusServiceProvider.tls.sopsFileKey` selects two runtime SOPS declarations from `inputs.secrets.sopsFiles`; it does not read or decrypt a secret during evaluation.

The public fixture is synthetic, encrypted-shaped, and evaluation-only. It is not a certificate, key, deployment secret, or production material. The focused policy check forces disabled, direct-path, self-signed, and SOPS enabled `system.build.toplevel` derivations; it uses `tryEval` to require failure for missing-map and explicit-path conflict configurations, and checks Prosody PEP/MAM/carbons/smacks options. These settings do not establish an OMEMO 2 client or bot end-to-end proof.

Validation is appended after the remote focused policy check.
