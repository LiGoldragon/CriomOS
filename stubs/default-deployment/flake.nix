{
  description = "Default deployment-shape input. Provide deployment variants such as home-off system evaluation through the deploy materialization tool.";

  outputs = _: {
    deployment = {
      # Historical CriomOS behavior: the system generation embeds
      # Home Manager and exposes per-user activation packages.
      includeHome = true;

      # Normal hardware deployments keep NixOS' broad firmware set.
      # Synthetic deployment inputs can set this false and rely only on
      # model-specific firmware.
      includeAllFirmware = true;
    };
  };
}
