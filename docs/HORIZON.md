# Horizon — schema and method table

The horizon is the view one node has of its cluster: its own attrs, its sibling
nodes (`exNodes`), its users, and the cluster itself. Raw horizon is declared
in `maisiliym/datom.nix`; enriched horizon (with `methods.*`) is the fixed
point of type-check + method-computation.

This document is the single source of truth for the horizon schema. Both the
Rust tool (`horizon-check`) and the Nix fallback in `lib/default.nix` must
stay faithful to it.

## Structural shape

```
Horizon = {
  cluster : Cluster
  node    : Node            # the local node; extra nodeMethods on it
  exNodes : { <name>: Node }  # every other node in the cluster
  users   : { <name>: User }
}

Cluster = {
  name    : enum clusterNames
  methods : ClusterMethods
}

Node = {
  name                : string
  species             : enum nodeSpecies
  size                : enum magnitude   # 0..3
  trust               : enum magnitude   # 0..3
  machine             : Machine
  io                  : Io               # on horizon.node only
  preCriomes          : PreCriomes       # raw — not exposed in enriched node
  linkLocalIps        : [LinkLocalIp]
  nodeIp              : string?
  wireguardPreCriome  : string?
  nordvpn             : bool
  wifiCert            : bool
  wireguardUntrustedProxies : [attrs]

  # derived (replicated to the enriched output):
  ssh                 : string           # "ssh-ed25519 <preCriome>"
  yggPreCriome        : string?
  yggAddress          : string?
  yggSubnet           : string?
  nixPreCriome        : string?          # raw signing key (not domain-prefixed)
  criomeDomainName    : string           # "<node>.<cluster>.criome"
  system              : string           # "x86_64-linux" / "aarch64-linux"
  nbOfBuildCores      : int
  typeIs              : { <species>: bool }

  methods             : NodeMethods
}

User = {
  name       : string
  style      : string
  species    : enum userSpecies
  keyboard   : enum keyboard
  size       : magnitude
  trust      : magnitude
  preCriomes : { <nodeName>: UserPreCriome }  # ssh + keygrip per node
  githubId   : string

  methods    : UserMethods
}
```

## Method DAG (one-to-one with `mkHorizonModule.nix`)

### `Node.methods` (every node)

| name | type | formula |
|-|-|-|
| `isFullyTrusted` | bool | `trust == 3` |
| `sizedAtLeast` | `{ min, med, max : bool }` | size >= 1 / 2 / 3 |
| `isBuilder` | bool | `!typeIs.edge && isFullyTrusted && (sizedAtLeast.med || behavesAs.center) && hasBasePrecriads` |
| `isDispatcher` | bool | `!behavesAs.center && isFullyTrusted && sizedAtLeast.min` |
| `isNixCache` | bool | `behavesAs.center && sizedAtLeast.min && hasBasePrecriads` |
| `hasNixPreCriad` | bool | `nixPreCriome != null && nixPreCriome != ""` |
| `hasYggPrecriad` | bool | `yggAddress != null && yggAddress != ""` |
| `hasSshPrecriad` | bool | `preCriomes.ssh present` |
| `hasWireguardPrecriad` | bool | `wireguardPreCriome != null` |
| `hasNordvpnPrecriad` | bool | `nordvpn == true` |
| `hasWifiCertPrecriad` | bool | `wifiCert == true` |
| `hasBasePrecriads` | bool | `hasNixPreCriad && hasYggPrecriad && hasSshPrecriad` |
| `sshPrecriome` | string | `hasSshPrecriad ? ssh : ""` |
| `nixPreCriome` | string | `hasNixPreCriad ? "${criomeDomainName}:${raw}" : ""` |
| `nixCacheDomain` | `string?` | `isNixCache ? "nix.${criomeDomainName}" : null` |
| `nixUrl` | `string?` | `isNixCache ? "http://${nixCacheDomain}" : null` |
| `behavesAs.largeAI` | bool | `typeIs.largeAI || typeIs."largeAI-router"` |
| `behavesAs.center` | bool | `typeIs.center || behavesAs.largeAI` |
| `behavesAs.router` | bool | `typeIs.hybrid || typeIs.router || typeIs."largeAI-router"` |
| `behavesAs.edge` | bool | `typeIs.edge || typeIs.hybrid || typeIs.edgeTesting` |
| `behavesAs.nextGen` | bool | `typeIs.edgeTesting || typeIs.hybrid` |
| `behavesAs.lowPower` | bool | `typeIs.edge || typeIs.edgeTesting` |
| `behavesAs.bareMetal` | bool | `machine.species == "metal"` |
| `behavesAs.virtualMachine` | bool | `machine.species == "pod"` |
| `behavesAs.iso` | bool | `!virtualMachine && io.disks == {}` |
| `hasVideoOutput` | bool | `behavesAs.edge` |

