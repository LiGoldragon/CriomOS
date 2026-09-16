# Prometheus TLS policy remote pass

The focused policy fixture at
`920abff090de1c8330f0179a3fb00a10c977ed96` evaluated successfully and its
single derivation completed on the configured Prometheus remote builder with
exit code 0.

The disposable fixture exercised generated certificate SANs for
`chat.example` and `git.example`, mode `0640`, idempotence, invalid-domain
refusal, and incomplete-pair refusal. No production certificate or key was
generated or read.
