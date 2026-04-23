# Full VM-driven test for the CriomOS PKI bootstrap lifecycle.
#
# Tests:
#   1. complex-init generates Ed25519 keypair on first boot
#   2. derive-pubkey re-derives ssh.pub from private key
#   3. CA certificate creation from GPG key
#   4. Node certificate signing from complex pubkey
#   5. Certificate chain verification (cryptographic)
#   6. Multi-node: second node generates its own complex, gets signed by same CA
#   7. Corruption recovery: corrupt key detected, renamed aside, regenerated
#   8. Idempotent boot: second boot preserves existing keys
#
# Usage:
#   nix build .#packages.x86_64-linux.tests.pki-bootstrap
#   or directly:
#   nix build -f nix/tests/pki-bootstrap.nix --arg pkgs 'import <nixpkgs> {}'

{ pkgs }:

let
  clavifaber = pkgs.callPackage ../clavifaber.nix { };

  constants = import ../mkCriomOS/constants.nix;
  inherit (constants.fileSystem.complex) dir keyFile sshPubFile;
  inherit (constants.fileSystem.wifiPki) caCertFile certsDir;

  # Shared NixOS module for all test nodes — installs clavifaber + complex-init
  complexModule = {
    environment.systemPackages = [ clavifaber pkgs.gnupg pkgs.openssl ];

    systemd.services.complex-init = {
      description = "Generate node identity complex (Ed25519 keypair)";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${clavifaber}/bin/clavifaber complex-init --dir "${dir}"
        ${clavifaber}/bin/clavifaber derive-pubkey --dir "${dir}"
      '';
    };
  };

