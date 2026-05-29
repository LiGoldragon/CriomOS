{ pkgs, ... }:
# Vulkan — faster and more stable than ROCm on Strix Halo (gfx1151).
(pkgs.llama-cpp.override { vulkanSupport = true; }).overrideAttrs (_: {
  version = "9404";
  src = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b9404";
    hash = "sha256-LFomOs5RjGu+zi8giHuAgcvo03AxdgCT1CGR3ht8Ih4=";
  };
  npmDepsHash = "sha256-DxgUDVr+kwtW55C4b89Pl+j3u2ILmACcQOvOBjKWAKQ=";
})
