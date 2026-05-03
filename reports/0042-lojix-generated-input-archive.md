# Lojix Generated Input Archive

## Question

`lojix-cli` now publishes generated deploy inputs as archive flakes
instead of passing local path inputs to Nix. The default publisher needs a
network surface that is present on the archive host.

## Shape

CriomOS provides that surface on nodes whose projected horizon marks them
as Nix-cache nodes. The module creates:

```text
/var/lib/lojix-inputs
```

and serves it under:

```text
http://<node criome domain>/lojix-inputs/
```

For the LiGoldragon cluster, Prometheus is the default target used by
`lojix-cli`:

```text
http://prometheus.goldragon.criome/lojix-inputs
```

## Boundary

The module is network-neutral. It does not name Prometheus or any
cluster; it keys only off the projected `horizon.node.isNixCache` field
and the node's projected Criome domain name.

## Operational Implication

`lojix-cli` uploads archives over SSH as root and Nix fetches them over
HTTP. If the archive host has not been deployed with this module yet,
publication or fetch will fail; lojix does not silently fall back to
local path inputs.
