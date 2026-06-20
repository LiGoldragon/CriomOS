{
  lib,
  pkgs,
  inputs,
  config,
  constants,
  deployment ? {
    includeComplex = true;
  },
  ...
}:
let
  inherit (constants.fileSystem.complex) dir;
  includeComplex = deployment.includeComplex or true;

  clavifaber = inputs.clavifaber.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Per-host artifacts produced by clavifaber. See clavifaber/ARCHITECTURE.md.
  publicationFile = "${dir}/publication.nota";

  # Clavifaber does NOT create the SSH host key. sshd does
  # (`services.openssh.enable = true` triggers
  # /etc/ssh/ssh_host_ed25519_key generation at first boot).
  # clavifaber's job: read sshd's `.pub` and aggregate it into
  # publication.nota along with the Yggdrasil projection and the
  # WiFi-PKI client cert when those are wired in.
  sshdHostPublicKey = "/etc/ssh/ssh_host_ed25519_key.pub";

  # Operator surface is one NOTA record per call. Today's boot
  # sequence is one call: assemble publication.nota. The
  # YggdrasilKeypairSetup / cert-issuance verbs land here when the
  # network/yggdrasil.nix consolidation (primary-8b3) and the
  # WiFi-PKI plumbing land.
  publicationWriting = ''
    (PublicKeyPublicationWriting (${config.networking.hostName} (${sshdHostPublicKey}) None None ${publicationFile}))
  '';
in
lib.mkIf includeComplex {
  environment.systemPackages = [ clavifaber ];

  # publication.nota lives in the complex directory; restrict it to
  # root since clavifaber writes there. The publication file itself
  # is mode 0644 (publicly readable per the haywire-stage cluster
  # contract); the containing directory is 0755 so consumers (e.g.
  # the SSH-pull pattern) can read the file without elevated perms.
  systemd.tmpfiles.rules = [
    "d ${dir} 0755 root root -"
  ];

  systemd.services.complex-init = {
    description = "Clavifaber publication assembly";
    wantedBy = [ "multi-user.target" ];
    # complex-init reads sshd's ssh_host_ed25519_key.pub, so sshd's
    # host-key generation must have completed first. NixOS's sshd
    # generates keys in its preStart; ordering `after = sshd.service`
    # ensures the key is present.
    after = [ "sshd.service" ];
    # Operator override: `touch ${dir}/.disabled` on a host to keep
    # clavifaber from running at boot. See
    # reports/system-specialist/112-clavifaber-existing-host-audit.md.
    unitConfig.ConditionPathExists = "!${dir}/.disabled";
    # `yggdrasil` lives on PATH for the (currently unused) yggdrasil
    # keypair setup; harmless when the request doesn't reach the
    # YggdrasilKey actor.
    path = [ pkgs.yggdrasil ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${clavifaber}/bin/clavifaber '${publicationWriting}'
    '';
  };
}
