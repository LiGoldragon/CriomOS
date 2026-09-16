# Offline Notify proof proposal

CriomOS has no existing `Notify` producer contract. This proof therefore does
not claim adoption by Message, Cloud, or a live XMPP component.

It proposes one exact inline Datom subset for the standalone CLI:

`Notify.{ «bare-jid» «body» }`

The spelling follows the existing Message convention: a single inline Datom
value, a `Variant.{ ... }` payload, and guillemet text. This proof is not a
general Datom parser. It rejects every other shape, requires one command-line
argument, limits the whole input to 4096 UTF-8 bytes and the body to 1024 UTF-8
bytes, and rejects malformed or empty bare JIDs and bodies.

The check creates two disposable in-memory OMEMO identities with the pinned
`twomemo` 2.1.0 dependency. Its typed transport boundary accepts only an opaque
encrypted envelope: there is no plaintext transport method or fallback. The
fixture uses `urn:xmpp:omemo:2`, decrypts the valid envelope, and verifies that
one modified ciphertext byte is rejected by OMEMO authentication. It creates
no account, contacts no XMPP service, and reads no secret.

Remaining work before any live XMPP use is deliberately outside this proof:

1. A producer-owned Notify contract must be added to the appropriate Message
   interface and parsed with its shared `datom-codec` dependency.
2. An account identity, authenticated XMPP session, persistent OMEMO storage,
   device-list/bundle publication, and an explicit trust policy must be wired.
3. The encrypted envelope must be serialized into an XMPP stanza and sent with
   delivery, retry, and error handling. No live transport or session exists
   here.
