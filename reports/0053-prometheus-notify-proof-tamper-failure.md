# Notify proof tamper-fixture failure

The remote realization of `a9a9933f30d873773a92e8f8df508cf1619fce36`
completed parser validation and the valid OMEMO round trip, then failed while
constructing the tampered payload. `ContentImpl` is implemented by
`twomemo.twomemo` but is not re-exported by the top-level `twomemo` module.

The next revision imports that implementation type from its defining module.
The failure occurred before tampered-message decryption; no account, network
session, or secret was accessed.
