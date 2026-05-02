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
local literals. When a module needs to flip behavior per node, it reads the
relevant boolean off the projected horizon (`horizon.node.typeIs.*`,
`horizon.node.behavesAs.*`, `horizon.node.has*PubKey`, etc.) rather than
hardcoding host names or local literals.

When a new toggle requires horizon truth absent from the current schema,
extend the typed schema in `horizon-rs` (`/home/li/git/horizon-rs/lib/src/`)
so the projected horizon exposes the new field, and consume that field
directly. Schema changes are tracked as horizon-rs beads.

## Cluster Truth Authority

CriomOS is **network-neutral**: it does not enumerate clusters or nodes.
The truth source is the lojix-projected horizon input.

For the LiGoldragon kriom, lojix reads `goldragon/datom.nota`, projects
it through `horizon-rs`, writes content-addressed `horizon` and `system`
flake inputs plus a deployment-shape input, and invokes this repo's
single system surface:
`nixosConfigurations.target`.

### Edit flow

- Edit cluster / node / user / trust truth in `goldragon/datom.nota`.
  Any node name, role, connectivity, or identity change begins there.
- `horizon-rs` validates the proposal and computes the enriched
  horizon. Use `lojix-cli eval` / `lojix-cli build` when checking the
  projected view against CriomOS.
- CriomOS modules read `horizon.node.*`, `horizon.exNodes.*`, and
  `horizon.users.*`; they never add node or cluster literals.

### Build/deploy authority

- Use flake-native commands only. No `<nixpkgs>` / `NIX_PATH`; reach
  for `nix run nixpkgs#jq -- ...` when you need a tool.
- Push before building. Lojix consumes a pinned GitHub revision; unpushed
  local commits are invisible.
- Public system surface:
  `github:LiGoldragon/CriomOS/<rev>#nixosConfigurations.target.config.system.build.toplevel`.
- Normal build/deploy entry point:
  `lojix-cli build|eval|deploy --cluster <C> --node <N> --source <proposal> --criomos github:LiGoldragon/CriomOS/<rev>`.
- Prefer `lojix-cli deploy --action boot` for first-touch deploys. Use
  `boot-once` for headless/riskier nodes, and `switch` only when live
  activation is intended.