### `User.methods`

| name | type | formula |
|-|-|-|
| `sizedAtLeast` | `{ min, med, max }` | see above |
| `hasPreCriome` | bool | `preCriomes has node.name` |
| `emailAddress` | string | `"${user.name}@${cluster.name}.criome.net"` |
| `matrixID` | string | `"@${user.name}:${cluster.name}.criome.net"` |
| `gitSigningKey` | `string?` | `hasPreCriome ? "&${keygrip_for_this_node}" : null` |
| `useColemak` | bool | `keyboard == "colemak"` |
| `useFastRepeat` | bool | `fastRepeat ?? true` |
| `isMultimediaDev` | bool | `species in { "multimedia", "unlimited" }` |
| `isCodeDev` | bool | `species in { "code", "unlimited" }` |
| `sshCriomes` | `[string]` | ssh-formatted pubkeys from every preCriome |
| `ssh` | string | *only when `hasPreCriome`* — ssh-formatted pubkey for this node |

### `Cluster.methods`

| name | type | formula |
|-|-|-|
| `trustedBuildPreCriomes` | `[string]` | `map (n: nodes.${n}.methods.nixPreCriome) nodeNames` |

### Node-scoped extras (`horizon.node.methods`, post-zone only)

Attached to `horizon.node.methods` on top of the `NodeMethods` above. Not
present on `exNodes.<n>.methods`.

| name | type | formula |
|-|-|-|
| `builderConfigs` | `[attrs]` | one entry per `n where exNodes.${n}.methods.isBuilder` |
| `cacheURLs` | `[string]` | `nixUrl` of every `isNixCache` exNode |
| `exNodesSshPreCriomes` | `[string]` | `exNodes.${n}.ssh` for every exNode |
| `dispatchersSshPreCriomes` | `[string]` | `exNodes.${n}.ssh` of dispatchers |
| `adminSshPreCriomes` | `[string]` | unique admin-user ssh keys from fully-trusted nodes |
| `chipIsIntel` | bool | `machine.arch in { "x86-64", "i686" }` |
| `modelIsThinkpad` | bool | `machine.model in thinkpadModels` |
| `useColemak` | bool | `io.keyboard == "colemak"` |
| `computerIs.<model>` | bool | one flag per known model, `true` for this node's model |
| `wireguardUntrustedProxies` | `[attrs]` | passthrough |

## Enums (from `mkCrioSphere/speciesModule.nix` — see legacy repo)

- `magnitude`: `0 .. 3`
- `nodeSpecies`: `center`, `edge`, `edgeTesting`, `hybrid`, `router`, `largeAI`,
  `largeAI-router`
- `userSpecies`: `code`, `multimedia`, `unlimited`, ...
- `keyboard`: `colemak`, `qwerty`, ...
- `machineSpecies`: `metal`, `pod`

## Invariants

- Every method is **derivable from raw input alone** — no Nix-evaluation-time
  context leaks in. This is what lets horizon-check reproduce it faithfully.
- `cluster.methods.trustedBuildPreCriomes` is the only cluster-scoped method
  today; keep the cluster / node / user / extras boundary sharp.
- `horizon.node.methods` is a superset of `exNodes.<node>.methods` (adds the
  node-scoped extras).
