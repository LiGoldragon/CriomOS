with builtins;

rec {

  /*
    Produces a HM activation hook that deep-merges nixSettings into a mutable
    JSON file. Nix-declared keys always win; user-added keys are preserved.
    Requires lib and pkgs from the calling module.

    Usage:
      home.activation.mergeMySettings = mkJsonMerge {
        inherit lib pkgs;
        file = "$HOME/.config/App/settings.json";
        nixSettings = { "my.key" = true; };
      };
  */
  mkJsonMerge =
    { lib, pkgs, file, nixSettings }:
    let
      nixJson = toJSON nixSettings;
      jq = "${pkgs.jq}/bin/jq";
    in
    let
      nixJsonFile = pkgs.writeText "nix-settings.json" nixJson;
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

  callWith =
    lambda: closure:
    let
      requiredInputs = functionArgs lambda;
      inputs = intersectAttrs requiredInputs closure;
    in
    lambda inputs;

  highestOf = list: tail (sort lessThan list);

  importJSON = filePath: fromJSON (readFile filePath);

  lowestOf = list: head (sort lessThan list);

  matchSize =
    size: ifNon: ifMin: ifMed: ifMax:
    let
      sizedAtLeast = mkSizeAtLeast size;
    in
    if sizedAtLeast.max then
      ifMax
    else if sizedAtLeast.med then
      ifMed
    else if sizedAtLeast.min then
      ifMin
    else
      ifNon;

  mkSizeAtLeast = size: {
    min = size >= 1;
    med = size >= 2;
    max = size == 3;
  };

}
