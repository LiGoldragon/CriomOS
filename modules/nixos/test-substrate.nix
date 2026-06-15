# The named test-substrate override profile (design report 47; reports 50/
# 4-design-proposal §2.3; C3).
#
# This is the SINGLE composable module that bakes in the live-run constraints
# the two end-to-end runs (reports 48 §fixes 1-5, 49 §step 2) independently
# re-derived into /tmp override sets. The VM-test generator (mkVmTest, C4)
# applies exactly this profile to the guest config — never re-typing the
# overrides per run.
#
# It is a FUNCTION of the substrate (`microvm` — booting, the default — or
# `uefi` — q35 + OVMF + ESP), returning two composable modules:
#
#   { guestModule  = <every OS-level prebake — composes onto the guest's own
#                     CriomOS nixosSystem>;
#     vmTypeModule = <the qemu machine-type override — composes onto the
#                     runNixOSTest driver node, where `virtualisation.qemu`
#                     exists>; }
#
# The split exists because the machine type lives on the qemu-vm test node
# (which declares `virtualisation.qemu`), while every other constraint is an
# ordinary CriomOS option valid on any guest. The generator composes BOTH onto
# the test node, so from the author's view it is one substrate.
#
# The difference between "a lean CriomOS guest" and "a lean CriomOS guest that
# boots and accepts a deploy" IS this profile.
#
# guestModule bakes (the shared live-run fixes):
#   - writable /nix/store overlay (boot.nixStoreMountOpts = ["rw"]) — the 26.05
#     successor to readOnlyNixStore=false; without it a second read-only overlay
#     shadows the writable one and `nix copy` into the target fails (the S5 mode);
#   - nix.settings.require-sigs = false — a SUBSTRATE property, not a daemon
#     change: the daemon's `nix copy` stays production-identical; the locally
#     built closure is simply unsigned, so the target must not require sigs;
#   - nscd re-enabled + passwd/group/shadow pinned to `files` — CriomOS
#     network/default.nix disables nscd AND empties nssModules, so getpwnam(root)
#     fails and sshd rejects root as "invalid user". The substrate restores NSS;
#   - an absolute ${bashInteractive}/bin/bash root login shell — else root has no
#     login shell and sshd again rejects root as an invalid user;
#   - sshd keys-only + the deploy key — normalize.nix already sets
#     PasswordAuthentication = false; the substrate APPENDS the harness deploy
#     key to root's authorizedKeys so the test driver can reach root@guest;
#   - the horizon-derived address — the guest advertises its own criome domain
#     as hostName/domain so lojix targets root@<node>.<cluster>.criome with zero
#     VM special-casing; the host side (test-vm-host.nix) resolves that name;
#   - console=ttyS0 serial — observability of the boot;
#   - (uefi only) ESP/root label alignment (root ext4 `nixos`, ESP vfat `ESP`)
#     so switch-to-configuration / systemd-boot find what they expect (report 49).
#
# vmTypeModule bakes:
#   - (microvm) the `-M microvm` machine type (qemu direct kernel boot) — the
#     lean userspace comes up here; stock q35 hangs it (report 49);
#   - (uefi) OVMF/UEFI on q35 with a real ESP so BootOnce is possible.
#
# Usage (from the generator):
#
#   let sub = import ./test-substrate.nix { substrate = "microvm"; deployKey = k; };
#   in runNixOSTest { nodes.guest = { imports = [ criomos sub.guestModule sub.vmTypeModule ]; }; ... }

{
  substrate ? "microvm",
  # The harness/deploy public key appended to root's authorizedKeys so the
  # test driver (and lojix) can reach root@<guest>. `null` leaves the
  # projection's adminSshPubKeys as the only root keys.
  deployKey ? null,
}:

