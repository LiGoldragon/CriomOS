{ config, lib, horizon, ... }:
let
  policy = horizon.node.batteryPowerPolicy or null;
in
{
  config = lib.mkIf (policy != null) {
    assertions = [ {
      assertion = policy.action >= 0 && policy.low <= 100
        && policy.low > policy.critical && policy.critical > policy.action;
      message = "Battery power policy requires 0 <= action < critical < low <= 100.";
    } ];
    systemd.services.upower.restartTriggers = [ config.environment.etc."UPower/UPower.conf".source ];
    services.upower = {
      enable = true;
      usePercentageForPolicy = true;
      percentageLow = policy.low;
      percentageCritical = policy.critical;
      percentageAction = policy.action;
      criticalPowerAction = policy.criticalPowerAction;
    };
  };
}
