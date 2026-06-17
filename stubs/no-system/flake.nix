{
  description = "Default placeholder system input. Provide the actual target system tuple through the deploy materialization tool.";

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

      Use the deploy materialization tool rather than hand-writing
      local path override commands.
    '';
  };
}
