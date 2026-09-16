#!/usr/bin/env python3
"""Offline OMEMO2 fixture for an already-validated Notify payload.

Datom parsing belongs to the shared signal-message command.  This fixture
only proves that bytes can make an encrypted in-memory round trip; it has no
XMPP account, network endpoint, or delivery action.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


OMEMO2_NAMESPACE = "urn:xmpp:omemo:2"


class TransportError(RuntimeError):
    """An encrypted transport did not preserve the submitted bytes."""


@dataclass(frozen=True)
class BareJid:
    value: str


@dataclass(frozen=True)
class EncryptedEnvelope:
    """Opaque encrypted material; it deliberately has no plaintext field."""

    value: object


class NotifyTransport(Protocol):
    """The only delivery seam accepted by the proof."""

    async def encrypt(self, recipient: BareJid, plaintext: bytes) -> EncryptedEnvelope: ...

    async def decrypt(self, envelope: EncryptedEnvelope) -> bytes: ...


async def deliver_encrypted(recipient: BareJid, plaintext: bytes, transport: NotifyTransport) -> None:
    """Prove one validated payload survives only an encrypted transport."""
    envelope = await transport.encrypt(recipient, plaintext)
    recovered = await transport.decrypt(envelope)
    if recovered != plaintext:
        raise TransportError("encrypted transport did not preserve Notify bytes")
