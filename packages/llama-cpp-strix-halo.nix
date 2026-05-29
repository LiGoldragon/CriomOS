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
  npmRoot = "tools/ui";
  npmDepsHash = "sha256-Iyg8FpcTKf2UYHuK7mA3cTAqVaLcQPcS0YCa5Qf01Gc=";
})
