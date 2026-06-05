# INTENT — CriomOS

CriomOS is the NixOS host platform for the sema ecosystem. It consumes projected Horizon data and exposes one network-neutral `nixosConfigurations.target` surface for deployment.

## Constraints

- Cluster, node, user, and deployment identity enter through lojix-projected inputs. CriomOS modules render projected facts; they do not branch on concrete cluster or node names.
- NixOS-level capabilities live here. Home Manager profile selection, user packages, and desktop-owned configuration live in CriomOS-home.
- Swap and compressed-swap policy for a node is authored as cluster data, projected through Horizon, and rendered here into NixOS swap/zram options.
