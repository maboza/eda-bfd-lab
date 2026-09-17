#!/usr/bin/env bash
#
# bfd.sh - deploy / tear down the EDA BFD scale test as one command.
#
# The deployment is two layers with different lifecycles, and they are worth
# keeping separate:
#
#   ports    10 VLAN-tagged links leaf1 <-> spine1 plus their Interface
#            resources, created by a NetworkTopology workflow. Slow-changing;
#            normally only rebuilt after a cluster redeploy.
#   sessions 4002 labelled CRs (DefaultRouter / DefaultInterface /
#            DefaultStaticRoute). This is the layer you actually churn.
#
# Use --sessions-only to cycle just the second layer, which is fast and cleans
# up entirely by label.
#
# Three things here are not obvious and are why this exists rather than a
# folder of YAML you kubectl apply:
#
#   1. The topology manifest must be `kubectl create`, not `apply`. The
#      NetworkTopology workflow only fires on create - applying over an
#      existing CR bumps its generation and silently does nothing.
#   2. Every kubectl call needs -n eda. Without it they hit the default
#      namespace and no-op without error, which looks exactly like success.
#   3. Tearing the ports down needs a NetworkTopology with operation: Delete.
#      Deleting the bfd-links CR does NOT remove the links - TopoLink,
#      TopoNode and Interface carry no ownerReferences.
#
# Usage:
#   ./bfd.sh deploy   [--sessions-only] [--count N] [--ports N]
#   ./bfd.sh teardown [--sessions-only]
#   ./bfd.sh verify
#   ./bfd.sh status
#
# From Windows, if the lab runs in a WSL distro:
#   wsl -d <distro> -e bash "/mnt/c/path/to/repo/bfd.sh" deploy

set -euo pipefail

EDA_NS="${EDA_NS:-eda}"
PG_DIR="${PG_DIR:-$HOME/playground}"
OUTDIR="${OUTDIR:-out-bfd}"
LABEL="${LABEL:-bfd-scale-test}"
TOPO_CR="${TOPO_CR:-bfd-links}"
COUNT="${COUNT:-1000}"
PORTS="${PORTS:-10}"
SESSION_TIMEOUT="${SESSION_TIMEOUT:-900}"

SESSIONS_ONLY=0
CMD="${1:-}"
[ $# -gt 0 ] && shift

while [ $# -gt 0 ]; do
    case "$1" in
        --sessions-only) SESSIONS_ONLY=1 ;;
        --count)         COUNT="$2"; shift ;;
        --ports)         PORTS="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------- utilities --
c_ok=''; c_warn=''; c_err=''; c_off=''
if [ -t 1 ]; then
    c_ok=$(printf '\033[32m'); c_warn=$(printf '\033[33m')
    c_err=$(printf '\033[31m'); c_off=$(printf '\033[0m')
fi
log()  { printf '%s==>%s %s\n' "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_err"  "$c_off" "$*" >&2; exit 1; }

cd "$(dirname "$0")"
[ -x "$PG_DIR/tools/kubectl" ] && export PATH="$PG_DIR/tools:$PATH"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found (set PG_DIR)"
command -v yq      >/dev/null 2>&1 || die "yq not found (set PG_DIR)"
kubectl version --request-timeout=10s >/dev/null 2>&1 \
    || die "cannot reach the Kubernetes API - is the kind cluster up?"

k() { kubectl -n "$EDA_NS" "$@"; }

