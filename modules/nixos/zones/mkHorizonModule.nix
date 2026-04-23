{
  lib,
  criomos-lib,
  config,
  clustersSpecies,
  Clusters,
  ...
}:
let
  inherit (builtins)
    filter
    concatStringsSep
    listToAttrs
    hasAttr
    attrNames
    concatMap
    elem
    ;
  inherit (lib)
    optionalAttrs
    optionalString
    unique
    ;

  inherit (criomos-lib) lowestOf mkSizeAtLeast;

  inherit (config) clusterName nodeName;
  inherit (clustersSpecies) nodeSpecies;

  inputCluster = Clusters.${clusterName};
  inputNodes = inputCluster.nodes;
  inputNode = inputNodes.${nodeName};

  nodeNames = attrNames inputCluster.nodes;
  userNames = attrNames inputCluster.users;

  archToSystemMap = {
    x86-64 = "x86_64-linux";
    arm64 = "aarch64-linux";
  };

  mkTrust = list: lowestOf (list ++ [ metaTrust ]);

  nodeCriomeDomainName = concatStringsSep "." [
    clusterName
    "criome"
  ];

  metaTrust = inputCluster.trust.cluster;

  mkSshString =
    preCriome:
    if (preCriome == null) then
      ""
    else
      concatStringsSep " " [
        "ssh-ed25519"
        preCriome
      ];

  mkNode =
    nodeName:
    let
      # (TODO typecheck)
      inputNode = inputNodes.${nodeName};
      inherit (inputNode) size species;
      inherit (inputNode.preCriomes) yggdrasil;

      speciesDatom =
        { datom, spec }:
        let
          inherit (datom) species;
          allSpecsNames = concatMap (n: lib.getAttr n spec) (attrNames spec);
          wantedAttrsNames = spec.${species};
          isNotWanted = n: !(elem n wantedAttrsNames);
          unwantedAttrs = filter isNotWanted allSpecsNames;
        in
        removeAttrs datom unwantedAttrs;

      filteredMachine = speciesDatom {
        datom = inputNode.machine;
        spec = {
          metal = [
            "arch"
            "motherBoard"
            "model"
          ];
          pod = [
            "arch"
            "superNode"
            "superUser"
          ];
        };
      };

      archFromMotherboard = mb: abort "Missing motherBoard table";

      checkedArch =
        if (filteredMachine.arch != null) then
          filteredMachine.arch
        else if (filteredMachine.species == "pod") then
          nodes.${filteredMachine.superNode}.machine.arch
        else if (filteredMachine.motherBoard != null) then
          (archFromMotherboard filteredMachine.motherBoard)
        else
          abort "Missing machine arch";

      machine = filteredMachine // {
        arch = checkedArch;
      };

      mkLinkLocalIP =
        linkLocalIP:
        with linkLocalIP;
        let
          # TODO
          interface = if (species == "ethernet") then "enp0s25" else "wlp3s0";
        in
        "fe80::${suffix}%${interface}";

      nodeIp = inputNode.nodeIp or null;
      wireguardPreCriome = inputNode.wireguardPreCriome or null;
      nordvpn = inputNode.nordvpn or false;
      wifiCert = inputNode.wifiCert or false;

      mkTypeIsFromTypeName =
        name:
        let
          isOfThisType = name == species;
        in
        lib.nameValuePair name isOfThisType;

      node = {
        inherit size species;

        name = nodeName;
        inherit machine wireguardPreCriome nordvpn wifiCert nodeIp;

        linkLocalIps =
          if (hasAttr "linkLocalIps" inputNode) then (map mkLinkLocalIP inputNode.linkLocalIps) else [ ];

        trust = mkTrust [
          inputNode.trust
          inputCluster.trust.nodes.${nodeName}
        ];

        ssh = mkSshString inputNode.preCriomes.ssh;

        yggPreCriome = yggdrasil.preCriome;
        yggAddress = yggdrasil.address;
        yggSubnet = yggdrasil.subnet;

        nixPreCriome =
          if inputNode.preCriomes.nixPreCriome != null && inputNode.preCriomes.nixPreCriome != ""
          then inputNode.preCriomes.nixPreCriome
          else inputNode.preCriomes.nixSigningPublicKey;

        criomeDomainName = concatStringsSep "." [
          nodeName
          nodeCriomeDomainName
        ];

        system = archToSystemMap.${machine.arch};

        nbOfBuildCores = 1; # TODO

        typeIs = listToAttrs (map mkTypeIsFromTypeName nodeSpecies);
      };

      methods =
        let
          inherit (node)
            trust
            size
            yggAddress
            criomeDomainName
            typeIs
            ;

        in
        rec {
          isFullyTrusted = trust == 3;
          sizedAtLeast = mkSizeAtLeast size;
          isBuilder =
            !typeIs.edge && isFullyTrusted && (sizedAtLeast.med || behavesAs.center) && hasBasePrecriads;
          isDispatcher = !behavesAs.center && isFullyTrusted && sizedAtLeast.min;
          isNixCache = behavesAs.center && sizedAtLeast.min && hasBasePrecriads;
          hasNixPreCriad = node.nixPreCriome != null && node.nixPreCriome != "";
          hasYggPrecriad = yggAddress != null && yggAddress != "";
          hasSshPrecriad = hasAttr "ssh" inputNode.preCriomes;
          hasWireguardPrecriad = wireguardPreCriome != null;
          hasNordvpnPrecriad = node.nordvpn;
          hasWifiCertPrecriad = node.wifiCert;

          hasBasePrecriads = hasNixPreCriad && hasYggPrecriad && hasSshPrecriad;

          sshPrecriome = if !hasSshPrecriad then "" else mkSshString inputNode.preCriomes.ssh;

          nixPreCriome = optionalString hasNixPreCriad (
            concatStringsSep ":" [
              criomeDomainName
              node.nixPreCriome
            ]
          );

          nixCacheDomain = if isNixCache then ("nix." + criomeDomainName) else null;
          nixUrl = if isNixCache then ("http://" + nixCacheDomain) else null;

          behavesAs = rec {
            largeAI = (typeIs.largeAI or false) || (typeIs."largeAI-router" or false);
            center = typeIs.center || largeAI;
            router = typeIs.hybrid || typeIs.router || typeIs."largeAI-router";
            edge = typeIs.edge || typeIs.hybrid || typeIs.edgeTesting;
            nextGen = typeIs.edgeTesting || typeIs.hybrid;
            lowPower = typeIs.edge || typeIs.edgeTesting;
            bareMetal = machine.species == "metal";
            virtualMachine = machine.species == "pod";
            iso = !virtualMachine && (inputNode.io.disks == { });
          };

          hasVideoOutput = behavesAs.edge;

        };

    in
    node // { inherit methods; };

  exNodeNames = attrNames exNodes;
  builders = filter (n: nodes.${n}.methods.isBuilder) exNodeNames;
  caches = filter (n: nodes.${n}.methods.isNixCache) exNodeNames;
  dispatchers = filter (n: nodes.${n}.methods.isDispatcher) exNodeNames;

  adminUserNames = filter (n: users.${n}.trust == 3) userNames;

  nodeMethods =
    let
      mkBuilder =
        n:
        let
          node = exNodes.${n};
        in
        {
          hostName = node.criomeDomainName;
          sshUser = "nixBuilder";
          sshKey = "/etc/ssh/ssh_host_ed25519_key";
          supportedFeatures = lib.optional (!node.typeIs.edge) "big-parallel";
          system = node.system;
          systems = lib.optional (node.system == "x86_64-linux") "i686-linux";
          maxJobs = node.nbOfBuildCores;
        };

      mkAdminUserPreCriomes =
        adminUserName:
        let
          adminUser = users.${adminUserName};
          preCriomeNodeNames = attrNames adminUser.preCriomes;
          isFullyTrustedNode = n: nodes.${n}.methods.isFullyTrusted;
          fullyTrustedPreCriomeNames = filter isFullyTrustedNode preCriomeNodeNames;
          getSshString =
            n:
            if (adminUser.preCriomes.${n}.ssh == null) then "" else (mkSshString adminUser.preCriomes.${n}.ssh);
        in
        map getSshString fullyTrustedPreCriomeNames;

      inherit (node.machine) model;
      thinkpadModels = [
        "ThinkPadX240"
        "ThinkPadX230"
        "ThinkPadT14Gen2Intel"
        "ThinkPadT14Gen5Intel"
      ];
      computerModels = thinkpadModels ++ [ "rpi3B" ];

      computerIsNotMap = listToAttrs (map (n: lib.nameValuePair n false) computerModels);

    in
    {
      builderConfigs = map mkBuilder builders;

      cacheURLs =
        let
          mkKacURL = n: exNodes.${n}.methods.nixUrl;
        in
        map mkKacURL caches;

      exNodesSshPreCriomes = map (n: exNodes.${n}.ssh) exNodeNames;

      dispatchersSshPreCriomes = map (n: exNodes.${n}.ssh) dispatchers;

      adminSshPreCriomes = unique (concatMap mkAdminUserPreCriomes adminUserNames);

      chipIsIntel = elem node.machine.arch [
        "x86-64"
        "i686"
      ]; # TODO

      modelIsThinkpad = elem node.machine.model thinkpadModels;

      useColemak = node.io.keyboard == "colemak";

      computerIs = computerIsNotMap // (optionalAttrs (model != null) { "${model}" = true; });

      wireguardUntrustedProxies = node.wireguardUntrustedProxies or [ ];
    };

  mkUser =
    userName:
    let
      inputUser = inputCluster.users.${userName};

      tcekPreCriome = nodeName: preCriome: hasAttr nodeName nodes;

      user = {
        name = userName;

        inherit (inputUser) style species keyboard;

        size = lowestOf [
          inputUser.size
          node.size
        ];

        trust = inputCluster.trust.users.${userName};

        preCriomes = lib.filterAttrs tcekPreCriome inputUser.preCriomes;

        githubId = if (inputUser.githubId == null) then userName else inputUser.githubId;

      };

      hasPreCriome = hasAttr node.name user.preCriomes;

      methods = {
        inherit hasPreCriome;

        sizedAtLeast = mkSizeAtLeast user.size;

        emailAddress = "${user.name}@${cluster.name}.criome.net";
        matrixID = "@${user.name}:${cluster.name}.criome.net";

        gitSigningKey = if hasPreCriome then ("&" + user.preCriomes.${node.name}.keygrip) else null;

        useColemak = user.keyboard == "colemak";
        useFastRepeat = inputUser.fastRepeat or true;

        isMultimediaDev = elem user.species [
          "multimedia"
          "unlimited"
        ];

        isCodeDev = elem user.species [
          "code"
          "unlimited"
        ];

        sshCriomes = lib.mapAttrsToList (n: pk: mkSshString pk.ssh) user.preCriomes;

      }
      // (lib.optionalAttrs hasPreCriome {
        ssh = mkSshString user.preCriomes.${node.name}.ssh;
      });

    in
    user // { inherit methods; };

  nodes = listToAttrs (
    map (y: lib.nameValuePair y.name y) (filter (x: x.trust != 0) (map (n: mkNode n) nodeNames))
  );

  cluster = {
    name = clusterName;

    methods = {
      trustedBuildPreCriomes = map (n: nodes.${n}.methods.nixPreCriome) nodeNames;
    };
  };

  exNodes = lib.filterAttrs (n: v: n != nodeName) nodes;

  node =
    let
      node = nodes.${nodeName};
    in
    node
    // {
      inherit (inputNode) io;
      methods = node.methods // nodeMethods;
    };

  users = listToAttrs (
    map (y: lib.nameValuePair y.name y) (filter (x: x.trust != 0) (map (n: mkUser n) userNames))
  );

in
{
  horizon = {
    inherit
      cluster
      node
      exNodes
      users
      ;
  };
}
