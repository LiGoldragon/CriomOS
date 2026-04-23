_:

# criomos-lib — Sema-style namespace of helpers. Ported from legacy
# `criomos-lib.nix`. Keep names flat. No type-suffixed names.

let
  inherit (builtins)
    fromJSON
    functionArgs
    head
    intersectAttrs
    readFile
    sort
    tail
    toJSON
    filterAttrs
    ;
in
rec {

  # List helpers.
  lowestOf = list: head (sort (a: b: a < b) list);
  highestOf = list: tail (sort (a: b: a < b) list);

  # JSON helpers.
  importJSON = filePath: fromJSON (readFile filePath);

  # Call a lambda with only the args it asks for, drawn from a closure.
  callWith =
    lambda: closure:
    let
      required = functionArgs lambda;
      present = intersectAttrs required closure;
    in
    lambda present;

  # Size ladder: 0 nothing / 1 min / 2 med / 3 max.
  mkSizeAtLeast = size: {
    min = size >= 1;
    med = size >= 2;
    max = size == 3;
  };

  matchSize =
    size: ifNon: ifMin: ifMed: ifMax:
    let
      s = mkSizeAtLeast size;
    in
    if s.max then ifMax
    else if s.med then ifMed
    else if s.min then ifMin
    else ifNon;

  # Deep-merge a nix-declared JSON object into a mutable settings file.
  # Nix-declared keys win; user-added keys are preserved.
  mkJsonMerge =
    { lib, pkgs, file, nixSettings }:
    let
      nixJsonFile = pkgs.writeText "nix-settings.json" (toJSON nixSettings);
      jq = "${pkgs.jq}/bin/jq";
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      target="${file}"
      mkdir -p "$(dirname "$target")"
      if [ -f "$target" ]; then
        ${jq} -s '.[0] * .[1]' "$target" ${nixJsonFile} > "$target.tmp"
        mv "$target.tmp" "$target"
      else
        cp ${nixJsonFile} "$target"
      fi
    '';

  # discoverClusters — any flake input whose outputs carry a `NodeProposal`
  # attr is treated as a cluster. CriomOS is network-neutral: it does
  # NOT enumerate clusters itself — they come from whatever the consumer
  # pinned in its flake.
  discoverClusters = inputs: filterAttrs (_: v: v ? NodeProposal) inputs;

  # mkHorizon — (cluster, node) → enriched horizon.
  #
  # Axis is (clusterName, nodeName), NEVER a hostName. Consuming sites pass
  # both explicitly; there is no flat host namespace in CriomOS.
  #
  # Final implementation calls `horizon-check` (Rust) via a derivation whose
  # output is the typed enriched horizon JSON, consumed via IFD. The pure-Nix
  # fallback (ported from legacy `mkHorizonModule.nix`) runs until then.
  #
  # Signature: { inputs, clusterName, nodeName } -> attrset
  #   { cluster, node, exNodes, users, methods }
  mkHorizon = _args: throw ''
    criomos-lib.mkHorizon: not yet implemented.

    Target: ingest inputs.<clusterName>.NodeProposal, validate, compute the
    method DAG documented in docs/HORIZON.md, return enriched horizon for
    (clusterName, nodeName).
  '';
}
