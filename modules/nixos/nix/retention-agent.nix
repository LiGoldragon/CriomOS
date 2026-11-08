{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) boolToString;
  sizeMagnitude = horizon.node.size;
  size = {
    medium = builtins.elem sizeMagnitude [
      "Medium"
      "Large"
      "Max"
    ];
    large = builtins.elem sizeMagnitude [
      "Large"
      "Max"
    ];
  };
in
{
  nix = {
    # Nix performs this work as store paths are written.  It is event work,
    # distinct from the scheduled optimiser below.
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
