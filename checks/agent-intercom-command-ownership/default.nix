{ inputs, pkgs, target }:
let
  system = pkgs.stdenv.hostPlatform.system;
  agentIntercom = inputs.criomos-home.packages.${system}.agent-intercom;
  userProfiles = pkgs.lib.mapAttrs (
    userName: userConfiguration:
    pkgs.buildEnv {
      name = "complete-host-${userName}-command-profile";
      paths = userConfiguration.home.packages;
    }
  ) target.config.home-manager.users;
  profilePaths = pkgs.lib.attrValues userProfiles;
in
assert builtins.elem agentIntercom target.config.environment.systemPackages;
pkgs.runCommand "complete-host-agent-intercom-command-ownership"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      agentIntercom
    ] ++ profilePaths;
  }
  ''
    set -eu

    # Agent Intercom must reserve the ordinary CLI names for direct packages.
    ! test -e ${agentIntercom}/bin/codex
    ! test -e ${agentIntercom}/bin/claude
    test -x ${agentIntercom}/bin/coi
    test -x ${agentIntercom}/bin/cci

    for profile in ${pkgs.lib.concatStringsSep " " (map toString profilePaths)}; do
      codex_version="$($profile/bin/codex --version)"
      printf '%s\n' "$codex_version" | grep -F 'codex-cli '
      ! printf '%s\n' "$codex_version" | grep -F '[agent-intercom-build]'
      claude_version="$($profile/bin/claude --version)"
      printf '%s\n' "$claude_version" | grep -F 'Claude Code'
      ! printf '%s\n' "$claude_version" | grep -F 'ERR_MODULE_NOT_FOUND'
      test -x "$profile/bin/coi"
      test -x "$profile/bin/cci"
    done

    touch "$out"
  ''
