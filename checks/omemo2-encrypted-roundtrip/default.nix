{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [
    ps.omemo
    ps.twomemo
    ps.typing-extensions
  ]);
  upstreamTests = pkgs.fetchurl {
    url = "https://codeload.github.com/Syndace/python-omemo/tar.gz/9a1ffdd";
    hash = "sha256-Rt1jEq7nVbp33d0pwczJg4SpCjQhf/+2cyQhFNawKqI=";
  };
in
pkgs.runCommand "omemo2-encrypted-roundtrip"
  {
    nativeBuildInputs = [ pkgs.gnutar ];
  }
  ''
      set -eu
      mkdir source
      tar -xzf ${upstreamTests} --strip-components=1 -C source

      cat > roundtrip.py <<'PY'
    import asyncio
    import sys

    sys.path.insert(0, "source")

    import twomemo
    from tests.in_memory_storage import InMemoryStorage
    from tests.session_manager_impl import make_session_manager_impl, TrustLevel

    NAMESPACE = twomemo.twomemo.NAMESPACE
    ALICE = "alice@example.org"
    BOB = "bob@example.org"

    async def main():
        bundles = {}
        device_lists = {}
        alice_queue = []
        bob_queue = []

        AliceSessionManager = make_session_manager_impl(ALICE, bundles, device_lists, alice_queue)
        BobSessionManager = make_session_manager_impl(BOB, bundles, device_lists, bob_queue)
        alice_storage = InMemoryStorage()
        bob_storage = InMemoryStorage()

        alice = await AliceSessionManager.create(
            backends=[twomemo.Twomemo(alice_storage)],
            storage=alice_storage,
            own_bare_jid=ALICE,
            initial_own_label=None,
            undecided_trust_level_name=TrustLevel.UNDECIDED.name,
        )
        bob = await BobSessionManager.create(
            backends=[twomemo.Twomemo(bob_storage)],
            storage=bob_storage,
            own_bare_jid=BOB,
            initial_own_label=None,
            undecided_trust_level_name=TrustLevel.UNDECIDED.name,
        )
        try:
            await alice.after_history_sync()
            await bob.after_history_sync()
            await alice.refresh_device_list(NAMESPACE, BOB)
            await bob.refresh_device_list(NAMESPACE, ALICE)
            secret = b"fixture-encrypted-message"
            messages, errors = await alice.encrypt(
                bare_jids=frozenset({BOB}),
                plaintext={NAMESPACE: secret},
                backend_priority_order=[NAMESPACE],
            )
            assert len(messages) == 1
            assert not errors
            message = next(iter(messages))
            plaintext, _, _ = await bob.decrypt(message)
            assert plaintext == secret
        finally:
            await alice.shutdown()
            await bob.shutdown()

    asyncio.run(main())
    PY

      ${python}/bin/python roundtrip.py
      touch "$out"
  ''
