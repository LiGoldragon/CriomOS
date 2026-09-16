# Prometheus TLS policy remote failure

The focused remote realization of the policy fixture at
`4cb93d6744f230b4754a0f0ad56653b0cbb67811` evaluated successfully and then
failed on the configured Prometheus Nix builder with exit code 1.

The rendered derivation identified the deterministic failure before any TLS
fixture command ran: eight dependency assertions rendered as `test 1 = true`.
Nix coerces booleans to `1` during shell interpolation, while the shell test
expects the literal string `true`. The fixture must pass each `builtins.elem`
result through its existing `bool` helper.

This is a test-fixture defect. The source implementation and production state
were not changed by the failed realization.
