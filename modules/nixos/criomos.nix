{ flake, inputs, ... }:

# nixosModules.criomos — top aggregate.

{
  lib,
  deployment ? {
    includeHome = true;
  },
  ...
}:
let
  includeHome = deployment.includeHome or true;
in
{
  imports = [
    ./disks/preinstalled.nix
    ./normalize.nix
    ./secrets.nix
    ./repository-receive.nix
    ./mirror.nix
    ./persona-router.nix
    # criome + spirit node modules (persistent-Spirit-mirror pieces 6/8). Both
    # are `mkEnableOption`-gated (default off) so importing them only makes the
    # `services.criome`/`services.spirit` options available cluster-wide; a node
    # opts in per deploy (the standing mirror pair enables both alongside
    # PersonaRouter). Inert on every other node.
    ./criome.nix
    ./spirit.nix
    ./lojix.nix
    ./nix
    ./complex.nix
    ./nspawn.nix
    ./llm.nix
    ./users.nix
    # Agent Intercom's node-level SSH and accessibility prerequisites;
    # user broker/adapters and session state remain in CriomOS-home.
    ./agent-intercom.nix
    ./network
    # aggregator — pulls in dnsmasq, yggdrasil, tailscale,
    # headscale, nordvpn, wifi-eap, networkd, wireguard,
    # plus networking.hosts entries from horizon.exNodes
    ./edge/default.nix
  ]
  ++ lib.optionals includeHome [
    ./userHomes.nix
  ]
  ++ [
    ./metal/default.nix
    ./router/default.nix
    ./vm-testing/default.nix
    # Lean-guest gate for a TestVm-species node — suppresses the home/doc
    # weight a test guest never wants while leaving it a real deploy target
    # (design report 47, surface 4).
    ./test-vm-guest.nix
    # TestVm host emission — per projected ex_node hosted here with
    # behavesAs.testVm, emit a real KVM microVM + additive tap + guest-IP
    # hosts entry + non-autostart unit (design report 47, surface 5).
    ./test-vm-host.nix
  ]
  # microvm.nix host module — provides the `microvm.vms.*` options the
  # VM-testing feature's persistent routed test VM is declared with. Inert
  # unless a `microvm.vms` is defined (only the VmTesting node-service does
  # so). Imported only when the input is present so downstream consumers that
  # drop it still evaluate.
  ++ lib.optionals (inputs ? microvm) [
    inputs.microvm.nixosModules.host
  ];

  # dconf-service is enabled cluster-wide so the system D-Bus always
  # has `ca.desrt.dconf` registered. home-manager's dconfSettings
  # activation (which stylix populates regardless of host role) then
  # succeeds on every node; on headless boxes the keys are written
  # but unread (no GTK/portal app reads them). The marginal cost is
  # one small daemon — cheaper than duplicating the headless-vs-edge
  # predicate on both system and home sides.
  programs.dconf.enable = true;
}
