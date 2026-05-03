{ lib, horizon, ... }:
let
  inherit (horizon) node;
  archiveRoot = "/var/lib/lojix-inputs";
in
{
  config = lib.mkIf node.isNixCache {
    systemd.tmpfiles.rules = [
      "d ${archiveRoot} 0755 root root - -"
    ];

    services.nginx = {
      enable = true;
      virtualHosts."${node.criomeDomainName}" = {
        locations."/lojix-inputs/" = {
          alias = "${archiveRoot}/";
          extraConfig = ''
            autoindex off;
          '';
        };
      };
    };
  };
}
