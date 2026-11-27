{
  config,
  horizon,
  lib,
  ...
}:

let
  policy = lib.findFirst (entry: entry.kind or null == "preferredWiredInternet") null (
    horizon.node.capabilities or [ ]
  );
  profileName = "criomos-preferred-wired";
  # The capability permits one preferred interface per host.
  profileUuid = "c90ba827-c1bb-4a1e-817f-26ea320ed08d";
  isIfname = name: builtins.match "[a-zA-Z0-9_.-]{1,15}" name != null;
  # A positive priority prefers this link for duplicate routing domains
  # without excluding a more-specific domain on Wi-Fi or a VPN.
  ipPolicy = {
    method = "auto";
    route-metric = 100;
    dns-priority = 90;
  };
in
lib.mkIf (policy != null) {
  assertions = [
    {
      assertion = config.networking.networkmanager.enable;
      message = "Preferred wired Internet requires NetworkManager on the client.";
    }
    {
      assertion = isIfname policy.interface;
      message = "Preferred wired Internet requires a valid interface name.";
    }
  ];

  networking.networkmanager.ensureProfiles.profiles.${profileName} = {
    connection = {
      id = profileName;
      uuid = profileUuid;
      type = "ethernet";
      interface-name = policy.interface;
      autoconnect = true;
      autoconnect-priority = 100;
    };
    ethernet = { };
    ipv4 = ipPolicy // {
      # Route unmatched DNS through the lease-provided DNS server while the
      # cable is connected. Existing more-specific DNS domains still win.
      dns-search = "~.;";
    };
    ipv6 = ipPolicy;
  };
}
