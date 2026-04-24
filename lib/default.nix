_:

# criomos-lib — Sema-style namespace of helpers. Keep names flat. No
# type-suffixed names.
#
# Most magnitude / list helpers that used to live here are now derived
# fields on horizon-rs Node / User (horizon.node.size.atLeastMed etc.),
# so the library is intentionally small.

let
  inherit (builtins)
    fromJSON
    readFile
    toJSON
    ;
in
{

  # ─── JSON helpers ────────────────────────────────────────────────────

  importJSON = filePath: fromJSON (readFile filePath);

  # Deep-merge a nix-declared JSON object into a mutable settings file.
  # Nix-declared keys win; user-added keys are preserved.
  #
  # KNOWN LIMITATION: jq's `*` operator is a *shallow* merge — nested
  # objects get replaced wholesale. User edits inside nested keys
  # (e.g. VSCodium's `"[python]": { ... }`) are lost. Replacement is
  # tracked as CriomOS-bb5 (criomos-cfg side-repo with proper 3-way
  # merge + drift reporting).
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
}
