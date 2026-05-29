{ pkgs, ... }:
# Vulkan — faster and more stable than ROCm on Strix Halo (gfx1151).
(pkgs.llama-cpp.override { vulkanSupport = true; }).overrideAttrs (_: {
  version = "8470";
  src = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b8470";
    hash = "sha256-ZX5eaeNZYZIzJyEV3k0Dpcr6L84ccm4YRI++pY9hlJU=";
  };
  npmDepsHash = "sha256-DxgUDVr+kwtW55C4b89Pl+j3u2ILmACcQOvOBjKWAKQ=";
})
