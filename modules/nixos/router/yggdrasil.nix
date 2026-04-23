{ lib, ... }:

{
  networking = {
    nftables = {
      tables.yggdrasil-local = {
        family = "ip6";
        content = ''
          chain input {
            type filter hook input priority -100;
            ip6 saddr fe80::/64 ip6 daddr fe80::/64 udp dport 9001 accept
            ip6 saddr fe80::/64 ip6 daddr fe80::/64 tcp dport 10001 accept
          }
        '';
      };
    };
  };
}
