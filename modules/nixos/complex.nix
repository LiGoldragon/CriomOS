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
  # yggdrasil_address, yggdrasil_public_key,
  # wifi_client_certificate_pem, state_database,
  # certificate_authority, server_certificate, node_certificates.
  convergeRequest = ''
    (Converge "${dir}" ${config.networking.hostName} "${publicationFile}" None None None "${stateDatabase}" None None [])
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
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${clavifaber}/bin/clavifaber '${convergeRequest}'
    '';
  };
}
