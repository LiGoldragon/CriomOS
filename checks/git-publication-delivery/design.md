# Git publication delivery

One accepted Git update serves two receivers. The mirror queues a repository to reconcile its current refs. The publication outbox holds exact updates and retires each one only when Curriculum accepts its own digest. The two queues retain different things.

```ethos sketch
Types
[ RepositoryName.String
  ReferenceName.String
  PublicationStream.{ RepositoryName ReferenceName }
  ReceiverHost.String
  OutboxDirectory.String
  PublicationRoute.{ ReceiverHost Vector<PublicationStream> OutboxDirectory }
  ObjectId.String
  Publication.{ PublicationStream Old.ObjectId New.ObjectId }
  PublicationDigest.String
  Announcement.[ PublicationReceived.Publication ]
  Refusal.[ Untrusted Invalid Unavailable ]
  Admission.[ Accepted.PublicationDigest Refused.Refusal ] ]
```

```mermaid
flowchart LR
    a["Git accepts one main update"] --> m["Mirror work queue: reconcile latest refs"]
    a --> b["Publication outbox: retain exact update"]
    sn["Sender network announces a configured return"] --> dr["Drain pending publications"]
    rn["Receiver network or SSH announces readiness"] --> w["Authenticated sender wake"]
    cr["Curriculum binds its admission socket"] --> w
    b --> dr
    dr --> s["Restricted SSH receive command"]
    w --> dr
    s --> c["Announce Publication to configured Curriculum"]
    c --> i["Compute digest and admit durably once"]
    i --> k["Return Admission through receive command"]
    k --> x["Sender retires only on matching Accepted"]
```

The outbox and Curriculum admission cover the handoff’s two durable states. The receive command forwards the publication and returns the consumer’s admission; it holds no third copy. A refusal, unreachable consumer or lost reply leaves the sender's record for replay. The wake command marks pending delivery and returns through its exit status.

Deployment supplies the receiver host, stream selectors and outbox directory. The landed transport accepts a configurable receiver and repository list and still fixes the ref and outbox path; the route configuration is a separate change. The network observers act on Linux link and route notifications for the configured peer path. The receiver also wakes when its SSH service announces readiness or its Curriculum listener binds. A network owner can announce additional returns by starting a configured target, including a recovery invisible to the local route. No host wiring is part of this release.

**Proof:** The targeted Nix check exercises Git admission, transport failures and replay; `ssh_witness.py` exercises authenticated storage and wake across a loopback listener; `curriculum_witness.py` exercises the real Curriculum binary’s refusal, durable admission and deduplication.
