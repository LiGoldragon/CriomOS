{ pkgs, ... }:
let
  io = builtins.fromJSON (builtins.readFile ./ouranos-io.json);
  evaluate = horizon: import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = { inherit horizon; };
    modules = [
      ../../modules/nixos/disks/preinstalled.nix
      { system.stateVersion = "26.11"; }
    ];
  };
  evaluated = evaluate { node = { inherit io; }; };
in
assert evaluated.config.fileSystems."/".device == io.disks."/".device;
assert evaluated.config.fileSystems."/boot".fsType == "vfat";
assert evaluated.config.boot.loader.systemd-boot.enable;
assert (builtins.head evaluated.config.swapDevices).size == (builtins.head io.swapDevices).sizeMebibytes;
assert evaluated.config.zramSwap.memoryPercent == io.compressedSwap.memoryPercent;
pkgs.runCommand "preinstalled-io-projection" { } "touch $out"
