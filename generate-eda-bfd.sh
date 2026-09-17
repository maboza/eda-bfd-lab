#!/usr/bin/env bash
#
# generate-eda-bfd.sh - generate Nokia EDA manifests for N BFD sessions between
# two nodes, spread across a set of physical ports.
#
# Model (validated against EDA 26.8.1 / SR Linux 26.7.1 sim nodes):
#
#   NetworkTopology  - creates the inter-switch links and their Interface
#                      resources. encapType Dot1q is REQUIRED: without it the
#                      Interface comes out encapType "Null" and cannot carry
#                      VLAN subinterfaces.
#   DefaultRouter    - one per node (the "default" network-instance). Needs only
#                      node + routerID. Deliberately NOT the services.eda
#                      Router/RoutedInterface pair, which additionally requires
#                      a SystemInterface and a DefaultRouter behind it.
#   DefaultInterface - one per session per side: the VLAN subinterface, its /31,
#                      and the BFD timers (in MILLISECONDS; EDA converts to the
#                      microseconds SR Linux reports).
#   DefaultStaticRoute - one per session per side. BFD in SR Linux is not
#                      free-floating: something must consume it. The static
#                      route's next-hop-group with bfd.enabled is what actually
#                      brings the session up (state shows STATIC_ROUTE as the
#                      subscribed protocol). The prefix is just the peer's own
#                      address as a /32 - it needs to exist, not to be useful.
#
# Sessions are laid out as: session s -> port (FIRST_PORT + s / PER_PORT),
# VLAN (START_VLAN + s % PER_PORT), /31 #s carved from BASE_NET.
#
# Everything generated carries the label bfd-scale-test=true, so teardown is:
#   kubectl -n eda delete defaultinterfaces,defaultstaticroutes -l bfd-scale-test=true
#
# Usage:
#   ./generate-eda-bfd.sh [--count 1000] [--ports 10] [--outdir out-bfd]
#
# Apply order: 00-topology.yaml, then 01-routers.yaml, then 02-sessions-*.yaml.

set -euo pipefail

COUNT=1000
PORTS=10
FIRST_PORT=13
START_VLAN=1000
BASE_NET="10.10.0.0"          # /31s are carved sequentially from here
LOCAL_NODE="leaf1"
REMOTE_NODE="spine1"
LOCAL_RID="10.0.0.1"
REMOTE_RID="10.0.0.2"
TX_MS=1000
RX_MS=1000
MULTIPLIER=3
BATCH=100                      # sessions per manifest file
OUTDIR="out-bfd"
LABEL="bfd-scale-test"

while [ $# -gt 0 ]; do
    case "$1" in
        --count)       COUNT="$2"; shift ;;
        --ports)       PORTS="$2"; shift ;;
        --first-port)  FIRST_PORT="$2"; shift ;;
        --start-vlan)  START_VLAN="$2"; shift ;;
        --base-net)    BASE_NET="$2"; shift ;;
        --local-node)  LOCAL_NODE="$2"; shift ;;
        --remote-node) REMOTE_NODE="$2"; shift ;;
        --tx-ms)       TX_MS="$2"; shift ;;
        --rx-ms)       RX_MS="$2"; shift ;;
        --multiplier)  MULTIPLIER="$2"; shift ;;
        --batch)       BATCH="$2"; shift ;;
        --outdir)      OUTDIR="$2"; shift ;;
        -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

if [ $(( COUNT % PORTS )) -ne 0 ]; then
    echo "warning: --count $COUNT does not divide evenly by --ports $PORTS" >&2
fi
PER_PORT=$(( (COUNT + PORTS - 1) / PORTS ))

if [ "$PER_PORT" -gt 4094 ]; then
    echo "error: $PER_PORT sessions per port exceeds the 4094 VLAN limit" >&2
    exit 1
fi

# BASE_NET as an integer, so /31 #s is just base + 2*s.
IFS=. read -r b1 b2 b3 b4 <<EOF
$BASE_NET
EOF
BASE_INT=$(( (b1 << 24) + (b2 << 16) + (b3 << 8) + b4 ))

int2ip() {
    local i=$1
    echo "$(( (i >> 24) & 255 )).$(( (i >> 16) & 255 )).$(( (i >> 8) & 255 )).$(( i & 255 ))"
}

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/00-topology.yaml "$OUTDIR"/01-routers.yaml \
      "$OUTDIR"/02-sessions-*.yaml "$OUTDIR"/session-map.csv

# ------------------------------------------------------------- topology ------
{
    echo "# $PORTS VLAN-tagged links $LOCAL_NODE <-> $REMOTE_NODE for BFD scale testing."
    echo "# Additive (operation: Create) - the base topology is left untouched."
    echo "apiVersion: topologies.eda.nokia.com/v1"
    echo "kind: NetworkTopology"
    echo "metadata: {name: bfd-links, namespace: eda}"
    echo "spec:"
    echo "  operation: Create"
    echo "  links:"
    p=0
    while [ "$p" -lt "$PORTS" ]; do
        port=$(( FIRST_PORT + p ))
        echo "  - name: ${LOCAL_NODE}-${REMOTE_NODE}-bfd-${port}"
        echo "    encapType: Dot1q"
        echo "    labels: {eda.nokia.com/role: interSwitch}"
        echo "    endpoints:"
        echo "    - local: {node: ${LOCAL_NODE}, interface: ethernet-1-${port}}"
        echo "      remote: {node: ${REMOTE_NODE}, interface: ethernet-1-${port}}"
        echo "      type: InterSwitch"
        p=$(( p + 1 ))
    done
} > "$OUTDIR/00-topology.yaml"

