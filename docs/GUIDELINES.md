# Sema Object Style — Unified Architecture and Naming Guide

This document defines the architectural, naming, and documentation rules for
object‑oriented codebases that follow Sema principles and the Criome lineage.
The rules are structural rather than stylistic. Violations indicate missing
abstraction, semantic duplication, or category error.

## Naming Is a Semantic Layer

*Names are a pseudo‑code layer that carries intent, constraints, and future
legality.* Meaning is distributed across repository name, directory path, module
name, type name, method name, and schema definition. Meaning appears exactly
once at the highest valid layer. Repetition across layers is forbidden.

Correct designs do not produce very long names. When a name grows long, it
indicates that an abstraction layer is missing and that an additional object or
module must be introduced.

A name is not a description. A name is a commitment.

```rust
// ❌ BAD: meaning repeated and concatenated
struct ShowHelloWorldFromStandardInApplication;

// ✅ GOOD: meaning layered by structure
// repo: hello_world
// bin: create
struct Application;
```

## Capitalization Is a Semantic Operator

*Capitalization declares ontology, not style.*

`PascalCase` denotes objects (types and traits). `snake_case` denotes actions,
relations, or flow (methods and fields).

Any suffix that restates objecthood (`Object`, `Type`, `Entity`, `Model`,
`Manager`) is invalid.

```rust
// ❌ BAD
struct UserObject;

// ✅ GOOD
struct User;
```

## Everything Is an Object

There are no free functions in reusable code. All behavior is attached to named
types or traits via `impl` blocks. Message‑passing between objects is the sole
computation model.

Binaries are exempt only as orchestration shells and contain no reusable logic.

```rust
use core::str::FromStr;

// ❌ BAD
fn parse_message(input: &str) -> Message { ... }

// ✅ GOOD: existing trait domain expressed as a trait implementation
impl FromStr for Message {
	type Err = MessageParseError;

	fn from_str(input: &str) -> Result<Self, Self::Err> {
		...
	}
}

// Call site
let message: Message = "...".parse()?;
```

## Trait‑Domain Rule

*Any behavior that falls within the semantic domain of an existing trait must be
expressed as a trait implementation.* Inherent methods are not used to bypass
existing trait domains.

Creating new nouns to encode trait composition is forbidden.

```rust
use std::fs::File;
use std::io::Read;

// `File` already inhabits the `Read` trait domain
let mut file = File::open("data.txt")?;
let mut buffer = String::new();
file.read_to_string(&mut buffer)?;
```

```rust
// ❌ BAD: composite role encoded as noun
struct FileReader;
```

## Objects Exist; Flows Occur

Objects are nouns that exist independently of execution. Flows are verbs that
occur during execution. A name that describes a flow cannot name an object.

```rust
// ❌ BAD: flow encoded as object
struct ShowGreetingFromStdin;

// ✅ GOOD
struct Greeting;
```

## Direction Encodes Action

*Direction replaces verbs.* When direction is explicit, action is implied.

`from_*` implies acquisition or construction. `to_*` implies emission or
projection. `into_*` implies consuming transformation.

Verbs such as `read`, `write`, `load`, or `save` are forbidden when direction
already conveys meaning.

```rust
// ❌ BAD
impl Data {
	pub fn read_from_stdin() -> Self { ... }
}

// ✅ GOOD
impl Data {
	pub fn from_stdin() -> Self { ... }
}
```

## Construction Resolves to the Receiving Type

All construction and parsing logic resides on the receiving type. The identity
claimed by the method name is always the return type.

```rust
use core::str::FromStr;

// ❌ BAD
fn parse_config(input: String) -> Config;

// ✅ GOOD: existing trait domain expressed as a trait implementation
impl FromStr for Config {
	type Err = ConfigParseError;

	fn from_str(input: &str) -> Result<Self, Self::Err> {
		...
	}
}

// Alternative when ownership is semantically required
impl From<String> for Config {
	fn from(input: String) -> Self {
		...
	}
}

// Call sites
let config: Config = "...".parse()?;
let config = Config::from(string_value);
```

## Sema Object Rule — Single Object In, Single Object Out

*All values that cross object boundaries are Sema objects.* Primitive types are
internal representations only.

Every method accepts at most one explicit object argument (excluding `self`) and
returns exactly one object. When multiple inputs or outputs are required, a new
object must be specified to contain them.

```rust
// ❌ BAD
fn transform(a: A, b: B) -> (C, D);

// ✅ GOOD
struct TransformationInput { a: A, b: B }
struct TransformationOutput { c: C }

impl TransformationOutput {
	pub fn from_input(input: TransformationInput) -> Self { ... }
}
```

## Schema Is Sema; Encoding Is Incidental

All transmissible objects are defined in Sema schemas. *Cap’n Proto is a
temporary wire representation* and must not appear in domain APIs, naming, or
documentation.

