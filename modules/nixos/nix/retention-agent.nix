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
    settings.auto-optimise-store = true;

    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-old";
    };

    # Lowest priorities.
    daemonCPUSchedPolicy = "idle";
    daemonIOSchedPriority = 7;

    extraOptions = ''
      keep-derivations = ${boolToString size.medium}
      keep-outputs = ${boolToString size.large}
    '';
  };
}
