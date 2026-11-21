{ pkgs, ... }:

let
  inherit (pkgs) yggdrasil;
in

# Remove this override in the same change that takes a Yggdrasil release
# carrying the Ironwood repair for a retransmitted authenticated session init.
assert yggdrasil.version == "0.5.15";
yggdrasil.overrideAttrs (previous: {
  postConfigure = (previous.postConfigure or "") + ''
    grep -Fx '# github.com/Arceliar/ironwood v0.0.0-20261023231900-0712eccbb962' vendor/modules.txt
    ironwood=vendor/github.com/Arceliar/ironwood
    chmod u+w "$ironwood/encrypted" "$ironwood/encrypted/session.go"
    patch --fuzz=0 --directory="$ironwood" -p1 < ${./retransmitted-init.patch}
  '';
})
