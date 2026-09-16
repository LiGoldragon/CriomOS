# Prometheus service-provider VM bounded receipt

The policy check was evaluated and built remotely with Nix 2.34.7 against
nixpkgs `f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1` and sops-nix
`a8627b21b9107c5711c96b84f32a9a4b3d45295f`.

- `checks/prometheus-service-provider-policy` exited 0.
- The first remote-only VM build used `timeout 300`; it reached the closure
  download and construction phase and was stopped at its outer deadline.
- One retry used `timeout 600`, with the same remote-only Nix options:
  `--max-jobs 0 --no-link --option substituters https://cache.nixos.org/`
  and `--option connect-timeout 5`. It exited 124 with `shutting down` and
  `error: interrupted by the user`.

The second run constructed generated NixOS artifacts, including both systems'
activation closures, boot JSON, Forgejo service units, and the test-driver
closure. It did not start the NixOS VM driver or QEMU before the outer timeout.
There is therefore no KVM availability result and no runtime activation proof
from this receipt.

The source commit title says "Prove Prometheus service provider firewall and VM
activation" because it adds the proof test and policy assertions. It must not
be read as a completed VM-runtime proof: the test is defined and evaluates, but
the bounded remote execution did not reach it.