let
  isMicrovm = substrate == "microvm";
  isUefi = substrate == "uefi";

  # ---- guestModule: every OS-level prebake, composable onto any guest -----
  guestModule =
    {
      lib,
      pkgs,
      horizon,
      ...
    }:
    let
      inherit (lib) mkForce mkAfter optionals;

      # The guest's own horizon-derived criome address — the exact name lojix
      # targets (root@<node>.<cluster>.criome).
      node = horizon.node;
      clusterName = horizon.cluster.name or node.name;
      criomeDomainName = node.criomeDomainName or "${node.name}.${clusterName}.criome";
    in
    {
      assertions = [
        {
          assertion = isMicrovm || isUefi;
          message = "test-substrate: substrate must be \"microvm\" or \"uefi\", got \"${toString substrate}\".";
        }
      ];

      # writable /nix/store overlay (S5 fix). The 26.05 option; without it a
      # second read-only store overlay shadows the writable one and the
      # daemon's `nix copy` into the target fails.
      boot.nixStoreMountOpts = mkForce [ "rw" ];

      # unsigned local closure (a substrate property, not a daemon change).
      nix.settings.require-sigs = mkForce false;

      # NSS restored: nscd on + passwd/group/shadow pinned to files. CriomOS
      # network/default.nix disables nscd and empties nssModules; both break
      # getpwnam(root) so sshd rejects root as an "invalid user".
      services.nscd.enable = mkForce true;
      system.nssDatabases = {
        passwd = mkForce [ "files" ];
        group = mkForce [ "files" ];
        shadow = mkForce [ "files" ];
      };

      # root login shell exists — an absolute bash (else sshd "invalid user").
      users.users.root.shell = mkForce "${pkgs.bashInteractive}/bin/bash";

      # sshd keys-only + the deploy key. normalize.nix already disables
      # password auth; reassert it and APPEND the harness deploy key to root's
      # authorizedKeys (additive — the projection's adminSshPubKeys stay).
      services.openssh = {
        enable = mkForce true;
        settings.PasswordAuthentication = mkForce false;
        settings.PermitRootLogin = mkForce "prohibit-password";
      };
      users.users.root.openssh.authorizedKeys.keys =
        mkAfter (optionals (deployKey != null) [ deployKey ]);

      # the horizon-derived address — the guest advertises its own criome
      # domain so lojix targets root@<node>.<cluster>.criome; the host side
      # resolves that name to the guest's IP.
      networking.hostName = mkForce node.name;
      networking.domain = mkForce "${clusterName}.criome";
      networking.hosts = {
        "127.0.0.2" = [ criomeDomainName ];
      };

      # serial console (observability of the boot).
      boot.kernelParams = mkAfter [ "console=ttyS0" ];

      # man/nixos documentation forced OFF — a substrate concern for the
      # hermetic runNixOSTest path. The test framework's base profile
      # (nixos-test-base.nix) sets documentation.{enable,nixos.enable} = false;
      # CriomOS normalize.nix sets them = true at the default priority for any
      # non-container, non-iso node. A LEAN TestVm guest dodges the clash because
      # test-vm-guest.nix force-disables docs, but a COMPLEX-OS guest (an Edge
      # desktop, a Router) is not a TestVm and would hit a conflicting-definition
      # eval error. Forcing docs off here (where every substrate prebake lives)
      # unblocks complex profiles under runNixOSTest without touching the
      # production module or the test author (Spirit [dqg3]). Docs are pure
      # weight on a throwaway test VM regardless of role.
      documentation = {
        enable = mkForce false;
        nixos.enable = mkForce false;
        man.enable = mkForce false;
      };

      # uefi-only: ESP/root label alignment so switch-to-configuration /
      # systemd-boot find what they expect (report 49).
      fileSystems = lib.optionalAttrs isUefi {
        "/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
          label = mkForce "nixos";
        };
        "/boot" = {
          device = "/dev/disk/by-label/ESP";
          fsType = "vfat";
          label = mkForce "ESP";
        };
      };
    };

  # ---- vmTypeModule: the qemu machine type, composed onto the test node ---
  # Lives where `virtualisation.qemu` is declared (the qemu-vm / runNixOSTest
  # node). runNixOSTest defaults to q35, which hangs the lean userspace
  # (report 49); force the microvm machine type with direct kernel boot.
  vmTypeModule =
    { lib, ... }:
    {
      virtualisation.qemu.options = lib.mkAfter (
        if isMicrovm then [ "-M microvm" ] else [ ]
      );
    };
in
{
  inherit guestModule vmTypeModule;
}
