{ inputs, pkgs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  fixtureInputs = inputs // {
    secrets = {
      sopsFiles = {
        prometheusServiceTls = ../../fixtures/prometheus-service-provider-evaluation-only.sops.yaml;
      };
    };
  };

  configurationFor =
    providerConfiguration: configurationInputs:
    lib.nixosSystem {
      inherit system;
      specialArgs = { inputs = configurationInputs; };
      modules = [
        inputs.sops-nix.nixosModules.sops
        ../../modules/nixos/prometheus-service-provider.nix
        {
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/disk/by-label/fixture-root";
            fsType = "ext4";
          };
          boot.loader.grub.devices = [ "/dev/sda" ];
          # Evaluation-only key path: no key is created or read by this check.
          sops.age.keyFile = "/run/keys/prometheus-service-provider-evaluation-only.age";
          criomos.prometheusServiceProvider = providerConfiguration;
        }
      ];
    };

  disabled = (configurationFor { } inputs).config;
  enabled =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls = {
        certificatePath = "/run/secrets/prometheus-service-certificate";
        keyPath = "/run/secrets/prometheus-service-key";
      };
      reviewRunner.enable = true;
    } inputs).config;

  sopsEnabled =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls.sopsFileKey = "prometheusServiceTls";
    } fixtureInputs).config;

  # Force the enabled host toplevel derivation so NixOS module assertions are
  # evaluated, then retain only a boolean. This avoids putting its drvPath
  # string (and the full host closure it carries) in this focused fixture.
  disabledToplevelEvaluated = builtins.deepSeq disabled.system.build.toplevel.drvPath true;
  enabledToplevelEvaluated = builtins.deepSeq enabled.system.build.toplevel.drvPath true;
  sopsToplevelEvaluated = builtins.deepSeq sopsEnabled.system.build.toplevel.drvPath true;

  missingTls =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
    } inputs).config;

  missingKey =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls.certificatePath = "/run/secrets/prometheus-service-certificate";
    } inputs).config;

  missingSops =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls.sopsFileKey = "prometheusServiceTls";
    } (inputs // { secrets = { sopsFiles = { }; }; })).config;

  conflictingTls =
    (configurationFor {
      enable = true;
      xmppDomain = "chat.example";
      forgejoDomain = "git.example";
      tls = {
        sopsFileKey = "prometheusServiceTls";
        certificatePath = "/run/secrets/explicit-certificate";
        keyPath = "/run/secrets/explicit-key";
      };
    } fixtureInputs).config;

  selfSignedToplevelEvaluated = builtins.deepSeq missingTls.system.build.toplevel.drvPath true;
  missingSopsToplevelRefused = !(builtins.tryEval missingSops.system.build.toplevel.drvPath).success;
  conflictingTlsToplevelRefused = !(builtins.tryEval conflictingTls.system.build.toplevel.drvPath).success;

  bool = value: if value then "true" else "false";
  hasFailedAssertion =
    message: configuration:
    builtins.any (
      assertion: !assertion.assertion && assertion.message == message
    ) configuration.assertions;
in
pkgs.runCommand "prometheus-service-provider-policy" {
  nativeBuildInputs = [
    pkgs.coreutils
    pkgs.openssl
  ];
} ''
  set -eu

  test ${lib.escapeShellArg (bool disabled.services.prosody.enable)} = false
  test ${lib.escapeShellArg (bool disabled.services.forgejo.enable)} = false
  test ${lib.escapeShellArg (bool (builtins.elem 5222 disabled.networking.firewall.allowedTCPPorts))} = false
  test ${lib.escapeShellArg (bool (builtins.elem 3000 disabled.networking.firewall.allowedTCPPorts))} = false
  test ${lib.escapeShellArg (bool (builtins.hasAttr "prometheus-nix-review" disabled.systemd.services))} = false
  test ${lib.escapeShellArg (bool (hasFailedAssertion "criomos.prometheusServiceProvider.tls requires deployment-owned runtime TLS paths, sopsFileKey, or generateSelfSigned" missingTls))} = false
  test ${lib.escapeShellArg (bool (hasFailedAssertion "criomos.prometheusServiceProvider.tls requires both certificatePath and keyPath" missingKey))} = true
  test ${lib.escapeShellArg (bool (hasFailedAssertion "criomos.prometheusServiceProvider.tls.sopsFileKey is missing from inputs.secrets.sopsFiles" missingSops))} = true
  test ${lib.escapeShellArg (bool (hasFailedAssertion "criomos.prometheusServiceProvider.tls.sopsFileKey conflicts with explicit certificatePath or keyPath" conflictingTls))} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.enable)} = true
  test ${lib.escapeShellArg (bool missingTls.systemd.services.prometheus-service-tls.enable)} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prosody.service" missingTls.systemd.services.prometheus-service-tls.before))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "forgejo.service" missingTls.systemd.services.prometheus-service-tls.before))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prosody.service" missingTls.systemd.services.prometheus-service-tls.requiredBy))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "forgejo.service" missingTls.systemd.services.prometheus-service-tls.requiredBy))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prometheus-service-tls.service" missingTls.systemd.services.prosody.requires))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prometheus-service-tls.service" missingTls.systemd.services.prosody.after))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prometheus-service-tls.service" missingTls.systemd.services.forgejo.requires))} = true
  test ${lib.escapeShellArg (bool (builtins.elem "prometheus-service-tls.service" missingTls.systemd.services.forgejo.after))} = true
  printf '%s\n' ${lib.escapeShellArg missingTls.systemd.services.prometheus-service-tls.script} | grep -F -- 'systemctl --no-block try-reload-or-restart prosody.service forgejo.service' 
  test ${
    lib.escapeShellArg missingTls.services.prosody.virtualHosts."chat.example".ssl.cert
  } = /var/lib/prometheus-service-tls/current/certificate.pem
  test ${lib.escapeShellArg missingTls.services.forgejo.settings.server.KEY_FILE} = /var/lib/prometheus-service-tls/current/key.pem
  test ${lib.escapeShellArg (bool enabled.services.prosody.allowRegistration)} = false
  test ${lib.escapeShellArg (bool enabled.services.prosody.c2sRequireEncryption)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.s2sRequireEncryption)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.modules.pep)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.modules.mam)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.modules.carbons)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.modules.smacks)} = true
  test ${lib.escapeShellArg (bool enabled.services.prosody.xmppComplianceSuite)} = false
  test ${lib.escapeShellArg (bool disabledToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool enabledToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool selfSignedToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool sopsToplevelEvaluated)} = true
  test ${lib.escapeShellArg (bool missingSopsToplevelRefused)} = true
  test ${lib.escapeShellArg (bool conflictingTlsToplevelRefused)} = true
  test ${lib.escapeShellArg sopsEnabled.services.prosody.virtualHosts."chat.example".ssl.cert} = /run/secrets/prometheus-service-certificate
  test ${lib.escapeShellArg sopsEnabled.services.forgejo.settings.server.KEY_FILE} = /run/secrets/prometheus-service-key
  test ${lib.escapeShellArg sopsEnabled.sops.secrets.prometheus-service-certificate.sopsFile} = ${lib.escapeShellArg fixtureInputs.secrets.sopsFiles.prometheusServiceTls}
  test ${lib.escapeShellArg sopsEnabled.sops.secrets.prometheus-service-key.key} = key
  test ${lib.escapeShellArg sopsEnabled.sops.secrets.prometheus-service-certificate.mode} = 0440
  test ${lib.escapeShellArg sopsEnabled.sops.secrets.prometheus-service-key.group} = prometheus-service-tls
  test ${
    lib.escapeShellArg (bool enabled.services.prosody.virtualHosts."chat.example".enabled)
  } = true
  test ${
    lib.escapeShellArg enabled.services.prosody.virtualHosts."chat.example".ssl.cert
  } = /run/secrets/prometheus-service-certificate
  test ${
    lib.escapeShellArg enabled.services.prosody.virtualHosts."chat.example".ssl.key
  } = /run/secrets/prometheus-service-key
  test ${lib.escapeShellArg (bool enabled.services.forgejo.enable)} = true
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.DOMAIN} = git.example
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.PROTOCOL} = https
  test ${lib.escapeShellArg (toString enabled.services.forgejo.settings.server.HTTP_PORT)} = 3000
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.ROOT_URL} = https://git.example:3000/
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.CERT_FILE} = /run/secrets/prometheus-service-certificate
  test ${lib.escapeShellArg enabled.services.forgejo.settings.server.KEY_FILE} = /run/secrets/prometheus-service-key
  test ${lib.escapeShellArg (bool enabled.services.forgejo.settings.service.DISABLE_REGISTRATION)} = true
  test ${lib.escapeShellArg (bool enabled.services.forgejo.settings.actions.ENABLED)} = false
  test ${lib.escapeShellArg (bool (builtins.elem 5222 enabled.networking.firewall.allowedTCPPorts))} = true
  test ${lib.escapeShellArg (bool (builtins.elem 3000 enabled.networking.firewall.allowedTCPPorts))} = true
  test ${lib.escapeShellArg enabled.systemd.services.prometheus-nix-review.serviceConfig.Type} = oneshot
  test ${lib.escapeShellArg enabled.systemd.services.prometheus-nix-review.serviceConfig.TimeoutStartSec} = 15min
  test ${lib.escapeShellArg enabled.systemd.services.prometheus-nix-review.serviceConfig.KillMode} = control-group
  printf '%s\n' ${lib.escapeShellArg enabled.systemd.services.prometheus-nix-review.serviceConfig.ExecStart} | grep -F -- 'github:LiGoldragon/CriomOS 7ee784103dac929bda499875a98504fd15ca6523'

  fixture="$TMPDIR/tls fixture"
  certificate="$fixture/current/certificate.pem"
  key="$fixture/current/key.pem"
  mkdir -p "$fixture/bin"
  cat > "$fixture/bin/chown" <<'SCRIPT'
  # Nix builders cannot change ownership. The fixture checks the requested
  # ownership while the real unit runs as root.
  test "$1" = root:prometheus-service-tls
  shift
  test "$#" -ge 1
  SCRIPT
  chmod +x "$fixture/bin/chown"
  PATH="$fixture/bin:$PATH"

  bash ${../../modules/nixos/prometheus-service-tls.sh} "$certificate" "$key" chat.example git.example
  test -s "$certificate"
  test -s "$key"
  test "$(stat -c %a "$certificate")" = 640
  test "$(stat -c %a "$key")" = 640
  openssl x509 -in "$certificate" -noout -ext subjectAltName | grep -F -- 'DNS:chat.example, DNS:git.example'
  test -L "$fixture/current"
  test "$(stat -c %a "$fixture/releases")" = 750
  test "$(stat -c %a "$(readlink -f "$fixture/current")")" = 750
  cp "$certificate" "$fixture/first-certificate.pem"
  cp "$key" "$fixture/first-key.pem"
  bash ${../../modules/nixos/prometheus-service-tls.sh} "$certificate" "$key" chat.example git.example
  cmp "$certificate" "$fixture/first-certificate.pem"
  cmp "$key" "$fixture/first-key.pem"

  old_current=$(readlink "$fixture/current")
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$key" -out "$certificate" \
    -subj /CN=chat.example \
    -addext 'subjectAltName=DNS:chat.example,DNS:git.example' >/dev/null 2>&1
  bash ${../../modules/nixos/prometheus-service-tls.sh} "$certificate" "$key" chat.example git.example
  test "$(readlink "$fixture/current")" != "$old_current"
  openssl x509 -in "$certificate" -noout -checkend 604800
  renewed_current=$(readlink "$fixture/current")
  if bash ${../../modules/nixos/prometheus-service-tls.sh} "$certificate" "$key" 'chat.example;touch-owned' git.example; then
    exit 1
  fi
  test "$(readlink "$fixture/current")" = "$renewed_current"

  if bash ${../../modules/nixos/prometheus-service-tls.sh} "$fixture/invalid-certificate.pem" "$fixture/invalid-key.pem" 'chat.example;touch-owned' git.example; then
    exit 1
  fi
  test ! -e "$fixture/invalid-certificate.pem"
  test ! -e "$fixture/invalid-key.pem"
  touch "$fixture/partial-certificate.pem"
  if bash ${../../modules/nixos/prometheus-service-tls.sh} "$fixture/partial-certificate.pem" "$fixture/partial-key.pem" chat.example git.example; then
    exit 1
  fi
  test ! -e "$fixture/partial-key.pem"
  touch "$out"
''
