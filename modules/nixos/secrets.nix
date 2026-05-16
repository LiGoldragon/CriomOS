{
  config,
  inputs,
  horizon,
  ...
}:
let
  # The cluster's resolved binding table — projected from the
  # proposal's `secret_bindings: Vec<ClusterSecretBinding>` into a
  # lookup-shaped `secretBindings: { <name> = <SecretBackend>; }`.
  # `SecretBackend` renders through serde's externally-tagged form, so
  # each value here is one of:
  #
  #   { Sops              = { file        = "..."; key             = "..."; }; }
  #   { SystemdCredential = { credentialName = "..."; }; }
  #   { Agenix            = { secretId    = "..."; }; }
  #
  # The whole map is empty when the cluster authored no bindings.
  clusterSecretBindings = horizon.cluster.secretBindings or { };

  # Dispatch one `SecretReference` (`{ name, purpose }`) onto the
  # backend the cluster bound it to. Returns a resolution record the
  # consumer module reads — see the per-variant comments below for
  # the fields populated by each backend.
  #
  # Loud-fail discipline (per the workspace's beauty rules + the
  # `operator-friendly loud-fail` shape carried by every other
  # secret-touching module): the binding-missing case throws with an
  # operator hint that names exactly which `cluster.secret_bindings`
  # entry the datom is missing; the staged-file-missing case (Sops)
  # throws with a hint pointing at the cluster repo's `secrets/`
  # directory.
  resolveSecret =
    secretRef:
    let
      name = secretRef.name;
      backend =
        clusterSecretBindings.${name}
          or (throw "secrets: no cluster.secret_bindings entry for ${name} — author one in the cluster datom that names a SecretBackend (Sops | SystemdCredential | Agenix)");
    in
    if backend ? Sops then
      let
        sops = backend.Sops;
        sopsFiles = inputs.secrets.sopsFiles or { };
        sopsFile =
          sopsFiles.${name}
            or (throw "secrets: cluster bound ${name} to Sops { file = ${sops.file}; } but inputs.secrets.sopsFiles.${name} is missing — stage the encrypted file under the cluster repo's secrets/ and re-run the flake lock");
      in
      {
        # The kind tag the consumer dispatches on if it needs to.
        kind = "Sops";
        # The logical name — also the sops.secrets attribute key.
        inherit name;
        # Runtime path sops-install-secrets writes the decrypted value to.
        runtimePath = config.sops.secrets.${name}.path;
        # Inputs the consumer copies into a `sops.secrets.${name}`
        # declaration: the staged sopsFile reference, plus a passthrough
        # of the binding's metadata for any future per-backend wiring.
        sopsConfig = {
          inherit sopsFile;
          format = "binary";
        };
        # The cluster-authored sops paths surfaced for debug/audit.
        clusterAuthored = {
          file = sops.file;
          key = sops.key;
        };
      }
    else if backend ? SystemdCredential then
      let
        credentialName = backend.SystemdCredential.credentialName;
      in
      {
        kind = "SystemdCredential";
        inherit name credentialName;
        # The systemd service declares
        #   LoadCredential = "${credentialName}:<path-on-disk>"
        # and reads from $CREDENTIALS_DIRECTORY/${credentialName} at
        # runtime. The consumer's runtime read path is therefore the
        # canonical `%d/<credentialName>` form — exposed here so the
        # consumer doesn't reconstruct it.
        runtimePath = "%d/${credentialName}";
      }
    else if backend ? Agenix then
      throw "secrets: cluster bound ${name} to Agenix { secretId = ${backend.Agenix.secretId}; } but the Agenix backend is not yet implemented in this resolver — file an issue (or extend resolveSecret) when the first Agenix consumer arrives"
    else
      throw "secrets: cluster.secret_bindings entry for ${name} is shaped like none of the known SecretBackend variants (Sops, SystemdCredential, Agenix) — backend = ${builtins.toJSON backend}";
in
{
  imports = [
    inputs.sops-nix.nixosModules.sops
  ];

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  # Expose the resolver under the module's `_module.args` so every
  # consumer that imports `secrets.nix` (the network aggregator does;
  # router/default.nix does directly) can take `resolveSecret` as a
  # function argument without going through `config.<some-path>`.
  _module.args.resolveSecret = resolveSecret;
}
