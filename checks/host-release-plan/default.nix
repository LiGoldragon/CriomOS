{ hostReleasePlan, pkgs }:

pkgs.runCommand "host-release-plan-check" {
  nativeBuildInputs = [ hostReleasePlan pkgs.jq ];
} ''
  proposal="$PWD/horizon-definition.datom"
  cp ${./horizon-definition.datom} "$proposal"
  host-release-plan "$proposal" online All > all.json
  host-release-plan "$proposal" offline All > another-viewpoint.json
  diff -u all.json another-viewpoint.json
  jq -e '
    . == {
      cluster: "fixture",
      hosts: [
        {node: "offline", hostname: "offline.fixture.criome", disposition: "SkippedOffline"},
        {node: "online", hostname: "online.fixture.criome", disposition: "Ready"},
        {node: "unspecified", hostname: "unspecified.fixture.criome", disposition: "Ready"}
      ]
    }
  ' all.json

  host-release-plan "$proposal" online Explicit test-image offline installer > explicit.json
  jq -e '
    .hosts | map([.node, .disposition]) ==
      [["test-image", "Ready"], ["offline", "Ready"], ["installer", "Ready"]]
  ' explicit.json

  refuse() {
    if host-release-plan "$@" > result.json 2> failure; then
      echo "An invalid release selection succeeded." >&2
      exit 1
    fi
    test ! -s result.json
  }
  refuse "$proposal" online Explicit online unknown
  grep -F 'Unknown host: unknown' failure
  refuse "$proposal" online Explicit online online
  refuse "$proposal" online Explicit
  refuse "$proposal" online All offline
  refuse "$proposal" unknown All
  refuse horizon-definition.datom online All
  mkdir linked
  ln -s "$proposal" linked/horizon-definition.datom
  refuse "$PWD/linked/horizon-definition.datom" online All
  touch "$out"
''
