{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  configFor = extra: (lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      ../../modules/nixos/git-publication.nix
      ../../modules/nixos/network/yggdrasil.nix
      {
        _module.args = {
          horizon.node.keys.yggdrasil = { };
          constants = {
            fileSystem.yggdrasil = {
              preCriadJson = "/var/lib/yggdrasil/fixture.json";
              subDirName = "yggdrasil";
              pubKeyJson = "/var/lib/yggdrasil/public.json";
              interfaceName = "ygg-fixture";
              combinedConfigJson = "/var/lib/yggdrasil/combined.json";
            };
            network.yggdrasil.ports = { linkLocalTCP = 10001; multicast = 9001; };
          };
        };
      }
      { system.stateVersion = "26.05"; }
      extra
    ];
  }).config;
  disabled = configFor {};
  endpoint = {
    enable = true;
    peer = "localhost";
    network.peerAddress = "127.0.0.1";
    knownHosts = pkgs.writeText "known-publication-peer" "";
    identityFile = "/run/credentials/publication";
    authorizedKeys = [ "ssh-ed25519 AAAA" ];
  };
  streams = [
    { repositoryName = "sample/psyche"; referenceName = "refs/heads/main"; }
    { repositoryName = "sample/psyche"; referenceName = "refs/heads/release/v1"; }
    { repositoryName = "sample/mind"; referenceName = "refs/heads/main"; }
  ];
  outboxDirectory = "/var/lib/fixture-publication/nondefault-spool";
  enabledFor = overlay: routeStreams: configFor {
    services.openssh.enable = true;
    users.groups.git = {};
    users.users.git = { isSystemUser = true; group = "git"; };
    criomos.yggdrasil.logLevel = overlay.logLevel;
    criomos.gitPublication = {
      inherit (overlay) overlayJournal;
      streams = routeStreams;
      sender = endpoint // { inherit outboxDirectory; };
      receiver = endpoint // {
        curriculumEndpoint = "/run/fixture/curriculum-publication.sock";
        reconnectTargets = [ "fixture-reconnected.target" ];
      };
    };
  };
  ordinary = { overlayJournal = { }; logLevel = "info"; };
  enabled = enabledFor ordinary streams;
  invalid = enabledFor ordinary [
    { repositoryName = "sample/psyche"; referenceName = "refs/heads/${lib.concatStrings (lib.replicate 120 "a")}"; }
  ];
  custom = enabledFor {
    overlayJournal = { unit = "fixture-overlay.service"; messagePattern = "^Fixture peer up: "; };
    logLevel = "debug";
  } streams;
  value = lib.escapeShellArg;
  patchedOverlay = pkgs.callPackage ../../packages/yggdrasil-overlay { };
  connectedService = configuration: role: configuration.systemd.services."git-publication-${role}-connected";
  connectedSettings = configuration: role: lib.last (lib.splitString " "
    (connectedService configuration role).serviceConfig.ExecStart);
  networkSettings = role: lib.last (lib.splitString " "
    enabled.systemd.services."git-publication-${role}-network".serviceConfig.ExecStart);
  overlayCommandHas = configuration: level:
    lib.hasInfix
      (builtins.unsafeDiscardStringContext "${patchedOverlay}/bin/yggdrasil -loglevel ${level}")
      configuration.systemd.services.yggdrasil.serviceConfig.ExecStart;
  keys = user: builtins.head enabled.users.users.${user}.openssh.authorizedKeys.keys;
  receiverCommand = builtins.head (builtins.match ''restrict,command="([^"]+)" .*'' (keys "git-publication-receiver"));
