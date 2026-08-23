{ inputs, pkgs, ... }:

# The Dotos request is authored by the NixOS module but parsed only when the
# oneshot unit runs.  Run that exact generated script with the pinned
# ClaviFaber binary, rather than recognizing a hand-copied command string.
let
  inherit (inputs.nixpkgs) lib;

  hostName = "fixture-host";
  fixtureDirectory = "/build/clavifaber-publication-request";
  generatedSshdHostPublicKey = "/etc/ssh/ssh_host_ed25519_key.pub";
  fixtureSshdHostPublicKey = "${fixtureDirectory}/ssh_host_ed25519_key.pub";
  publicationFile = "${fixtureDirectory}/publication.dotos";

  configuration = lib.nixosSystem {
    inherit pkgs;
    specialArgs = {
      inherit inputs;
      constants.fileSystem.complex.dir = fixtureDirectory;
      deployment.includeComplex = true;
    };
    modules = [
      ../../modules/nixos/complex.nix
      {
        networking.hostName = hostName;
        system.stateVersion = "26.05";
      }
    ];
  };

  complexInit = pkgs.writeShellScript "complex-init-fixture" (
    # `/etc` is unavailable in a sandbox. Redirect only the existing-key path;
    # every DOTOS variant and product shape remains the module's generated one.
    lib.replaceStrings
      [ generatedSshdHostPublicKey ]
      [ fixtureSshdHostPublicKey ]
      configuration.config.systemd.services.complex-init.script
  );
in
pkgs.runCommand "clavifaber-publication-request" {
  nativeBuildInputs = [ pkgs.openssh ];
} ''
  set -eu

  mkdir -p ${lib.escapeShellArg fixtureDirectory}
  ssh-keygen -q -t ed25519 -N "" -f ${lib.escapeShellArg (lib.removeSuffix ".pub" fixtureSshdHostPublicKey)}

  ${complexInit}
  test -s ${lib.escapeShellArg publicationFile}
  test "$(stat -c %a ${lib.escapeShellArg publicationFile})" = 644
  grep -F ${lib.escapeShellArg hostName} ${lib.escapeShellArg publicationFile}

  touch "$out"
''
