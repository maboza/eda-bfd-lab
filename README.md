# EDA BFD scale test

Deploy and tear down a large-scale BFD test on a Nokia EDA fabric, as one
command. Written against EDA 26.8.1 with simulated SR Linux 26.7.1 nodes.

Default shape: **1000 BFD sessions** between `leaf1` and `spine1`, spread 100 per
port across 10 VLAN-tagged ports, with **1-second timers** (tx/rx 1000 ms,
detection multiplier 3) and a `/31` per session carved from `10.10.0.0/21`.

```bash
./bfd.sh deploy                     # ports + sessions, then verify
./bfd.sh deploy --sessions-only     # just the session layer
./bfd.sh deploy --count 200 --ports 4
./bfd.sh teardown --sessions-only
./bfd.sh teardown                   # everything, including the ports
./bfd.sh verify
```

`generate-eda-bfd.sh` writes the manifests and a `session-map.csv` mapping every
session to its port, VLAN and addressing; `bfd.sh` calls it for you. Both are
parameterised — see `--help`.

Requires `kubectl` and `yq` (the EDA playground ships both in `tools/`; point
`PG_DIR` at your checkout if it lives elsewhere), and a reachable EDA cluster
whose nodes are `Synced`.

## Two layers

The deployment splits into two layers with different lifecycles, and keeping them
separate is what makes redeployment cheap:

- **ports** — 10 VLAN-tagged links `leaf1 <-> spine1` (`ethernet-1/13`–`1/22`) and
  their `Interface` resources, created by a `NetworkTopology` workflow.
  Slow-changing; normally only rebuilt after a cluster redeploy.
- **sessions** — 4002 labelled CRs. This is the layer you actually churn, and it
  cleans up entirely by label.

Use `--sessions-only` to cycle just the second layer.

## How BFD is modelled

EDA 26.8.1 has **no BFD CRD** — BFD is a property of other resources:

| Resource | Role |
|---|---|
| `DefaultRouter` (`routing/v1`) | one per node; needs only `node` + `routerID` |
| `DefaultInterface` (`routing/v1`) | VLAN subinterface, `/31`, and the BFD timers (**milliseconds**; SR Linux state reports microseconds) |
| `DefaultStaticRoute` (`protocols/v2`) | `nexthopGroup.nexthops[].bfd` — **required**, since BFD needs a consumer to bring the session up |

Do **not** use `Router` + `RoutedInterface` (`services/v2`) for this. They expose
the same `bfd` timer fields and look correct, but fail to reconcile with
`missing dependency of type SystemInterfaceState`: a services `Router` needs a
`SystemInterface`, which needs a `DefaultRouter` behind it anyway.

## Why this isn't just `kubectl apply -f`

Three traps, each of which fails **silently**:

1. **The topology manifest needs `kubectl create`, not `apply`.** The
   `NetworkTopology` workflow only fires on create; applying over an existing CR
   bumps its generation and does nothing at all.
2. **Every `kubectl` call needs `-n eda`.** Without it they hit the `default`
   namespace and no-op without error — which looks exactly like success.
3. **Tearing down ports needs a `NetworkTopology` with `operation: Delete`.**
   Deleting the `bfd-links` CR does *not* remove the links: `TopoLink`,
   `TopoNode` and `Interface` carry no `ownerReferences`. A label-based delete
   cleans up all 4002 session CRs but leaves the 10 links and 20 Interfaces
   behind.

## Verifying

There is no BFD CRD to inspect, so query node state directly:

```bash
kubectl -n eda-system exec deploy/eda-toolbox -- edactl -n eda query \
  '.namespace.node.srl.bfd.network-instance.peer where (.namespace.node.name = "leaf1")' -o json
```

Two gotchas: an **unfiltered** `edactl query` returns only the first node's rows,
so filter per node or you will undercount by half; and the table output's column
order is not stable between runs, so use `-o json` and key names rather than
column positions.

`./bfd.sh verify` wraps this and reports sessions UP per node, links up, resource
counts and alarms.

## Notes

Ports and sessions are created in dependency order — routers before sessions, or
the `DefaultInterface`s fail to reconcile on a missing `defaultRouter`.

`deploy` waits for sessions to be **UP**, not merely present: the config lands
well before the sessions establish, and with 1-second timers the last few take a
while. Checking the resource count alone reports success at roughly 90%.

Generated output (`out-bfd/`) is git-ignored — it is fully reproducible from
`generate-eda-bfd.sh`.
