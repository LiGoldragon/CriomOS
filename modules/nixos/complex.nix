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

  # Convergence-runner artifacts. See clavifaber/ARCHITECTURE.md.
  publicationFile = "${dir}/publication.nota";
  stateDatabase = "${dir}/clavifaber.redb";

  # The Converge request as one positional NOTA record. Per
  # clavifaber's ARCHITECTURE.md, fields are:
  # identity_directory, node_name, publication_output,
  # yggdrasil (Option<YggdrasilPlan>),
  # wifi_client_certificate_pem, state_database,
  # certificate_authority, server_certificate, node_certificates.
  #
  # `yggdrasil = None` today: the existing yggdrasil network module at
  # modules/nixos/network/yggdrasil.nix owns the runtime keypair via its
  # own preStart seed step. Passing a YggdrasilPlan here would have
  # clavifaber mint a *different* keypair, so publication.nota would
  # carry a yggdrasil identity that isn't the one the daemon actually
  # uses. The consolidation — clavifaber as the sole owner of the
  # per-host yggdrasil keypair, with the network module reading from
  # the clavifaber-written file — is deferred (tracked separately).
  convergeRequest = ''
    (Converge "${dir}" ${config.networking.hostName} "${publicationFile}" None None "${stateDatabase}" None None [])
  '';
in
{
  environment.systemPackages = [ clavifaber ];

  # Clavifaber writes private key bytes; restrict the directory.
  systemd.tmpfiles.rules = [
    "d ${dir} 0700 root root -"
  ];

  systemd.services.complex-init = {
    description = "Clavifaber convergence — host key material + publication";
    wantedBy = [ "multi-user.target" ];
    before = [
      "NetworkManager.service"
      "sshd.service"
    ];
    # `yggdrasil` lives on PATH so the YggdrasilKey actor can mint and
    # statically derive identity material when the YggdrasilPlan
    # consolidation lands. Harmless when yggdrasil = None.
    path = [ pkgs.yggdrasil ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${clavifaber}/bin/clavifaber '${convergeRequest}'
    '';
  };
}
