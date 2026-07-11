{
  pkgs,
  inputs,
}:
let
  deploymentLock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  homeLock = builtins.fromJSON (builtins.readFile "${inputs.criomos-home}/flake.lock");
  spiritCargoLock = builtins.readFile "${inputs.spirit}/Cargo.lock";

  require = condition: message: if condition then true else throw message;
  deploymentNodes = deploymentLock.nodes;
  homeNodes = homeLock.nodes;
in
assert require (deploymentNodes.criomos-home.locked.rev == "8cc609ebc2c5f145024510bd3fdbd7cd9f406f67") "unexpected CriomOS-home revision";
assert require (deploymentNodes.spirit.locked.rev == "f9f5266abec8a0bcf43b8bcc93cf066aa9f97ea2") "unexpected Spirit revision";
assert require (deploymentNodes.spirit-judge.locked.rev == "c2303a30ff88fea527a8075b22f1d598a80fdb80") "unexpected spirit-judge revision";
assert require (homeNodes.spirit-judge.locked.rev == "c2303a30ff88fea527a8075b22f1d598a80fdb80") "Home does not consume the witness producer";
assert require (pkgs.lib.hasInfix "signal-spirit-judge.git?rev=7c25b71a34858c0d912dff8fd0b4f4ac213d7cd1" spiritCargoLock) "Spirit does not pin the approved signal contract";
pkgs.runCommand "spirit-judge-pin-chain" {
  allowSubstitutes = false;
  preferLocalBuild = false;
} ''
  touch "$out"
''
