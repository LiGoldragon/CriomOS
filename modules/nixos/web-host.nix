{
  lib,
  pkgs,
  inputs,
  horizon,
  ...
}:
let
  inherit (builtins) hasAttr head;
  inherit (lib)
    hasPrefix
    listToAttrs
    mkIf
    removePrefix
    replaceStrings
    ;

  nodeServices = import ./node-services.nix { inherit lib; };

  webHost = nodeServices.payload (horizon.node.services or [ ]) "WebHost";
  sites = webHost.sites or [ ];
  enabled = sites != [ ];

  sourcePath =
    site:
    let
      source = site.source or (throw "WebHost site is missing source");
      inputName = removePrefix "flake-input:" source;
    in
    if hasPrefix "flake-input:" source then
      if hasAttr inputName inputs then
        inputs.${inputName}
      else
        throw "WebHost site source ${source} names a flake input that is not available"
    else
      throw "WebHost site source ${source} is unsupported; use flake-input:<name> for reproducible build-time rendering";

  siteName = site: replaceStrings [ "." ":" "/" ] [ "-" "-" "-" ] site.domain;

  siteArtifact =
    site:
    let
      source = sourcePath site;
      renderer = site.renderer or "MarkdownStatic";
    in
    if renderer == "MarkdownStatic" then
      pkgs.runCommand "web-host-${siteName site}" { nativeBuildInputs = [ pkgs.zola ]; } ''
        set -eu
        cp -R ${source}/. source
        chmod -R u+w source
        export HOME="$TMPDIR"
        zola --root source build --output-dir "$out"
      ''
    else
      throw "WebHost renderer ${renderer} is unsupported by CriomOS";

  primaryDomain = (head sites).domain;

  virtualHosts = listToAttrs (
    map (site: {
      name = site.domain;
      value = {
        root = siteArtifact site;
        forceSSL = true;
        enableACME = true;
        extraConfig = ''
          add_header X-Content-Type-Options nosniff always;
          add_header Referrer-Policy no-referrer always;
          add_header X-Frame-Options DENY always;
        '';
      };
    }) sites
  );
in
mkIf enabled {
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@${primaryDomain}";
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;
    serverTokens = false;
    virtualHosts = virtualHosts;
  };
}
