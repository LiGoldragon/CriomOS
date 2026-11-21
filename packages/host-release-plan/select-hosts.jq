def host($disposition):
  {node: .name, hostname: .criomeDomainName, disposition: $disposition};

def persistent:
  .isLive == false and .behavesAs.testVm == false;

def all_hosts:
  map(select(persistent) |
    host(if .online == false then "SkippedOffline" else "Ready" end));

def explicit_hosts($names):
  INDEX(.[]; .name) as $by_name
  | if ($names | length) != ($names | unique | length) then
      error("Name each explicit host once.")
    else
      [$names[] as $name | $by_name[$name] |
        if . == null then error("Unknown host: \($name)") else host("Ready") end]
    end;

{
  cluster,
  hosts: ([.node, .exNodes[]] | sort_by(.name) |
    if $selection == "All" then all_hosts else explicit_hosts($ARGS.positional) end)
}
