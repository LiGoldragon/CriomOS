{ inputs, pkgs, ... }:
let
  agentIntercomPackage =
    inputs.criomos-home.packages.${pkgs.stdenv.hostPlatform.system}.agent-intercom;
in
{
  # Agent Intercom exports only distinct wrapper names. Its availability is
  # independent of Horizon node services; direct `codex` and `claude` remain
  # owned by their matching user profiles.
  environment.systemPackages = [ agentIntercomPackage ];
}
