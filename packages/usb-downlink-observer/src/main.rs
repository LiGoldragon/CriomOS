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
fn json_string(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len() + 2);
    escaped.push('"');
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            '\u{08}' => escaped.push_str("\\b"),
            '\u{0c}' => escaped.push_str("\\f"),
            control if control.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", control as u32))
            }
            ordinary => escaped.push(ordinary),
        }
    }
    escaped.push('"');
    escaped
}
fn carrier(bridge: &str) -> (bool, Option<bool>) {
    carrier_in(Path::new("/sys/class/net"), bridge)
}
fn carrier_in(net: &Path, bridge: &str) -> (bool, Option<bool>) {
    // usb-downlink.nix is the sole bridge-member selector, so an entry in
    // brif is a matching USB Ethernet member.  The bridge device itself is
    // created even when no USB NIC exists and therefore cannot distinguish
    // LinkAbsent from CarrierDown.
    let members = match fs::read_dir(net.join(bridge).join("brif")) {
        Ok(entries) => entries.filter_map(Result::ok).collect::<Vec<_>>(),
        Err(_) => return (false, None),
    };
    if members.is_empty() {
        return (false, None);
    }
    let states = members
        .iter()
        // `brif/<member>` proves bridge membership, but Linux resolves that
        // entry to the member's `brport` directory.  Carrier belongs to the
        // NIC device, so read it through the matching `class/net/<member>`
        // entry instead of treating a missing brport/carrier as unknown.
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter_map(|member| fs::read_to_string(net.join(member).join("carrier")).ok())
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
    let root = dir.join("root-diagnostics.json");
    if let Some(raw) = raw {
        let raw_text = format!(
            "{{\"rootRawAddressEvidence\":{{\"rawValue\":{}}}}}",
            json_string(raw)
        );
        let _ = fs::write(&root, raw_text);
    } else if !root.exists() {
        // A host with no raw address evidence still gets a root-only view.
        let _ = fs::write(&root, "{}");
    }
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
    fn fresh_post_start_fdb_promotes_peer_without_known_identity() {
        let mut s = State::initial();
        s.carrier(true, Some(true));
        s.witnessed_peer("bridge-fdb", "fresh post-start FDB entry");
        assert!(matches!(s.peer, Peer::Present { .. }));
        let public = s.public_json();
        assert!(public.contains("witnessed-source-event"));
        assert!(public.contains("recognizerDisabled"));
        assert!(!public.contains("knownClusterNode"));
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
        s.lease("10.44.0.148 aa:bb:cc duid:00:01:00:01:de:ad:be:ef", false);
        assert!(matches!(s.peer, Peer::Unknown(_)));
        let public = s.public_json();
        assert!(public.contains("dhcp-lease"));
        assert!(!public.contains("10.44.0.148"));
        assert!(!public.contains("aa:bb:cc"));
        assert!(!public.contains("00:01:00:01:de:ad:be:ef"));
    }
    #[test]
    fn link_absent_and_carrier_down_are_distinct() {
        let mut state = State::initial();
        state.carrier(false, None);
        assert_eq!(state.link, Link::Absent);
        assert_eq!(state.peer, Peer::Unknown("no-matching-usb-ethernet"));
        state.carrier(true, Some(false));
        assert_eq!(state.link, Link::CarrierDown);
        assert_eq!(state.peer, Peer::Unknown("carrier-down"));
    }
    #[test]
    fn identical_carrier_samples_do_not_emit_a_duplicate_transition() {
        let mut state = State::initial();
        state.carrier(true, Some(true));
        let sequence = state.sequence;
        state.carrier(true, Some(true));
        assert_eq!(state.sequence, sequence);
    }
    #[test]
    fn bridge_member_carrier_comes_from_the_member_nic() {
        let directory = std::env::temp_dir().join(format!("usb-downlink-sysfs-{}", now()));
        let net = directory.join("class/net");
        let bridge = net.join("br-downlink");
        let member = net.join("enxusb0");
        fs::create_dir_all(bridge.join("brif")).unwrap();
        fs::create_dir_all(member.join("brport")).unwrap();
        fs::write(member.join("carrier"), "1\n").unwrap();
        // Linux brif entries resolve to the member's brport directory, which
        // carries bridge-port attributes but no NIC carrier file.
        std::os::unix::fs::symlink("../../../enxusb0/brport", bridge.join("brif/enxusb0")).unwrap();
        assert!(bridge
            .join("brif/enxusb0")
            .join("carrier")
            .metadata()
            .is_err());
        assert_eq!(carrier_in(&net, "br-downlink"), (true, Some(true)));
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn raw_diagnostic_survives_a_later_redacted_transition() {
        let directory = std::env::temp_dir().join(format!("usb-downlink-observer-{}", now()));
        fs::create_dir_all(&directory).unwrap();
        let mut state = State::initial();
        state.carrier(true, Some(true));
        let raw = "10.44.0.148 aa:bb:cc duid:00:01:00:01:de:ad:be:ef\\newline\ncontrol:\u{0001}";
        write_state(&directory, &state, Some(raw));
        state.witnessed_peer("bridge-fdb", "fresh fdb entry");
        write_state(&directory, &state, None);
        let public = fs::read_to_string(directory.join("public.json")).unwrap();
        let root = fs::read_to_string(directory.join("root-diagnostics.json")).unwrap();
        assert!(!public.contains("10.44.0.148"));
        assert!(!public.contains("aa:bb:cc"));
        assert!(root.contains("10.44.0.148"));
        assert!(root.contains("aa:bb:cc"));
        assert!(
            root.contains("\\\\newline\\ncontrol:\\u0001"),
            "root JSON must escape slash, newline, and control data: {root}"
        );
        assert_eq!(
            root,
            format!(
                "{{\"rootRawAddressEvidence\":{{\"rawValue\":{}}}}}",
                json_string(raw)
            ),
            "root diagnostic is parseable JSON assembled from one escaped string"
        );
        assert_eq!(
            fs::metadata(directory.join("root-diagnostics.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
