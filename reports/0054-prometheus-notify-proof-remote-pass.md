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