in
assert disabled.criomos.gitPublication.enqueueCommand == null;
assert !(disabled.systemd.paths ? git-publication-deliver);
assert enabled.criomos.gitPublication.enqueueCommand != null;
assert builtins.elem "d ${outboxDirectory} 0700 git git -" enabled.systemd.tmpfiles.rules;
assert lib.any (entry:
  entry.message == "Each Git publication stream must fit the wire budget with SHA-256 object IDs."
  && !entry.assertion
) invalid.assertions;
assert !(disabled.systemd.services ? git-publication-sender-connected);
assert !(disabled.systemd.services ? git-publication-receiver-connected);
assert (connectedService enabled "sender").serviceConfig.Type == "notify";
assert (connectedService enabled "receiver").serviceConfig.User == "git-publication-receiver";
assert (connectedService custom "sender").before == [ "fixture-overlay.service" ];
assert (connectedService custom "receiver").before == [ "fixture-overlay.service" ];
assert overlayCommandHas enabled "info";
assert overlayCommandHas custom "debug";
assert enabled.systemd.services.git-publication-sender-network.wantedBy == [ "multi-user.target" ];
assert enabled.systemd.paths.git-publication-deliver.wantedBy == [ "multi-user.target" ];
assert enabled.systemd.services.git-publication-deliver.wantedBy == [];
assert !(disabled.systemd.paths ? git-publication-reconnect);
assert builtins.elem enabled.systemd.services.sshd.serviceConfig.Type [ "notify" "notify-reload" ];
assert enabled.systemd.paths.git-publication-reconnect.pathConfig.PathExists == enabled.criomos.gitPublication.receiver.readinessMarker;
assert builtins.elem "fixture-reconnected.target" enabled.systemd.services.git-publication-receiver-return.wantedBy;
pkgs.runCommand "git-publication-delivery" { nativeBuildInputs = [ pkgs.git pkgs.iproute2 pkgs.python3 ]; } ''
  set -euo pipefail
  test ${value enabled.systemd.paths.git-publication-deliver.pathConfig.PathExists} = /var/lib/git-publication-wake/ready
  printf '%s\n' ${value (keys "git-publication-wake")} | grep -E '^restrict,command="[^"]+git-publication-wake" ssh-ed25519 '
  printf '%s\n' ${value (keys "git-publication-receiver")} | grep -E '^restrict,command="[^"]+git-publication-receive" ssh-ed25519 '
  python3 -B - ${value enabled.criomos.gitPublication.enqueueCommand} \
    ${value enabled.systemd.services.git-publication-deliver.serviceConfig.ExecStart} \
    ${value receiverCommand} <<'PYTHON'
  import json
  from pathlib import Path
  import shlex
  import sys

  def settings(wrapper):
      _, _, _, settings_path, _, _ = shlex.split(Path(wrapper).read_text().splitlines()[-1])
      return json.loads(Path(settings_path).read_bytes())

  enqueue, drain, receiver = map(settings, sys.argv[1:])
  assert enqueue["outbox"] == drain["outbox"] == "${outboxDirectory}"
  assert enqueue["streams"] == drain["streams"] == receiver["streams"] == json.loads('${builtins.toJSON streams}')
  PYTHON
  python3 -B - ${value (networkSettings "sender")} ${value (networkSettings "receiver")} <<'PYTHON'
  import json
  from pathlib import Path
  import sys

  sender, receiver = (json.loads(Path(path).read_bytes()) for path in sys.argv[1:])
  assert sender["outbox"] == "${outboxDirectory}"
  assert sender["wake"] == "${enabled.systemd.paths.git-publication-deliver.pathConfig.PathExists}"
  assert "outbox" not in receiver
  PYTHON
  python3 -B - ${value (connectedSettings enabled "sender")} ${value (connectedSettings enabled "receiver")} <<'PYTHON'
  import json
  from pathlib import Path
  import sys

  sender, receiver = (json.loads(Path(path).read_bytes()) for path in sys.argv[1:])
  assert sender["wake"] == "${enabled.systemd.paths.git-publication-deliver.pathConfig.PathExists}"
  assert receiver["wake"] == "${enabled.systemd.paths.git-publication-reconnect.pathConfig.PathExists}"
  assert sender["unit"] == receiver["unit"] == "yggdrasil.service"
  PYTHON
  "${patchedOverlay}/bin/yggdrasil" -version
  {
    python3 -B ${./.}/contract.py ${../../modules/nixos/git-publication/delivery.py}
    python3 -B ${./.}/network_witness.py ${../../modules/nixos/git-publication}
    python3 -B ${./.}/journal_witness.py ${../../modules/nixos/git-publication} \
      ${value (connectedSettings enabled "sender")} ${value (connectedSettings custom "receiver")}
  } | tee "$out"
''
