{
  description = "Default placeholder horizon input. Provide a real projected horizon through the deploy materialization tool.";

  outputs = _: {
    horizon = throw ''
      CriomOS: no horizon input was provided.

      The `horizon` flake input is a stub by default. Provide a real
      one by overriding the input — typically via the `lojix`
      orchestrator tool, which projects a cluster proposal (in-process
      via horizon-lib, not as a CriomOS dependency) and writes a
      content-addressed horizon flake for the deploy evaluation.

      Use the deploy materialization tool rather than hand-writing
      local path override commands.
    '';
  };
}
