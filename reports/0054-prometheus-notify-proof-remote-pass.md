# Notify proof remote pass

The focused `prometheus-notify-proof` check at
`9b550876b0cbb1e361d6bfd0330ba456c9683d51` evaluated and completed on the
configured Prometheus remote builder with exit code 0.

The fixture accepted the exact proposal-only `Notify.{ «bare-jid» «body» }`
subset, rejected malformed input, a JID resource, and a 1025-byte body. It
used the pinned `twomemo` dependency with `urn:xmpp:omemo:2` for a disposable
in-memory encrypted round trip and rejected a modified ciphertext byte. The
CLI result is `NotifyValidatedOffline.{}` and represents parsing only; it does
not enqueue or deliver a notification. No account, live XMPP session, or
secret was used.

## Correction: accepted syntax depends on the producer revision

The original spelling/recipient-quoting claim above was inaccurate for the struct-only producer audited at CriomOS 9dd0e63: that parser consumed positional `{ bob@example.org «body» }`, with a bare recipient accepted. The later producer aec96bf40807f4452aaf3729b7e834eb6182b44f introduces `NotifyEnvelope.[Notify.Notify]`, so the current CLI accepts `Notify.{ bob@example.org «body» }`. It also declares the validation outcomes as contract types. Neither form implies delivery. See 0055 for the changed contract and 0059 for a newly captured check of current sources; earlier pass receipts do not prove later source revisions.
