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
pkgs.runCommand "prometheus-notify-proof"
  { nativeBuildInputs = [ python pkgs.gnutar ]; }
  ''
    set -eu
    mkdir source
    tar -xzf ${upstreamTests} --strip-components=1 -C source
    cp ${../../packages/prometheus-notify-proof.py} notify_proof.py
    cat > fixture.py <<'PY'
    import asyncio
    import sys

    sys.path.insert(0, ".")
    sys.path.insert(0, "source")

    import omemo
    import twomemo
    from twomemo.twomemo import ContentImpl
    from notify_proof import (
        EncryptedEnvelope,
        OMEMO2_NAMESPACE,
        Notify,
        NotifyError,
        BareJid,
        deliver_encrypted,
        main,
        parse_notify,
    )
    from tests.in_memory_storage import InMemoryStorage
    from tests.session_manager_impl import TrustLevel, make_session_manager_impl

    ALICE = "alice@example.org"
    BOB = "bob@example.org"

    class OfflineTwomemoTransport:
        def __init__(self, alice, bob):
            self.alice = alice
            self.bob = bob

        async def encrypt(self, recipient, plaintext):
            assert recipient.value == BOB
            messages, errors = await self.alice.encrypt(
                bare_jids=frozenset({recipient.value}),
                plaintext={OMEMO2_NAMESPACE: plaintext},
                backend_priority_order=[OMEMO2_NAMESPACE],
            )
            assert len(messages) == 1
            assert not errors
            message = next(iter(messages))
            assert message.namespace == "urn:xmpp:omemo:2"
            return EncryptedEnvelope(message)

        async def decrypt(self, envelope):
            plaintext, _, _ = await self.bob.decrypt(envelope.value)
            assert plaintext is not None
            return plaintext

    async def make_transport():
        bundles = {}
        device_lists = {}
        AliceSessionManager = make_session_manager_impl(ALICE, bundles, device_lists, [])
        BobSessionManager = make_session_manager_impl(BOB, bundles, device_lists, [])
        alice_storage = InMemoryStorage()
        bob_storage = InMemoryStorage()
        alice = await AliceSessionManager.create(
            backends=[twomemo.Twomemo(alice_storage)], storage=alice_storage,
            own_bare_jid=ALICE, initial_own_label=None,
            undecided_trust_level_name=TrustLevel.UNDECIDED.name,
        )
        bob = await BobSessionManager.create(
            backends=[twomemo.Twomemo(bob_storage)], storage=bob_storage,
            own_bare_jid=BOB, initial_own_label=None,
            undecided_trust_level_name=TrustLevel.UNDECIDED.name,
        )
        await alice.after_history_sync()
        await bob.after_history_sync()
        await alice.refresh_device_list(OMEMO2_NAMESPACE, BOB)
        await bob.refresh_device_list(OMEMO2_NAMESPACE, ALICE)
        return OfflineTwomemoTransport(alice, bob), alice, bob

    async def encrypted_round_trip():
        transport, alice, bob = await make_transport()
        try:
            await deliver_encrypted(
                Notify(BareJid(BOB), "fixture encrypted Notify"), transport
            )
        finally:
            await alice.shutdown()
            await bob.shutdown()

    async def tamper_is_rejected():
        transport, alice, bob = await make_transport()
        try:
            envelope = await transport.encrypt(BareJid(BOB), b"tamper fixture")
            message = envelope.value
            tampered_content = ContentImpl(
                message.content.ciphertext[:-1] + bytes([message.content.ciphertext[-1] ^ 1])
            )
            tampered = EncryptedEnvelope(message._replace(content=tampered_content))
            try:
                await transport.decrypt(tampered)
            except omemo.DecryptionFailed:
                pass
            else:
                raise AssertionError("tampered OMEMO payload decrypted")
        finally:
            await alice.shutdown()
            await bob.shutdown()

    assert OMEMO2_NAMESPACE == "urn:xmpp:omemo:2"
    parsed = parse_notify("Notify.{ «bob@example.org» «fixture encrypted Notify» }")
    assert parsed.recipient.value == BOB
    assert main(["Notify.{ «bob@example.org» «accepted» }"]) == 0
    for malformed in [
        "Notify.{ bob@example.org «missing guillemets» }",
        "Notify.{ «bob@example.org» missing-guillemets }",
        "Notify.{ «bob@example.org/resource» «resource is not bare» }",
        "Other.{ «bob@example.org» «wrong variant» }",
    ]:
        try:
            parse_notify(malformed)
        except NotifyError:
            pass
        else:
            raise AssertionError("malformed Notify input was accepted")
    try:
        parse_notify("Notify.{ «bob@example.org» «" + "x" * 1025 + "» }")
    except NotifyError:
        pass
    else:
        raise AssertionError("oversized Notify body was accepted")
    asyncio.run(encrypted_round_trip())
    asyncio.run(tamper_is_rejected())
    PY
    ${python}/bin/python fixture.py
    touch "$out"
  ''
