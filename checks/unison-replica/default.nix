{ pkgs }:
let
  inherit (pkgs) lib;
  synchronization = { master = "master"; replica = "replica"; tree = "Code"; };
  account = { name = "example"; hasPublicKey = false; synchronizations = [ synchronization ]; };
  declaredUser = { example = { name = "example"; home = "/home/example"; group = "users"; }; };
  evaluate = node: users: package: (lib.evalModules {
    specialArgs = { inherit pkgs; horizon = { node.name = node; inherit users; }; };
    modules = [
      ../../modules/nixos/unison.nix
      {
        options.environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
        options.users.users = lib.mkOption { type = lib.types.attrs; default = {}; };
        options.home-manager.users = lib.mkOption { type = lib.types.attrs; default = {}; };
        options.systemd.services = lib.mkOption { type = lib.types.attrs; default = {}; };
        options.systemd.tmpfiles.settings = lib.mkOption { type = lib.types.attrs; default = {}; };
        config.users.users = declaredUser;
        config.criomos.unisonReplica.package = package;
      }
    ];
  }).config;
  replica = evaluate "replica" [ account ] pkgs.unison;
  master = evaluate "master" [ account ] pkgs.unison;
  other = evaluate "other" [ account ] pkgs.unison;
  empty = evaluate "replica" [ (account // { synchronizations = []; }) ] pkgs.unison;
  custom = evaluate "replica" [ account ] pkgs.hello;
  root = { "/home/example/Code".d = { user = "example"; group = "users"; }; };
in
assert replica.environment.systemPackages == [ pkgs.unison ];
assert master.environment.systemPackages == [];
assert other.environment.systemPackages == [];
assert empty.environment.systemPackages == [];
assert custom.environment.systemPackages == [ pkgs.hello ];
assert replica.users.users == declaredUser;
assert replica.home-manager.users == {};
assert replica.systemd.services == {};
assert replica.systemd.tmpfiles.settings == { unison-roots = root; };
assert master.systemd.tmpfiles.settings == { unison-roots = root; };
assert other.systemd.tmpfiles.settings == {};
assert empty.systemd.tmpfiles.settings == {};
pkgs.runCommand "unison-replica-system-program-contract" {} ''
  touch "$out"
''