# Both of these must emit exactly one number. Note `grep -c` prints "0" AND
# exits 1 when nothing matches, so a trailing `|| echo 0` would emit "0\n0" -
# capture into a variable and default it instead.
bfd_sessions() {   # $1 = node
    local n
    n="$(kubectl -n eda-system exec deploy/eda-toolbox -- edactl -n "$EDA_NS" query \
          ".namespace.node.srl.bfd.network-instance.peer where (.namespace.node.name = \"$1\")" \
          -o json 2>/dev/null | yq -p json -o json '. | length' 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}
bfd_up() {         # $1 = node
    local n
    n="$(kubectl -n eda-system exec deploy/eda-toolbox -- edactl -n "$EDA_NS" query \
          ".namespace.node.srl.bfd.network-instance.peer where (.namespace.node.name = \"$1\")" \
          -o json 2>/dev/null \
          | yq -p json -o json -r '.[] | ."session-state"' 2>/dev/null \
          | grep -c '^UP$' || true)"
    printf '%s' "${n:-0}"
}
# pipefail makes a mid-pipeline `grep` with no matches fail the whole pipeline,
# which under set -e kills the script - and at the first poll there are
# legitimately no bfd- links yet. Capture and default, like the helpers above.
topolinks_up() {
    local n
    n="$(k get topolinks --no-headers 2>/dev/null \
          | grep 'bfd-' | awk '$2=="up"' | wc -l | tr -d ' ' || true)"
    printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------- generate --
generate() {
    [ -x ./generate-eda-bfd.sh ] || die "generate-eda-bfd.sh not found next to this script"
    log "generating manifests ($COUNT sessions over $PORTS ports)"
    ./generate-eda-bfd.sh --count "$COUNT" --ports "$PORTS" --outdir "$OUTDIR" >/dev/null
}

# ------------------------------------------------------------ deploy: ports --
deploy_ports() {
    log "deploying ports (layer 1)"
    # Delete the CR first: the workflow only fires on create, and an apply over
    # an existing CR is a silent no-op. This does not touch the links themselves.
    k delete networktopology "$TOPO_CR" --ignore-not-found >/dev/null
    k create -f "$OUTDIR/00-topology.yaml" >/dev/null
    log "waiting for $PORTS links to come up"
    for i in $(seq 1 30); do
        n="$(topolinks_up)"
        [ "$n" = "$PORTS" ] && { log "all $PORTS links up"; return; }
        sleep 10
    done
    warn "only $(topolinks_up)/$PORTS links up - check: kubectl -n $EDA_NS get topolinks"
}

# --------------------------------------------------------- deploy: sessions --
deploy_sessions() {
    log "deploying sessions (layer 2)"
    k apply -f "$OUTDIR/01-routers.yaml" >/dev/null
    for f in "$OUTDIR"/02-sessions-*.yaml; do
        k apply -f "$f" >/dev/null
        printf '    applied %s\r' "$(basename "$f")"
    done
    echo
    # Wait for sessions to be UP, not merely present. The config lands well
    # before the sessions come up - with 1s timers and a x3 multiplier the last
    # few take a while, and checking the count alone reports success at ~90%.
    log "waiting for $COUNT sessions to come UP (timeout ${SESSION_TIMEOUT}s)"
    deadline=$(( $(date +%s) + SESSION_TIMEOUT ))
    while :; do
        l="$(bfd_up leaf1)"; s="$(bfd_up spine1)"
        if [ "$l" = "$COUNT" ] && [ "$s" = "$COUNT" ]; then
            log "leaf1=$l spine1=$s sessions UP"
            return
        fi
        [ "$(date +%s)" -ge "$deadline" ] && { warn "timed out at leaf1=$l spine1=$s UP"; return; }
        printf '    UP: leaf1=%s spine1=%s of %s ...\r' "$l" "$s" "$COUNT"
        sleep 15
    done
}

# ---------------------------------------------------------------- teardown --
teardown_sessions() {
    log "removing sessions (label $LABEL=true)"
    k delete defaultstaticroutes,defaultinterfaces,defaultrouters \
        -l "$LABEL=true" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    for i in $(seq 1 60); do
        n="$(k get defaultinterfaces,defaultstaticroutes,defaultrouters \
               -l "$LABEL=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        [ "$n" = "0" ] && { log "session resources removed"; return; }
        printf '    %s still present...\r' "$n"
        sleep 5
    done
    warn "some labelled resources remain"
}

teardown_ports() {
    log "removing ports (layer 1)"
    [ -f "$OUTDIR/00-topology.yaml" ] || { warn "no $OUTDIR/00-topology.yaml; run generate first"; return; }
    # Same link list, operation: Delete. A plain kubectl delete of the
    # NetworkTopology CR would leave every TopoLink and Interface behind.
    tmp="$(mktemp)"
    yq '.metadata.name = "bfd-links-delete" | .spec.operation = "Delete"' \
        "$OUTDIR/00-topology.yaml" > "$tmp"
    k delete networktopology bfd-links-delete --ignore-not-found >/dev/null
    k create -f "$tmp" >/dev/null
    rm -f "$tmp"
    for i in $(seq 1 30); do
        n="$(k get topolinks --no-headers 2>/dev/null | grep -c 'bfd-' || true)"
        [ "$n" = "0" ] && { log "links removed"; break; }
        sleep 5
    done
    k delete networktopology bfd-links-delete --ignore-not-found >/dev/null
    k delete networktopology "$TOPO_CR" --ignore-not-found >/dev/null
    log "topology CRs removed"
}

# ------------------------------------------------------------------ verify --
do_verify() {
    echo
    log "BFD state"
    kubectl -n eda-system exec deploy/eda-toolbox -- edactl -n "$EDA_NS" query \
        .namespace.node.srl.bfd 2>/dev/null | sed 's/^/    /'
    for n in leaf1 spine1; do
        t="$(bfd_sessions "$n")"; u="$(bfd_up "$n")"
        if [ "$t" != "0" ] && [ "$t" = "$u" ]; then
            log "$n: $u/$t sessions UP"
        else
            warn "$n: $u/$t sessions UP"
        fi
    done
    echo
    log "resources"
    printf '    links up:            %s\n' "$(topolinks_up)"
    for r in defaultrouters defaultinterfaces defaultstaticroutes; do
        printf '    %-20s %s\n' "$r:" "$(k get "$r" -l "$LABEL=true" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    done
    printf '    alarms:              %s\n' "$(k get alarms --no-headers 2>/dev/null | wc -l | tr -d ' ')"
}

# --------------------------------------------------------------------- main --
case "$CMD" in
    deploy)
        generate
        [ "$SESSIONS_ONLY" -eq 1 ] || deploy_ports
        deploy_sessions
        do_verify
        ;;
    teardown)
        teardown_sessions
        [ "$SESSIONS_ONLY" -eq 1 ] || teardown_ports
        do_verify
        ;;
    verify|status)
        do_verify
        ;;
    *)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
