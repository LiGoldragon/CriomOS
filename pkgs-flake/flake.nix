{
  description = "Pkgs flake — instantiates nixpkgs for one (nixpkgs-rev, system) tuple. Lives inside CriomOS but is consumed via path:./pkgs-flake so its evaluation is isolated in nix's flake-eval cache: same (nixpkgs.narHash, system.narHash) → cache hit, regardless of what changed in CriomOS otherwise. lojix overrides the `system` input per deploy; CriomOS's nixpkgs is propagated via `follows`.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    system.url = "path:./stubs/no-system";
  };

  outputs = { self, nixpkgs, system }: {
    pkgs = import nixpkgs {
      system = system.system;
      config.allowUnfree = true;
    };
  };
}