# -------------------------------------------------------------- routers ------
{
    echo "apiVersion: routing.eda.nokia.com/v1"
    echo "kind: DefaultRouter"
    echo "metadata:"
    echo "  name: bfd-${LOCAL_NODE}"
    echo "  namespace: eda"
    echo "  labels: {${LABEL}: \"true\"}"
    echo "spec: {node: ${LOCAL_NODE}, routerID: ${LOCAL_RID}}"
    echo "---"
    echo "apiVersion: routing.eda.nokia.com/v1"
    echo "kind: DefaultRouter"
    echo "metadata:"
    echo "  name: bfd-${REMOTE_NODE}"
    echo "  namespace: eda"
    echo "  labels: {${LABEL}: \"true\"}"
    echo "spec: {node: ${REMOTE_NODE}, routerID: ${REMOTE_RID}}"
} > "$OUTDIR/01-routers.yaml"

# ------------------------------------------------------------- sessions ------
echo "session,port,vlan,subnet,${LOCAL_NODE}_ip,${REMOTE_NODE}_ip" > "$OUTDIR/session-map.csv"

emit_side() {
    # $1=side tag (l/r) $2=node $3=router $4=iface-resource $5=vlan
    # $6=local ip $7=peer ip $8=session index
    local tag=$1 node=$2 router=$3 iface=$4 vlan=$5 lip=$6 pip=$7 s=$8
    cat <<YAML
---
apiVersion: routing.eda.nokia.com/v1
kind: DefaultInterface
metadata:
  name: bfd-${tag}-${s}
  namespace: eda
  labels: {${LABEL}: "true"}
spec:
  defaultRouter: ${router}
  interface: ${iface}
  vlanID: ${vlan}
  subinterfaceIndex: ${vlan}
  ipv4Addresses:
  - ipPrefix: ${lip}/31
  bfd:
    enabled: true
    desiredMinTransmitIntMs: ${TX_MS}
    requiredMinReceiveIntMs: ${RX_MS}
    detectionMultiplier: ${MULTIPLIER}
---
apiVersion: protocols.eda.nokia.com/v2
kind: DefaultStaticRoute
metadata:
  name: bfd-sr-${tag}-${s}
  namespace: eda
  labels: {${LABEL}: "true"}
spec:
  defaultRouter: ${router}
  prefixes: [${pip}/32]
  nexthopGroup:
    nexthops:
    - ipPrefix: ${pip}
      bfd: {enabled: true, localAddress: ${lip}}
YAML
}

s=0
files=0
while [ "$s" -lt "$COUNT" ]; do
    batch_start=$s
    batch_end=$(( s + BATCH ))
    [ "$batch_end" -gt "$COUNT" ] && batch_end=$COUNT
    f=$(printf '%s/02-sessions-%03d.yaml' "$OUTDIR" "$files")

    {
        while [ "$s" -lt "$batch_end" ]; do
            port=$(( FIRST_PORT + s / PER_PORT ))
            vlan=$(( START_VLAN + s % PER_PORT ))
            lint=$(( BASE_INT + 2 * s ))
            rint=$(( lint + 1 ))
            lip=$(int2ip "$lint")
            rip=$(int2ip "$rint")

            emit_side "l1" "$LOCAL_NODE"  "bfd-${LOCAL_NODE}"  "${LOCAL_NODE}-ethernet-1-${port}"  "$vlan" "$lip" "$rip" "$s"
            emit_side "s1" "$REMOTE_NODE" "bfd-${REMOTE_NODE}" "${REMOTE_NODE}-ethernet-1-${port}" "$vlan" "$rip" "$lip" "$s"

            echo "$s,ethernet-1/$port,$vlan,$lip/31,$lip,$rip" >> "$OUTDIR/session-map.csv"
            s=$(( s + 1 ))
        done
    } > "$f"

    files=$(( files + 1 ))
done

cat <<EOF
generated in $OUTDIR/
  00-topology.yaml       $PORTS links ${LOCAL_NODE} <-> ${REMOTE_NODE} (ethernet-1/${FIRST_PORT}..1/$(( FIRST_PORT + PORTS - 1 ))), Dot1q
  01-routers.yaml        2 DefaultRouters
  02-sessions-*.yaml     $files files, $COUNT sessions, $BATCH per file
  session-map.csv        session -> port / vlan / addressing

  $COUNT sessions x $PER_PORT per port, VLANs ${START_VLAN}..$(( START_VLAN + PER_PORT - 1 )) on each port
  BFD ${TX_MS}ms tx / ${RX_MS}ms rx / multiplier ${MULTIPLIER}
  $(( COUNT * 4 + 2 )) custom resources total

apply:
  kubectl create -f $OUTDIR/00-topology.yaml     # create, not apply - the
                                                 # workflow only fires on create
  kubectl apply  -f $OUTDIR/01-routers.yaml
  for f in $OUTDIR/02-sessions-*.yaml; do kubectl apply -f "\$f"; done

verify:
  kubectl -n eda-system exec deploy/eda-toolbox -- \\
    edactl -n eda query .namespace.node.srl.bfd

teardown:
  kubectl -n eda delete defaultinterfaces,defaultstaticroutes,defaultrouters -l ${LABEL}=true
EOF
