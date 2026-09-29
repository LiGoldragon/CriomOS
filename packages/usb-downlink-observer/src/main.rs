//! Passive, boot-scoped evidence reducer for a non-Router USB downlink.
//! It observes kernel and Kea output only; this binary never sends a packet
//! or changes network-owner configuration.
use std::{
    collections::hash_map::DefaultHasher,
    env, fs,
    hash::{Hash, Hasher},
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixListener},
    path::Path,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Link {
    Absent,
    CarrierDown,
    CarrierUp,
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Peer {
    Unknown(&'static str),
    Present {
        source: &'static str,
        reference: String,
    },
    Stale {
        source: &'static str,
        reference: String,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Address {
    kind: &'static str,
    reference: String,
    fresh: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct State {
    link: Link,
    peer: Peer,
    addresses: Vec<Address>,
    sequence: u64,
}

impl State {
    fn initial() -> Self {
        Self {
            link: Link::Absent,
            peer: Peer::Unknown("no-matching-usb-ethernet"),
            addresses: vec![],
            sequence: 0,
        }
    }
    fn carrier(&mut self, present: bool, carrier: Option<bool>) {
        let link = if !present {
            Link::Absent
        } else {
            match carrier {
                Some(true) => Link::CarrierUp,
                Some(false) => Link::CarrierDown,
                None => Link::Unknown,
            }
        };
        let peer = match link {
            Link::CarrierDown => Peer::Unknown("carrier-down"),
            Link::CarrierUp => Peer::Unknown("no-current-evidence"),
            Link::Absent => Peer::Unknown("no-matching-usb-ethernet"),
            Link::Unknown => Peer::Unknown("link-state-unknown"),
        };
        if self.link != link || self.peer != peer {
            self.link = link;
            self.peer = peer;
            self.sequence += 1;
        }
    }
    fn witnessed_peer(&mut self, source: &'static str, raw: &str) {
        if self.link == Link::CarrierUp {
            self.peer = Peer::Present {
                source,
                reference: opaque(raw),
            };
            self.sequence += 1;
        }
    }
    fn startup_peer_without_source_age(&mut self, source: &'static str, raw: &str) {
        self.peer = Peer::Stale {
            source,
            reference: opaque(raw),
        };
        self.sequence += 1;
    }
    fn lease(&mut self, raw: &str, fresh: bool) {
        self.addresses = vec![Address {
            kind: "dhcp-lease",
            reference: opaque(raw),
            fresh,
        }];
        self.sequence += 1;
    }
    fn public_json(&self) -> String {
        let link = match self.link {
            Link::Absent => "linkAbsent",
            Link::CarrierDown => "carrierDown",
            Link::CarrierUp => "carrierUp",
            Link::Unknown => "carrierUnknown",
        };
        let peer = match &self.peer { Peer::Unknown(reason) => format!("{{\"peerUnknown\":{{\"reason\":\"{}\"}}}}", reason), Peer::Present { source, reference } => format!("{{\"peerPresent\":{{\"source\":\"{}\",\"evidenceRef\":\"{}\",\"freshnessBasis\":\"witnessed-source-event\"}}}}", source, reference), Peer::Stale { source, reference } => format!("{{\"peerEvidenceStale\":{{\"source\":\"{}\",\"evidenceRef\":\"{}\"}}}}", source, reference) };
        let addresses = self.addresses.iter().map(|a| format!("{{\"kind\":\"{}\",\"opaqueEvidenceRef\":\"{}\",\"freshness\":\"{}\",\"source\":\"kea\"}}", a.kind, a.reference, if a.fresh { "fresh" } else { "stale" })).collect::<Vec<_>>().join(",");
        format!("{{\"schemaVersion\":1,\"sequence\":{},\"observedAt\":{},\"link\":{{\"{}\":{{\"source\":\"kernel\"}}}},\"peer\":{},\"addresses\":[{}],\"recognition\":{{\"recognizerDisabled\":{{\"reason\":\"no-approved-link-identity\"}}}}}}", self.sequence, now(), link, peer, addresses)
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn opaque(value: &str) -> String {
    let mut h = DefaultHasher::new();
    value.hash(&mut h);
    format!("ephemeral:{:016x}", h.finish())
}
fn carrier(bridge: &str) -> (bool, Option<bool>) {
    // usb-downlink.nix is the sole bridge-member selector, so an entry in
    // brif is a matching USB Ethernet member.  The bridge device itself is
    // created even when no USB NIC exists and therefore cannot distinguish
    // LinkAbsent from CarrierDown.
    let members = match fs::read_dir(format!("/sys/class/net/{bridge}/brif")) {
        Ok(entries) => entries.filter_map(Result::ok).collect::<Vec<_>>(),
        Err(_) => return (false, None),
    };
    if members.is_empty() {
        return (false, None);
    }
    let states = members
        .iter()
        .filter_map(|entry| fs::read_to_string(entry.path().join("carrier")).ok())
        .map(|value| value.trim() == "1")
        .collect::<Vec<_>>();
    if states.is_empty() {
        (true, None)
    } else {
        (true, Some(states.into_iter().any(|up| up)))
    }
}
fn lease_snapshot() -> Option<String> {
    // Kea's memfile is an already-written record.  There is no witnessed DHCP
    // request or source-time freshness contract here, so every startup/reread
    // observation is deliberately stale and never changes PeerUnknown.
    fs::read_to_string("/var/lib/kea/dhcp4.leases")
        .ok()
        .and_then(|text| {
            text.lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .map(str::to_owned)
        })
}
fn bridge_member_event(bridge: &str, line: &str) -> bool {
    fs::read_dir(format!("/sys/class/net/{bridge}/brif"))
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().into_string().ok())
        .any(|member| line.contains(&format!(" dev {member}")))
}
fn write_state(dir: &Path, state: &State, raw: Option<&str>) {
    let public = state.public_json();
    let public_path = dir.join("public.json");
    let _ = fs::write(&public_path, &public);
    let _ = fs::set_permissions(public_path, fs::Permissions::from_mode(0o644));
    let raw_text = raw
        .map(|v| {
            format!(
                "{{\"rootRawAddressEvidence\":{{\"rawValue\":\"{}\"}}}}",
                v.replace('"', "")
            )
        })
        .unwrap_or_else(|| "{}".into());
    let root = dir.join("root-diagnostics.json");
    let _ = fs::write(&root, raw_text);
    let _ = fs::set_permissions(root, fs::Permissions::from_mode(0o600));
    println!("usb-downlink-observer transition {}", public);
}
fn serve(listener: UnixListener, shared: Arc<Mutex<State>>) {
    for stream in listener.incoming().flatten() {
        let _ = stream
            .try_clone()
            .and_then(|mut s| s.write_all(shared.lock().unwrap().public_json().as_bytes()));
    }
}
fn main() {
    let bridge = env::args().nth(1).unwrap_or_else(|| "br-downlink".into());
    let dir = std::path::PathBuf::from("/run/usb-downlink-observer");
    let _ = fs::create_dir_all(&dir);
    let socket = dir.join("public.sock");
    let _ = fs::remove_file(&socket);
    let shared = Arc::new(Mutex::new(State::initial()));
    let listener = UnixListener::bind(&socket).expect("bind public socket");
    let _ = fs::set_permissions(&socket, fs::Permissions::from_mode(0o644));
    {
        let state = shared.clone();
        thread::spawn(move || serve(listener, state));
    }
    // A bounded startup read is explicitly stale: read time cannot establish peer freshness.
    {
        let mut state = shared.lock().unwrap();
        let (present, up) = carrier(&bridge);
        state.carrier(present, up);
        let lease = lease_snapshot();
        if let Some(raw) = &lease {
            state.lease(raw, false);
        }
        write_state(&dir, &state, lease.as_deref());
    }
    // ip monitor subscribes to already-produced rtnetlink events. It has no mutating subcommand.
    let child = Command::new("ip")
        .args(["monitor", "link", "neigh", "dev", &bridge])
        .stdout(Stdio::piped())
        .spawn();
    if let Ok(mut child) = child {
        if let Some(out) = child.stdout.take() {
            let state = shared.clone();
            let dir = dir.clone();
            thread::spawn(move || {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    let mut s = state.lock().unwrap();
                    if line.contains("lladdr") {
                        s.witnessed_peer("rtnetlink-neighbor", &line);
                        write_state(&dir, &s, None);
                    }
                }
            });
        }
    }
    // bridge monitor reports FDB changes.  Events from another bridge are not
    // evidence for this edge: only the current usb-downlink bridge members
    // qualify, and only events observed after this process started are fresh.
    let fdb = Command::new("bridge")
        .args(["monitor", "fdb"])
        .stdout(Stdio::piped())
        .spawn();
    if let Ok(mut fdb) = fdb {
        if let Some(out) = fdb.stdout.take() {
            let state = shared.clone();
            let dir = dir.clone();
            let bridge = bridge.clone();
            thread::spawn(move || {
                for line in BufReader::new(out).lines().map_while(Result::ok) {
                    if bridge_member_event(&bridge, &line) {
                        let mut s = state.lock().unwrap();
                        s.witnessed_peer("bridge-fdb", &line);
                        write_state(&dir, &s, None);
                    }
                }
            });
        }
    }
    loop {
        thread::sleep(Duration::from_secs(2));
        let mut s = shared.lock().unwrap();
        let (present, up) = carrier(&bridge);
        let before = s.clone();
        s.carrier(present, up);
        if *s != before {
            write_state(&dir, &s, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn carrier_down_is_not_failure() {
        let mut s = State::initial();
        s.carrier(true, Some(false));
        assert_eq!(s.link, Link::CarrierDown);
        assert_eq!(s.peer, Peer::Unknown("carrier-down"));
        assert!(!s.public_json().contains("FAILURE"));
    }
    #[test]
    fn carrier_up_is_unknown_until_witnessed() {
        let mut s = State::initial();
        s.carrier(true, Some(true));
        assert_eq!(s.peer, Peer::Unknown("no-current-evidence"));
        s.witnessed_peer("bridge-fdb", "aa:bb:cc");
        assert!(matches!(s.peer, Peer::Present { .. }));
        assert!(s.public_json().contains("witnessed-source-event"));
    }
    #[test]
    fn startup_snapshot_never_becomes_fresh() {
        let mut s = State::initial();
        s.carrier(true, Some(true));
        s.startup_peer_without_source_age("bridge-fdb", "aa:bb:cc");
        assert!(matches!(s.peer, Peer::Stale { .. }));
        assert!(!s.public_json().contains("aa:bb:cc"));
    }
    #[test]
    fn lease_is_opaque_and_not_peer_identity() {
        let mut s = State::initial();
        s.carrier(true, Some(true));
        s.lease("10.44.0.148 aa:bb:cc", false);
        assert!(matches!(s.peer, Peer::Unknown(_)));
        let public = s.public_json();
        assert!(public.contains("dhcp-lease"));
        assert!(!public.contains("10.44.0.148"));
        assert!(!public.contains("aa:bb:cc"));
    }
}
