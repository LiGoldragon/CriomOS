{
  # Periodic maintenance is operator-invoked.  Keep the underlying programs
  # and boot-time setup available while preventing module and package defaults
  # from installing schedules on any host variant.
  nix = {
    gc.automatic = false;
    optimise.automatic = false;
  };

  services = {
    cron.enable = false;
    fstrim.enable = false;
    locate.enable = false;
    logrotate.enable = false;
  };

  systemd = {
    timers = {
      fwupd-refresh.enable = false;
      nm-cloud-setup.enable = false;
      systemd-tmpfiles-clean.enable = false;
      xfs_scrub_all.enable = false;
    };

    # Leave systemd.user.tmpfiles.enable at its default so login-time setup is
    # retained; only its daily cleanup timer is masked.
    user.timers.systemd-tmpfiles-clean.enable = false;
  };
}
