{
  pkgs,
  constants,
  ...
}:
let
  inherit (constants.fileSystem.complex) dir;

  clavifaber = pkgs.callPackage ../clavifaber.nix { };

in
{
  environment.systemPackages = [ clavifaber ];

  systemd.services.complex-init = {
    description = "Generate node identity complex (Ed25519 keypair)";
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
      ${clavifaber}/bin/clavifaber complex-init --dir "${dir}"
      ${clavifaber}/bin/clavifaber derive-pubkey --dir "${dir}"
    '';
  };
}
