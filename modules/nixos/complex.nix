{
  pkgs,
  inputs,
  config,
  constants,
  ...
}:
let
  inherit (constants.fileSystem.complex) dir;

  clavifaber = inputs.clavifaber.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Per-host artifacts produced by clavifaber. See clavifaber/ARCHITECTURE.md.
  publicationFile = "${dir}/publication.nota";

  # The boot-time setup sequence is a series of NOTA-only clavifaber
  # calls (no Converge mega-request; that is orchestrator territory and
  # does not belong in clavifaber). Each call is idempotent — re-runs are
  # cheap because the per-handler skip-on-disk-existence checks
  # short-circuit when the output files already exist.
  identitySetup = ''(IdentitySetup "${dir}")'';
  publicationWriting = ''
    (PublicKeyPublicationWriting ${config.networking.hostName} "${dir}" None None "${publicationFile}")
  '';
in
{
  environment.systemPackages = [ clavifaber ];

  # Clavifaber writes private key bytes; restrict the directory.
  systemd.tmpfiles.rules = [
    "d ${dir} 0700 root root -"
  ];

  systemd.services.complex-init = {
    description = "Clavifaber host key-material setup";
    wantedBy = [ "multi-user.target" ];
    before = [
      "NetworkManager.service"
      "sshd.service"
    ];
    # Operator override: `touch ${dir}/.disabled` on a host to keep
    # clavifaber from running at boot. Useful when the host's identity
    # is managed out-of-band (HSM-backed, manually-provisioned, etc.)
    # and clavifaber must not touch the directory. See
    # reports/system-specialist/112-clavifaber-existing-host-audit.md.
    unitConfig.ConditionPathExists = "!${dir}/.disabled";
    # `yggdrasil` lives on PATH so the YggdrasilKey actor can mint and
    # statically derive identity material when the YggdrasilKeypairSetup
    # call is wired in (today the publication writes None for the
    # yggdrasil keypair until the network/yggdrasil.nix consolidation
    # lands — primary-8b3).
    path = [ pkgs.yggdrasil ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${clavifaber}/bin/clavifaber '${identitySetup}'
      ${clavifaber}/bin/clavifaber '${publicationWriting}'
    '';
  };
}
