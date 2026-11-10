{ lib, ... }:
{
  # How long a machine that suspends then hibernates on battery stays in
  # suspend before it hibernates.
  options.criomos.sleep.hibernateDelay = lib.mkOption {
    type = lib.types.str;
    default = "2h";
    description = "How long a suspend on battery lasts before the machine hibernates, as a systemd time span.";
  };
}
