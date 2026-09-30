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
    sync::{mpsc, Arc, Mutex},
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
    fn carrier(&mut self, present: bool, carrier: Option<bool>) -> bool {
        let link = if !present {
            Link::Absent
        } else {
            match carrier {
                Some(true) => Link::CarrierUp,
                Some(false) => Link::CarrierDown,
                None => Link::Unknown,
            }
        };
        if self.link == link {
            // Carrier is a link dimension. Re-reading the same classification
            // must not erase fresher peer evidence from a monitor event.
            return false;
        }
        let peer = match link {
            Link::CarrierDown => Peer::Unknown("carrier-down"),
            Link::CarrierUp => Peer::Unknown("no-current-evidence"),
            Link::Absent => Peer::Unknown("no-matching-usb-ethernet"),
            Link::Unknown => Peer::Unknown("link-state-unknown"),
        };
        self.link = link;
        self.peer = peer;
        self.sequence += 1;
        true
    }
    fn witnessed_peer(&mut self, source: &'static str, raw: &str) -> bool {
        if self.link == Link::CarrierUp {
            let peer = Peer::Present {
                source,
                reference: opaque(raw),
            };
            if self.peer != peer {
                self.peer = peer;
                self.sequence += 1;
                return true;
            }
        }
        false
    }
    fn startup_peer_without_source_age(&mut self, source: &'static str, raw: &str) {
        let peer = Peer::Stale {
            source,
            reference: opaque(raw),
        };
        if self.peer != peer {
            self.peer = peer;
            self.sequence += 1;
        }
    }
    fn lease(&mut self, raw: &str, fresh: bool) {
        let addresses = vec![Address {
            kind: "dhcp-lease",
            reference: opaque(raw),
            fresh,
        }];
        if self.addresses != addresses {
            self.addresses = addresses;
            self.sequence += 1;
        }
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
fn tokens(line: &str) -> Vec<&str> {
    line.split_whitespace().collect()
}
fn has_pair(tokens: &[&str], key: &str, value: &str) -> bool {
    tokens.windows(2).any(|pair| pair == [key, value])
}
fn deleted(token: &str) -> bool {
    token.eq_ignore_ascii_case("deleted")
}
fn interface_token(token: &str, bridge: &str) -> bool {
    token.strip_suffix(':') == Some(bridge)
}
fn ifindex_token(token: &str) -> bool {
    token
        .strip_suffix(':')
        .and_then(|index| index.parse::<u32>().ok())
        .is_some()
}
fn link_event_for(bridge: &str, line: &str) -> bool {
    let event = tokens(line);
    match event.as_slice() {
        [operation, index, name, ..] if deleted(operation) => {
            ifindex_token(index) && interface_token(name, bridge)
        }
        [index, name, ..] => ifindex_token(index) && interface_token(name, bridge),
        _ => false,
    }
}
fn neighbor_event_for(bridge: &str, line: &str) -> bool {
    let event = tokens(line);
    event
        .first()
        .and_then(|address| address.parse::<std::net::IpAddr>().ok())
        .is_some()
        && has_pair(&event, "dev", bridge)
        && event
            .iter()
            .any(|state| matches!(*state, "REACHABLE" | "DELAY" | "PROBE"))
        && !event
            .iter()
            .any(|state| deleted(state) || matches!(*state, "FAILED" | "STALE" | "PERMANENT"))
}
fn mac_token(token: &str) -> bool {
    let octets = token.split(':').collect::<Vec<_>>();
    octets.len() == 6
        && octets
            .iter()
            .all(|octet| octet.len() == 2 && u8::from_str_radix(octet, 16).is_ok())
}
fn fdb_event_for(bridge: &str, members: &[String], line: &str) -> bool {
    let event = tokens(line);
    let affirmative = match event.as_slice() {
        [mac, "dev", member, "master", master, ..] => {
            mac_token(mac) && master == &bridge && members.iter().any(|known| known == member)
        }
        _ => false,
    };
    affirmative
        && !event.iter().any(|token| {
            deleted(token)
                || token.eq_ignore_ascii_case("static")
                || token.eq_ignore_ascii_case("permanent")
        })
}
fn bridge_members(bridge: &str) -> Vec<String> {
    fs::read_dir(format!("/sys/class/net/{bridge}/brif"))
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect()
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
#[derive(Clone, Copy)]
enum MonitorKind {
    LinkNeighbor,
    Fdb,
}
impl MonitorKind {
    fn name(self) -> &'static str {
        match self {
            Self::LinkNeighbor => "link-neighbor",
            Self::Fdb => "fdb",
        }
    }
}
fn supervise_reader(
    kind: MonitorKind,
    stdout: impl std::io::Read + Send + 'static,
    state: Arc<Mutex<State>>,
    dir: std::path::PathBuf,
    bridge: String,
    exited: mpsc::Sender<(MonitorKind, &'static str)>,
) {
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    let _ = exited.send((kind, "eof"));
                    return;
                }
                Err(_) => {
                    let _ = exited.send((kind, "read-error"));
                    return;
                }
                Ok(_) => {
                    let witnessed = match kind {
                        MonitorKind::LinkNeighbor => {
                            if link_event_for(&bridge, &line) {
                                let mut current = state.lock().unwrap();
                                let (present, up) = carrier(&bridge);
                                let changed = current.carrier(present, up);
                                if changed {
                                    write_state(&dir, &current, None);
                                }
                            }
                            neighbor_event_for(&bridge, &line)
                        }
                        MonitorKind::Fdb => fdb_event_for(&bridge, &bridge_members(&bridge), &line),
                    };
                    if witnessed {
                        let mut current = state.lock().unwrap();
                        let source = match kind {
                            MonitorKind::LinkNeighbor => "rtnetlink-neighbor",
                            MonitorKind::Fdb => "bridge-fdb",
                        };
                        if current.witnessed_peer(source, &line) {
                            write_state(&dir, &current, None);
                        }
                    }
                }
            }
        }
    });
}
fn spawn_monitor(
    kind: MonitorKind,
    command: &str,
    args: &[&str],
    state: Arc<Mutex<State>>,
    dir: std::path::PathBuf,
    bridge: String,
    exited: mpsc::Sender<(MonitorKind, &'static str)>,
) -> Result<std::process::Child, &'static str> {
    let mut child = Command::new(command)
        .args(args)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|_| "spawn-error")?;
    let stdout = child.stdout.take().ok_or("stdout-unavailable")?;
    supervise_reader(kind, stdout, state, dir, bridge, exited);
    Ok(child)
}
fn stop_monitor(child: &mut std::process::Child) -> std::io::Result<std::process::ExitStatus> {
    let _ = child.kill();
    child.wait()
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
    // Both subscriptions are required evidence sources. A spawn failure, read
    // error, or EOF terminates this process so systemd's Restart=on-failure can
    // recreate a complete observer; the surviving child is always reaped.
    let (exited_tx, exited_rx) = mpsc::channel();
    let monitor_bridge = bridge.clone();
    let mut link_neighbor = match spawn_monitor(
        MonitorKind::LinkNeighbor,
        "ip",
        &["monitor", "link", "neigh", "dev", &bridge],
        shared.clone(),
        dir.clone(),
        monitor_bridge,
        exited_tx.clone(),
    ) {
        Ok(child) => child,
        Err(class) => {
            eprintln!("usb-downlink-observer monitor=link-neighbor error={class}");
            std::process::exit(1);
        }
    };
    let mut fdb = match spawn_monitor(
        MonitorKind::Fdb,
        "bridge",
        &["monitor", "fdb"],
        shared.clone(),
        dir.clone(),
        bridge.clone(),
        exited_tx,
    ) {
        Ok(child) => child,
        Err(class) => {
            let _ = stop_monitor(&mut link_neighbor);
            eprintln!("usb-downlink-observer monitor=fdb error={class}");
            std::process::exit(1);
        }
    };
    loop {
        if let Ok((kind, class)) = exited_rx.recv_timeout(Duration::from_secs(2)) {
            let _ = stop_monitor(&mut link_neighbor);
            let _ = stop_monitor(&mut fdb);
            eprintln!(
                "usb-downlink-observer monitor={} error={class}",
                kind.name()
            );
            std::process::exit(1);
        }
        let mut s = shared.lock().unwrap();
        let (present, up) = carrier(&bridge);
        if s.carrier(present, up) {
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
    fn unchanged_carrier_preserves_witnessed_peer() {
        let mut state = State::initial();
        state.carrier(true, Some(true));
        assert!(state.witnessed_peer("bridge-fdb", "fresh event"));
        let sequence = state.sequence;
        assert!(!state.carrier(true, Some(true)));
        assert!(matches!(state.peer, Peer::Present { .. }));
        assert_eq!(state.sequence, sequence);
    }
    #[test]
    fn repeated_same_peer_event_does_not_advance_sequence() {
        let mut state = State::initial();
        state.carrier(true, Some(true));
        assert!(state.witnessed_peer(
            "rtnetlink-neighbor",
            "192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        let sequence = state.sequence;
        assert!(!state.witnessed_peer(
            "rtnetlink-neighbor",
            "192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        assert_eq!(state.sequence, sequence);
    }
    #[test]
    fn strict_neighbor_fixture_rejects_delete_wrong_port_and_prefixes() {
        assert!(neighbor_event_for(
            "br-downlink",
            "192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        assert!(neighbor_event_for(
            "br-downlink",
            "192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 PROBE"
        ));
        assert!(!neighbor_event_for(
            "br-downlink",
            "Deleted 192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        assert!(!neighbor_event_for(
            "br-downlink",
            "deleted 192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        assert!(!neighbor_event_for(
            "br-downlink",
            "192.0.2.2 dev br-downlink0 lladdr 00:11:22:33:44:55 REACHABLE"
        ));
        assert!(!neighbor_event_for(
            "br-downlink",
            "192.0.2.2 dev br-downlink lladdr 00:11:22:33:44:55 STALE"
        ));
    }
    #[test]
    fn strict_fdb_fixture_requires_current_member_and_exact_master() {
        let members = vec!["enxusb0".to_owned()];
        assert!(fdb_event_for(
            "br-downlink",
            &members,
            "00:11:22:33:44:55 dev enxusb0 master br-downlink"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "Deleted 00:11:22:33:44:55 dev enxusb0 master br-downlink"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "00:11:22:33:44:55 dev enxusb0 master br-downlink0"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "00:11:22:33:44:55 dev enxusb01 master br-downlink"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "00:11:22:33:44:55 dev enxusb0 master br-downlink static"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "00:11:22:33:44:55 dev enxusb0 master br-downlink permanent"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "deleted 00:11:22:33:44:55 dev enxusb0 master br-downlink"
        ));
        assert!(!fdb_event_for(
            "br-downlink",
            &members,
            "noise dev enxusb0 master br-downlink"
        ));
    }
    #[test]
    fn link_fixture_refreshes_without_lladdr() {
        assert!(link_event_for(
            "br-downlink",
            "5: br-downlink: <BROADCAST,MULTICAST,UP> mtu 1500"
        ));
        assert!(!link_event_for(
            "br-downlink",
            "5: br-downlink0: <BROADCAST,MULTICAST,UP> mtu 1500"
        ));
        assert!(!link_event_for(
            "br-downlink",
            "noise br-downlink: <BROADCAST,MULTICAST,UP> mtu 1500"
        ));
    }
    #[test]
    fn link_deletion_is_a_valid_refresh_that_can_make_link_absent() {
        assert!(link_event_for(
            "br-downlink",
            "Deleted 5: br-downlink: <BROADCAST,MULTICAST> mtu 1500"
        ));
        let mut state = State::initial();
        state.carrier(true, Some(true));
        assert!(state.carrier(false, None));
        assert_eq!(state.link, Link::Absent);
        assert_eq!(state.peer, Peer::Unknown("no-matching-usb-ethernet"));
    }
    #[test]
    fn fake_monitor_eof_is_reported_for_supervision() {
        let directory = std::env::temp_dir().join(format!("usb-downlink-monitor-{}", now()));
        fs::create_dir_all(&directory).unwrap();
        let (tx, rx) = mpsc::channel();
        supervise_reader(
            MonitorKind::Fdb,
            std::io::Cursor::new(Vec::<u8>::new()),
            Arc::new(Mutex::new(State::initial())),
            directory.clone(),
            "br-downlink".to_owned(),
            tx,
        );
        let (kind, class) = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(kind.name(), "fdb");
        assert_eq!(class, "eof");
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn fake_monitor_spawn_failure_is_visible() {
        let (tx, _rx) = mpsc::channel();
        let result = spawn_monitor(
            MonitorKind::Fdb,
            "/definitely/not/a/monitor",
            &[],
            Arc::new(Mutex::new(State::initial())),
            std::env::temp_dir(),
            "br-downlink".to_owned(),
            tx,
        );
        assert_eq!(result.err(), Some("spawn-error"));
    }
    #[test]
    fn fake_monitor_read_error_is_reported_for_supervision() {
        struct BrokenReader;
        impl std::io::Read for BrokenReader {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("fixture"))
            }
        }
        let (tx, rx) = mpsc::channel();
        supervise_reader(
            MonitorKind::Fdb,
            BrokenReader,
            Arc::new(Mutex::new(State::initial())),
            std::env::temp_dir(),
            "br-downlink".to_owned(),
            tx,
        );
        let (kind, class) = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(kind.name(), "fdb");
        assert_eq!(class, "read-error");
    }
    #[test]
    fn fake_monitor_child_eof_is_reported_and_reaped() {
        let (tx, rx) = mpsc::channel();
        let mut child = spawn_monitor(
            MonitorKind::LinkNeighbor,
            "sh",
            &["-c", "exit 0"],
            Arc::new(Mutex::new(State::initial())),
            std::env::temp_dir(),
            "br-downlink".to_owned(),
            tx,
        )
        .unwrap();
        let (kind, class) = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(kind.name(), "link-neighbor");
        assert_eq!(class, "eof");
        assert!(child.wait().unwrap().success());
    }
    #[test]
    fn sibling_monitor_cleanup_kills_and_reaps_the_other_child() {
        let (tx, rx) = mpsc::channel();
        let mut child = spawn_monitor(
            MonitorKind::Fdb,
            "sh",
            &["-c", "exec sleep 60"],
            Arc::new(Mutex::new(State::initial())),
            std::env::temp_dir(),
            "br-downlink".to_owned(),
            tx,
        )
        .unwrap();
        assert!(!stop_monitor(&mut child).unwrap().success());
        let (_, class) = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(class, "eof");
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
