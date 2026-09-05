{
  lib,
  horizon,
  ...
}:
let
  inherit (lib) boolToString;
  hasMagnitude = values: builtins.elem horizon.node.size values;
  isMedium = hasMagnitude [
    "Medium"
    "Large"
    "Max"
  ];
  isLarge = hasMagnitude [
    "Large"
    "Max"
  ];
in
{
  nix = {
    settings.auto-optimise-store = true;

    # Lowest priorities.
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedPriority = 7;

    extraOptions = ''
      keep-derivations = ${boolToString isMedium}
      keep-outputs = ${boolToString isLarge}
    '';
  };
}
