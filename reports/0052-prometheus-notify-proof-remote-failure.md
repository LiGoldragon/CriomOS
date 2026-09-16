# Notify proof remote fixture failure

The remote realization of `55b75fa357cd98ba26090fbee2e8854598cb0796`
reached the Python fixture and failed with `IndentationError` at the body of
`OfflineTwomemoTransport`.

The Nix indented string had already removed the common four-space prefix. The
fixture then ran an additional `sed` command that removed the remaining class
method indentation. The failure occurred before any OMEMO encryption ran. The
next source revision removes that redundant command; no runtime state, account,
or secret was involved.
