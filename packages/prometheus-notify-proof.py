#!/usr/bin/env python3
"""Offline-only Notify proof using the ecosystem's inline Datom spelling.

This is deliberately a strict, proposal-only subset, not a general Datom
parser and not a Message contract.  It accepts precisely one input shaped as
``Notify.{ «bare-jid» «body» }``. The offline fixture supplies the encrypted
transport; this CLI only validates input and never claims to enqueue delivery.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from typing import Protocol


MAX_INPUT_BYTES = 4096
MAX_BODY_BYTES = 1024
OMEMO2_NAMESPACE = "urn:xmpp:omemo:2"

_NOTIFY = re.compile(r"^Notify\.\{\s+«([^«»\r\n]+)»\s+«([^«»\r\n]*)»\s+\}$")


class NotifyError(ValueError):
    """An input is outside the narrowly proposed Notify contract."""


class TransportError(RuntimeError):
    """An encrypted transport did not preserve the submitted bytes."""


@dataclass(frozen=True)
class BareJid:
    value: str


@dataclass(frozen=True)
class Notify:
    recipient: BareJid
    body: str


@dataclass(frozen=True)
class EncryptedEnvelope:
    """Opaque encrypted material; it deliberately has no plaintext field."""

    value: object


class NotifyTransport(Protocol):
    """The only delivery seam accepted by the proof."""

    async def encrypt(self, recipient: BareJid, plaintext: bytes) -> EncryptedEnvelope: ...

    async def decrypt(self, envelope: EncryptedEnvelope) -> bytes: ...


def parse_notify(text: str) -> Notify:
    """Parse the exact offline POC subset of the established inline Datom form."""
    if len(text.encode("utf-8")) > MAX_INPUT_BYTES:
        raise NotifyError("Notify input exceeds 4096 UTF-8 bytes")
    match = _NOTIFY.fullmatch(text)
    if match is None:
        raise NotifyError("expected Notify.{ «bare-jid» «body» }")
    recipient_text, body = match.groups()
    if recipient_text.count("@") != 1:
        raise NotifyError("recipient must be a bare JID")
    localpart, domain = recipient_text.split("@", 1)
    if (
        not localpart
        or not domain
        or "/" in recipient_text
        or any(character.isspace() for character in recipient_text)
    ):
        raise NotifyError("recipient must be a bare JID")
    if not body:
        raise NotifyError("Notify body must not be empty")
    if len(body.encode("utf-8")) > MAX_BODY_BYTES:
        raise NotifyError("Notify body exceeds 1024 UTF-8 bytes")
    return Notify(BareJid(recipient_text), body)


async def deliver_encrypted(notify: Notify, transport: NotifyTransport) -> None:
    """Prove one parsed notification survives only an encrypted transport."""
    plaintext = notify.body.encode("utf-8")
    envelope = await transport.encrypt(notify.recipient, plaintext)
    recovered = await transport.decrypt(envelope)
    if recovered != plaintext:
        raise TransportError("encrypted transport did not preserve Notify bytes")


def main(arguments: list[str]) -> int:
    if len(arguments) != 1:
        print(f"expected exactly one inline Datom value, received {len(arguments)}", file=sys.stderr)
        return 2
    try:
        parse_notify(arguments[0])
    except NotifyError as error:
        print(f"malformed Notify Datom: {error}", file=sys.stderr)
        return 2
    print("NotifyValidatedOffline.{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
