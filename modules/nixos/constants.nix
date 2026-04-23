let
  systemd = rec {
    stateDirectory = "/var/lib";
    runtimeDirectory = "/run";
    dynamicUserStateDirectory = stateDirectory + "/private";
    dynamicUserRuntimeDirectory = runtimeDirectory + "/private";
  };

in
{
  fileSystem = {
    nix = {
      stateDirectory = "/etc/nix";
      preCriad = "/etc/nix/preCriad";
    };

    inherit systemd;

    yggdrasil = rec {
      subDirName = "yggdrasil";
      stateDirectory = systemd.dynamicUserStateDirectory + "/" + subDirName;

      runtimeDirectory = systemd.runtimeDirectory + "/" + subDirName;

      preCriomeJson = runtimeDirectory + "/preCriome.json";
      preCriadJson = stateDirectory + "/preCriad.json";
      combinedConfigJson = stateDirectory + "/combinedConfig.json";

      interfaceName = "yggTun";
    };
    nordvpn = {
      privateKeyFile = "/etc/nordvpn/privateKey";
    };

    complex = {
      dir = "/etc/criomOS/complex";
      keyFile = "/etc/criomOS/complex/key.pem";
      sshPubFile = "/etc/criomOS/complex/ssh.pub";
    };

    wifiPki = {
      caCertFile = "/etc/criomOS/wifi-pki/ca.pem";
      certsDir = "/etc/criomOS/wifi-pki";
      serverDir = "/etc/criomOS/wifi-server";
      serverCertFile = "/etc/criomOS/wifi-server/server.pem";
      serverKeyFile = "/etc/criomOS/wifi-server/server.key";
    };

    screenshots = "Pictures/Screenshots";
  };

  network = {
    ula48Suffix = {
      wifi = rec {
        subnet = ":1000:1000";
        address = subnet + ":1000::";
        radvdPrefix = subnet + "::/64";
      };
    };

    yggdrasil = rec {
      subnet = "200::";
      prefix = 7;
      namespace = subnet + "/" + (toString prefix);
      ports = {
        multicast = 9001;
        linkLocalTCP = 10001;
      };
    };

    lan = {
      subnetPrefix = "10.18.0";
      gateway = "10.18.0.1";
      subnet = "10.18.0.0/24";
    };

    nat64 = {
      pool = rec {
        subnet = "64:ff9b::";
        prefix = 96;
        full = subnet + "/" + (toString prefix);
      };
    };

    nix = {
      serve = {
        ports = {
          external = 5000;
          internal = 4999;
        };
      };

      store = {
        http = {
          ports.external = 8000;
        };
      };
    };

  };

}
