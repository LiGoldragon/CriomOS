# Current offline Notify Datom receipt

This corrects the historical regex-era receipts in 0051 and 0054.  The current
consumer accepts the shared typed constructor:

```text
Notify.{ bob@example.org «hello «quoted\» text» }
```

The inner closing guillemet is escaped with one backslash.  A bare positional
struct is not the current CLI contract.

Producer revision `aec96bf40807f4452aaf3729b7e834eb6182b44f` passed the remote
`test-notify-datom` check (2 tests).  Consumer revision
`e27a61b026a8bdbdad564cbc89190e7bceaa5b7f` passed the remote focused
`prometheus-notify-proof` derivation.  That proof invokes the packaged
`notify-datom` command with the constructor above, rejects `Submit.{ x }`, and
rejects a 1025-byte body and a 4097-byte input.

The command parses and validates only.  Its typed outcome is
`NotifyValidatedOffline.{}` on success and a typed `NotifyRejected.*` outcome
on failure; it has no XMPP transport, account, credentials, or delivery path.

The full CriomOS check attribute still needs the normal deployment materializer
to provide its required system input.  The focused receipt evaluated the same
pinned sources with `x86_64-linux`; it does not claim a full system evaluation.
