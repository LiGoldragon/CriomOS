# Sema Object Style — Unified Nix Architecture and Naming

This document adapts the Sema architectural, naming, and documentation rules for Nix-based projects. The rules are structural. Violations often indicate missing abstraction, semantic duplication, or category error.

## Naming Is a Semantic Layer

*Names are a pseudo-code layer that carries intent and constraints.* Meaning is distributed across repository name, directory path, file name, and attribute paths. Meaning should appear exactly once at the highest valid layer. Repetition across layers is forbidden.

Correct designs do not produce very long attribute names. When a name grows long, it indicates that an abstraction layer is missing and that an additional nested attrset or module must be introduced.

A name is not a description. A name is a commitment.

```nix
# ❌ BAD: meaning repeated and concatenated
let
  showHelloWorldFromStandardInApplication = { ... };
in
  ...

# ✅ GOOD: meaning layered by structure
# repo: hello-world
# file: pkgs/create/default.nix
{
  application = { ... };
}
```

## Naming Convention Declares Role

*Attribute naming declares role, not style.*

`camelCase` denotes functions, relations, or flow. `kebab-case` denotes static package names or attributes that are not functions. This aligns with the conventions used throughout `nixpkgs`.

A suffix that restates the type (`Package`, `Module`, `Attrset`) is invalid.

```nix
# In a flake's `outputs` section:
{ self, nixpkgs }: {
  # ❌ BAD: "Package" is redundant in this context
  packages.x86_64-linux.userPackage = nixpkgs.legacyPackages.x86_64-linux.hello;

  # ✅ GOOD: The context makes the role clear
  packages.x86_64-linux.user = nixpkgs.legacyPackages.x86_64-linux.hello;
}
```

## Group Related Functions in Attrset Namespaces

While files returning functions are a core Nix idiom (especially for modules and overlays), avoid creating a large number of disconnected, single-function utility files. Instead, group related helper functions into a single "namespace" attrset. This provides clarity and better organization.

```nix
# ❌ AVOID: A loose collection of single-purpose utility files for one "object".
# file: lib/parse-message.nix
# file: lib/validate-message.nix
# file: lib/serialize-message.nix

# ✅ PREFER: Grouping related functions into a single namespace.
# file: lib/message.nix
{
  fromJSON = input: ... ;
  isValid = msg: ... ;
  toJSON = msg: ... ;
}
```

## Standard Library (`lib`) Domain Rule

*Any behavior that falls within the semantic domain of an existing `lib` function must be expressed using that function.* Do not re-implement standard library patterns for merging, mapping, or filtering.

```nix
# `lib.recursiveUpdate` already inhabits the deep-merge domain.
let
  defaults = { options.a = 1; };
  overrides = { options.b = 2; };
in
  lib.recursiveUpdate defaults overrides
```

## Attrsets Exist; Flows Occur

Attrsets are nouns that exist independently of evaluation. Flows (functions and processes) are verbs that occur during evaluation. A name that describes a flow cannot name a static entity like a module or package.

This principle is most visible in module design.

```nix
# ❌ BAD: A module named after an action ("flow"). Its options are hard to predict.
# What would go inside this module?
home.modules.enableAutomaticBackups = { ... };


# ✅ GOOD: A module named after a noun, with actions/states as options.
# The "object" is `backups`, the "flow" is the backup process it manages.
home.modules.backups = {
  enable = true;
  automatic = true;
  frequency = "daily";
};
```

## Direction Encodes Action

*Direction replaces verbs.* When direction is explicit, action is implied.

`from*` implies acquisition or construction. `to*` implies emission or projection.

Verbs such as `read`, `write`, `load`, or `save` are discouraged when direction already conveys meaning.

```nix
# ❌ BAD
{
  readFromTOML = path: ...;
}

# ✅ GOOD
{
  fromTOML = path: ...;
}
```

## Construction Resolves to the Defining Attrset

All construction and parsing logic resides on or near the attrset it produces. The primary "noun" being defined by a file should be the focus of its construction functions.

```nix
# In a file defining a `config` structure:

# ❌ BAD: Unrelated function in the global scope
# parse.nix
final: prev: {
  parseConfig = input: final.lib.importTOML input;
}

# ✅ GOOD: Construction function grouped with the related noun
# config.nix
{ lib, ... }:
{
  # ... config options and type definitions
  fromTOML = input: lib.importTOML input;
}
```

## Sema Object Rule — Single Attrset In, Single Attrset Out

*All values that cross module or file boundaries should be attrsets.* Primitive types (strings, bools) are for internal logic only.

Every reusable function should accept at most one argument: an attribute set. This makes the function's signature self-documenting, as the attribute keys act as named arguments. When multiple inputs or outputs are required, they must be fields within a single input or output attrset.

```nix
# ❌ BAD: Positional arguments are ambiguous at the call site.
# What is `100`? What is `0.08`? The order is implicit.
lib.calculatePrice = basePrice: taxRate: basePrice * (1 + taxRate);
finalPrice = lib.calculatePrice 100 0.08;


# ✅ GOOD: Attrset arguments are self-documenting at the call site.
# The meaning of each value is explicit.
lib.calculatePrice = { basePrice, taxRate }: basePrice * (1 + taxRate);
finalPrice = lib.calculatePrice { basePrice = 100; taxRate = 0.08; };
```

## Filesystem as Semantic Layer

Repository names, directory paths, and file boundaries are semantic layers. Inner layers assume outer context. Names never restate repository philosophy, lineage, or purpose.

```text
hello-world/
  pkgs/
    types/
    create/
      default.nix
```

## Documentation Protocol

All documentation is *impersonal, timeless, and precise*. All non-boilerplate behavior **must be made clear**. Clarity is achieved in one of two ways:

1.  **Self-Documenting Code:** The code is considered self-documenting if its purpose is made obvious through its structure and its strict adherence to the other guidelines (e.g., naming, data flow).

2.  **Comments:** If the code cannot be made self-documenting, its purpose and the *why* behind its logic **must be** explained in comments.

Boilerplate is not documented.

```nix
# Example 1: Self-documenting code requiring no comment.
# Adherence to other guidelines (clear names, simple structure) makes a comment redundant.
config.fromTOML = path: lib.trivial.importTOML (builtins.readFile path);


# Example 2: Code requiring a mandatory comment.
# The logic is simple, but the reason for the specific value is critical and not
# obvious from the code itself.
/*
  This timeout is set to 901 seconds.
  The upstream server has a 900-second timeout, but under load, it can
  take up to one extra second to close the connection. This value prevents
  a race condition that was causing intermittent failures.
*/
networking.timeout = 901;
```
