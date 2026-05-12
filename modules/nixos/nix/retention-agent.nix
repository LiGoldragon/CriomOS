{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) boolToString;
  inherit (horizon.node) size;
in
{
  nix = {
    settings.auto-optimise-store = true;

    # Lowest priorities.
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedPriority = 7;

    extraOptions = ''
      keep-derivations = ${boolToString size.medium}
      keep-outputs = ${boolToString size.large}
    '';
  };
}