```rust
// Domain code speaks Sema
use sema::hello_world;

let message = hello_world::Builder::new();
```

## Filesystem as Semantic Layer

Repository names, directory paths, and module boundaries are semantic layers.
Inner layers assume outer context. Names never restate repository philosophy,
lineage, or purpose.

```text
hello_world/
  crates/
	types/
	bin/
	  create/
```

## Documentation Protocol

All documentation is *impersonal, timeless, and precise*.

No first‑ or second‑person language. No humor or evaluative commentary. Behavior
is stated as fact. Non‑boilerplate behavior is documented. Boilerplate is not.

```rust
/// Constructs a `Greeting` from a Sema `Text` value.
///
/// Returns a fully initialized object.
```

## Node-Horizon Toggle Policy

Any non-default NixOS switch must be driven by node-horizon data rather than
local literals. The handling of `logind.settings.Login.HandleLidSwitch` in
`nix/mkCriomOS/metal/default.nix` now reads a horizon-derived `behavesAs.center`
boolean that is rooted in `horizon.node.typeIs.center`, ensuring the no-suspend
behavior is explicitly center-driven. The example relies on the center/server
semantics, where the central server nodes built for CriomOS ignore the lid switch
while the general server population falls back to the default suspend action.
When a new toggle requires horizon truth that is absent from the current schema,
extend the CriomOS/CrioSphere schema (for example `capnp/criosphere.capnp`) so
the node horizon exposes an optional or defaulted value, and consume that value
directly instead of hardcoding the behavior inside a module.

## Operator Node/Network Truth Authority

**MUST UPDATE WHEN EDITING REPO:** When node or network behavior is touched, operators update the Maisiliym source (`datom.nix` / `NodeProposal.nodes.*`) first, then reread this guidance and `docs/AGENTS.md` before touching CriomOS artifacts. For deployment/build consumption, prefer the GitHub flake source `github:LiGoldragon/maisiliym`; do not rely on ad-hoc local checkout overrides in this lane.

### Edit authority
- Maisiliym owns node/network truth inside `datom.nix` via `NodeProposal.nodes.*`. Any node name, role, connectivity, or identity change begins by editing the corresponding `NodeProposal` entry so horizon data exports the new truth before any CriomOS consumer is built or deployed.
- Maintain the Maisiliym trust model (users, hardware assignments, disk layout) in the same `NodeProposal` block and test via the toparranged validation (`nix flake check` or the Maisiliym validation job) before downstream operators consume it.
- For deployment/build consumption, operators and deploy agents should treat `github:LiGoldragon/maisiliym` as the canonical flake source. Local path overrides such as `/home/li/git/maisiliym` are historical/operator scratch only and are not the preferred deploy lane anymore.

### Build/deploy authority
- CriomOS consumes that Maisiliym truth through horizon exports (see `nix/mkCrioZones/mkHorizonModule.nix` for the export wiring) and the network modules (`nix/mkCriomOS/network/default.nix`, `nix/mkCriomOS/network/unbound.nix`). Builders read `node.name`, `node.yggAddress`, and `exNodes` from horizon data rather than adding new literals.
- Update horizon exports before adjusting CriomOS DNS, host tables, or kube provisioning. After the Maisiliym change lands, rerun the exact CriomOS attr build and deployment flow so unbound, DHCP, and activation regenerate from the fresh node truth.
- Use flake-native commands only. Do not use `<nixpkgs>` / `NIX_PATH` style invocations in this repo; when you need environment packages, use flake registry references such as `nix shell nixpkgs#jq`.
- Exact build commands:
  - `nix build .#crioZones.maisiliym.ouranos.os --no-link --print-out-paths --refresh`
  - `nix build .#crioZones.maisiliym.prometheus.os --no-link --print-out-paths --refresh`
  - `nix build .#crioZones.maisiliym.ouranos.deployManifest --no-link --print-out-paths --refresh`
  - `nix build .#crioZones.maisiliym.prometheus.deployManifest --no-link --print-out-paths --refresh`
  - If an override is required for the Maisiliym source, use only `--override-input maisiliym github:LiGoldragon/maisiliym`.
- Exact deployment flow:
  - Use `criomos-deploy <cluster> <node>` to build fullOs on the target, set the system profile, and activate. Use `--boot` for kernel changes, `--commit <hash>` for a specific revision.
  - Replace `<cluster>` and `<node>` with the Maisiliym cluster and node names (e.g. `criomos-deploy maisiliym prometheus`).
  - To reload a user's compositor shell after deployment: `criomos-reload-shell <cluster> <node> <user>`.
  - The deploy script builds via `github:LiGoldragon/CriomOS/<commit>#crioZones.<cluster>.<node>.fullOs` on the target node over SSH, using the current main commit by default.
  - `ouranos`: can also deploy locally since criomos-deploy is in systemPackages.
