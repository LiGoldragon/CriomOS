{ inputs, pkgs, ... }:

let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  hostName = "fixture-host";
  complexDir = "/var/lib/fixture-complex";
  sshdHostPublicKey = "/etc/ssh/ssh_host_ed25519_key.pub";
  publicationFile = "${complexDir}/publication.dotos";

  clavifaber = pkgs.writeShellScriptBin "clavifaber" "";
  configuration = lib.nixosSystem {
    inherit pkgs;
    specialArgs = {
      constants.fileSystem.complex.dir = complexDir;
      deployment.includeComplex = true;
      inputs.clavifaber.packages.${system}.default = clavifaber;
    };
    modules = [
      ../../modules/nixos/complex.nix
      {
        networking.hostName = hostName;
        system.stateVersion = "26.05";
      }
    ];
  };

  publicationCommand = builtins.unsafeDiscardStringContext configuration.config.systemd.services.complex-init.script;
  expectedRequest = "PublicKeyPublicationWriting.{${hostName} {${sshdHostPublicKey}} None None ${publicationFile}}";
  expectedCommand = builtins.unsafeDiscardStringContext "${clavifaber}/bin/clavifaber '${expectedRequest}'";
in
assert lib.assertMsg (lib.hasInfix expectedCommand publicationCommand)
  "complex-init must invoke ClaviFaber with the typed PublicKeyPublicationWriting request";
pkgs.runCommand "clavifaber-publication-request" { } ''
  touch "$out"
''