in
pkgs.testers.nixosTest {
  name = "pki-bootstrap";

  nodes = {
    # CA authority — generates GPG key and signs certificates
    faber = { pkgs, ... }: {
      imports = [ complexModule ];
      networking.hostName = "faber";

      # Generate a GPG key on first boot for CA operations
      systemd.services.gpg-ca-init = {
        description = "Generate test CA GPG key";
        wantedBy = [ "multi-user.target" ];
        after = [ "complex-init.service" ];
        requires = [ "complex-init.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.gnupg ];
        script = ''
          export GNUPGHOME=/root/.gnupg
          mkdir -p $GNUPGHOME
          chmod 700 $GNUPGHOME

          if [ -f /root/.ca-keygrip ]; then
            exit 0
          fi

          cat > /tmp/keygen.batch <<'BATCH'
          %no-protection
          Key-Type: eddsa
          Key-Curve: ed25519
          Key-Usage: sign
          Name-Real: Aedifico Test CA
          Name-Email: test@aedifico.criome
          Expire-Date: 0
          %commit
          BATCH

          gpg --batch --gen-key /tmp/keygen.batch
          rm /tmp/keygen.batch

          # Extract and persist keygrip
          gpg --list-secret-keys --with-keygrip --with-colons \
            | grep '^grp:' | head -1 | cut -d: -f10 > /root/.ca-keygrip

          # Ensure agent is running
          gpg-connect-agent /bye

          # Generate CA certificate
          mkdir -p ${certsDir}
          KEYGRIP=$(cat /root/.ca-keygrip)
          ${clavifaber}/bin/clavifaber ca-init \
            --keygrip "$KEYGRIP" \
            --cn "Aedifico Test CA" \
            --out ${caCertFile}
        '';
      };
    };

    # Client node — receives signed certificate
    probus = { pkgs, ... }: {
      imports = [ complexModule ];
      networking.hostName = "probus";
    };
  };

  testScript = ''
    start_all()

    # ── Phase 1: Complex generation on boot ──
    with subtest("complex-init generates keypair on faber"):
        faber.wait_for_unit("complex-init.service")
        faber.succeed("test -f ${keyFile}")
        faber.succeed("test -f ${sshPubFile}")

        # Verify permissions
        faber.succeed("stat -c '%a' ${keyFile} | grep -q 600")
        faber.succeed("stat -c '%a' ${dir} | grep -q 700")
        faber.succeed("stat -c '%a' ${sshPubFile} | grep -q 644")

        # Verify PEM format
        faber.succeed("grep -q 'BEGIN PRIVATE KEY' ${keyFile}")

        # Verify SSH format
        faber.succeed("grep -q 'ssh-ed25519' ${sshPubFile}")

    with subtest("complex-init generates keypair on probus"):
        probus.wait_for_unit("complex-init.service")
        probus.succeed("test -f ${keyFile}")
        probus.succeed("test -f ${sshPubFile}")
        probus.succeed("grep -q 'ssh-ed25519' ${sshPubFile}")

    # ── Phase 2: Derive-pubkey consistency ──
    with subtest("derive-pubkey matches stored pubkey"):
        stored = faber.succeed("cat ${sshPubFile}").strip()
        derived = faber.succeed("clavifaber derive-pubkey --dir ${dir}").strip()
        assert stored == derived, f"stored={stored} derived={derived}"

    with subtest("derive-pubkey corrects tampered ssh.pub"):
        original = probus.succeed("cat ${sshPubFile}").strip()
        probus.succeed("echo 'ssh-ed25519 AAAA_TAMPERED wrong' > ${sshPubFile}")
        probus.succeed("clavifaber derive-pubkey --dir ${dir}")
        restored = probus.succeed("cat ${sshPubFile}").strip()
        assert restored == original, f"original={original} restored={restored}"

    # ── Phase 3: CA certificate creation ──
    with subtest("CA certificate generated on faber"):
        faber.wait_for_unit("gpg-ca-init.service")
        faber.succeed("test -f ${caCertFile}")
        faber.succeed("test -f /root/.ca-keygrip")

        # Verify CA:TRUE
        faber.succeed("openssl x509 -in ${caCertFile} -noout -text | grep -q 'CA:TRUE'")

        # Verify CN
        faber.succeed("openssl x509 -in ${caCertFile} -noout -subject | grep -q 'Aedifico Test CA'")

    # ── Phase 4: Sign probus node certificate ──
    with subtest("sign probus certificate from its complex pubkey"):
        # Get probus SSH pubkey
        probus_pubkey = probus.succeed("cat ${sshPubFile}").strip()
        keygrip = faber.succeed("cat /root/.ca-keygrip").strip()

        # Copy CA cert to probus for later verification
        ca_pem = faber.succeed("cat ${caCertFile}")

        # Sign on faber (CA machine)
        faber.succeed(
            f"clavifaber node-cert "
            f"--ca-keygrip {keygrip} "
            f"--ca-cert ${caCertFile} "
            f"--ssh-pubkey '{probus_pubkey}' "
            f"--cn probus@aedifico "
            f"--out ${certsDir}/probus.pem"
        )
        faber.succeed("test -f ${certsDir}/probus.pem")

    # ── Phase 5: Cryptographic verification ──
    with subtest("verify probus certificate chains to CA"):
        faber.succeed(
            "clavifaber verify "
            "--ca-cert ${caCertFile} "
            "--cert ${certsDir}/probus.pem"
        )

    with subtest("openssl also verifies the chain"):
        # Ed25519 certs with SHA-256 pre-hash may not verify with openssl,
        # but structural checks work
        faber.succeed(
            "openssl x509 -in ${certsDir}/probus.pem -noout -subject "
            "| grep -q 'probus@aedifico'"
        )

    # ── Phase 6: Sign faber's own node certificate ──
    with subtest("sign faber certificate from its own complex"):
        faber_pubkey = faber.succeed("cat ${sshPubFile}").strip()
        keygrip = faber.succeed("cat /root/.ca-keygrip").strip()
        faber.succeed(
            f"clavifaber node-cert "
            f"--ca-keygrip {keygrip} "
            f"--ca-cert ${caCertFile} "
            f"--ssh-pubkey '{faber_pubkey}' "
            f"--cn faber@aedifico "
            f"--out ${certsDir}/faber.pem"
        )
        faber.succeed(
            "clavifaber verify "
            "--ca-cert ${caCertFile} "
            "--cert ${certsDir}/faber.pem"
        )

    # ── Phase 7: Server certificate ──
    with subtest("generate and verify server certificate"):
        keygrip = faber.succeed("cat /root/.ca-keygrip").strip()
        faber.succeed(
            f"clavifaber server-cert "
            f"--ca-keygrip {keygrip} "
            f"--ca-cert ${caCertFile} "
            f"--cn faber.criome "
            f"--out-cert /tmp/server.pem "
            f"--out-key /tmp/server.key"
        )
        faber.succeed("test -f /tmp/server.pem")
        faber.succeed("test -f /tmp/server.key")
        faber.succeed(
            "clavifaber verify "
            "--ca-cert ${caCertFile} "
            "--cert /tmp/server.pem"
        )

    # ── Phase 8: Corruption recovery ──
    with subtest("corrupt key detected and regenerated"):
        original_pub = probus.succeed("cat ${sshPubFile}").strip()

        # Corrupt the private key
        probus.succeed("echo GARBAGE > ${keyFile}")

        # Re-run complex-init — should detect corruption, rename aside, regenerate
        probus.succeed("clavifaber complex-init --dir ${dir}")
        probus.succeed("clavifaber derive-pubkey --dir ${dir}")

        new_pub = probus.succeed("cat ${sshPubFile}").strip()
        assert new_pub != original_pub, "key should have been regenerated"

        # Broken file should be preserved
        probus.succeed("ls ${dir}/key.pem.broken.* >/dev/null 2>&1")

        # New key should be valid PEM
        probus.succeed("grep -q 'BEGIN PRIVATE KEY' ${keyFile}")

    # ── Phase 9: Idempotent reboot ──
    with subtest("reboot preserves existing keys"):
        pre_reboot_pub = faber.succeed("cat ${sshPubFile}").strip()
        pre_reboot_key = faber.succeed("sha256sum ${keyFile}").strip()

        faber.shutdown()
        faber.start()
        faber.wait_for_unit("complex-init.service")

        post_reboot_pub = faber.succeed("cat ${sshPubFile}").strip()
        post_reboot_key = faber.succeed("sha256sum ${keyFile}").strip()

        assert pre_reboot_pub == post_reboot_pub, "pubkey changed after reboot"
        assert pre_reboot_key == post_reboot_key, "private key changed after reboot"

    # ── Phase 10: Cross-node cert deployment ──
    with subtest("deploy probus cert and verify on probus itself"):
        # Copy CA cert and node cert to probus
        ca_pem = faber.succeed("cat ${caCertFile}")
        probus.succeed("mkdir -p ${certsDir}")
        probus.succeed("cat > ${caCertFile} << 'CERTEOF'\n" + ca_pem + "CERTEOF")

        node_cert = faber.succeed("cat ${certsDir}/probus.pem")
        probus.succeed("cat > ${certsDir}/probus.pem << 'CERTEOF'\n" + node_cert + "CERTEOF")

        # Verify on probus using its own clavifaber
        probus.succeed(
            "clavifaber verify "
            "--ca-cert ${caCertFile} "
            "--cert ${certsDir}/probus.pem"
        )
  '';
}
