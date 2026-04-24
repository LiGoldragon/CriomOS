{
  description = "Default placeholder horizon input. Override with `--override-input horizon path:<lojix-generated-dir>` (or via the wrapper flake lojix prepares) to provide a real projected horizon.";

  outputs = _: {
    horizon = throw ''
      CriomOS: no horizon input was provided.

      The `horizon` flake input is a stub by default. Provide a real
      one by overriding the input — typically via the `lojix`
      orchestrator tool, which projects a cluster proposal (in-process
      via horizon-lib, not as a CriomOS dependency) and writes a
      content-addressed horizon flake whose path it passes as
      `--override-input horizon path:...`.

      For ad-hoc testing:
        horizon-cli --cluster X --node Y < datom.nota > /tmp/h/horizon.json
        cat > /tmp/h/flake.nix <<EOF
          { outputs = _: { horizon = builtins.fromJSON (builtins.readFile ./horizon.json); }; }
        EOF
        nix build .#nixosConfigurations.target.config.system.build.toplevel \
          --override-input horizon path:/tmp/h
    '';
  };
}
