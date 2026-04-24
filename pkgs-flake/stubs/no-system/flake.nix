{
  outputs = _: {
    system = throw "pkgs-flake invoked without a system input — it must be provided via `follows` from a parent flake.";
  };
}
