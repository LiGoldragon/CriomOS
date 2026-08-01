## Shared-input pin discipline

When bumping a component pin (lojix, orchestrate, spirit, or any shared input)
in either CriomOS or CriomOS-home, check the other flake's pin for the same
input and bump it to match. The authoritative version is whichever flake was
intentionally updated; the other must follow within the same commit sequence.

When CriomOS-home is consumed as a module, CriomOS's follows overrides
deduplicate shared inputs. This discipline applies to standalone CriomOS-home
evaluations (home-manager switch without a system rebuild).
