{
  description = "Default placeholder system input. Override with `--override-input system path:<lojix-generated-system-dir>` to provide the actual target system tuple.";

  outputs = _: {
    system = throw ''
      CriomOS: no system input was provided.

      The `system` flake input is a stub by default. Provide a real
      one by overriding the input — typically via the `lojix`
      orchestrator tool, which derives the system tuple from
      `horizon.node.system` and writes a tiny content-addressed
      flake whose only output is `system = "x86_64-linux"` (or
      similar). The same content yields the same narHash, which lets
      the pkgs-flake's evaluation cache stay warm across deploys
      that target the same system.

      Ad-hoc form:
        mkdir /tmp/sys && cat > /tmp/sys/flake.nix <<EOF
          { outputs = _: { system = "x86_64-linux"; }; }
        EOF
        nix build .#nixosConfigurations.target.config.system.build.toplevel \
          --override-input system path:/tmp/sys \
          --override-input horizon path:<horizon-dir>
    '';
  };
}
