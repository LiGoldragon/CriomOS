{ pkgs, ... }:
# Vulkan — faster and more stable than ROCm on Strix Halo (gfx1151).
pkgs.llama-cpp.override { vulkanSupport = true; }
