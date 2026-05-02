{
  description = "Default deployment-shape input. Override with `--override-input deployment path:<lojix-generated-deployment-dir>` to request variants such as home-off system evaluation.";

  outputs = _: {
    deployment = {
      # Historical CriomOS behavior: the system generation embeds
      # Home Manager and exposes per-user activation packages.
      includeHome = true;
    };
  };
}
