#!/usr/bin/env bash
# kb-mongosync: drive mongosync to migrate MongoDB clusters.
# Deployment is done with the kb-mongosync Helm chart; this script only
# prepares values, installs, and drives the mongosync HTTP API.
#
# Two input modes:
#   auto   --src-ns/--src-cluster/--dst-ns/--dst-cluster; connection strings
#            are discovered from KubeBlocks resources via kubectl
#   manual --source-uri/--destination-uri; no kubectl discovery at all, and
#            --api-url drives an existing release without kubectl
set -Eeuo pipefail

# All logging goes to stderr so captured stdout carries data only.
log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*" >&2; exit 1; }

KB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kb-mongosync.XXXXXX")"
chmod 700 "$KB_TMP"
PF_PID=""

cleanup() {
  local rc=$?
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
  rm -rf "$KB_TMP"
  exit "$rc"
}
trap cleanup EXIT INT TERM

for _c in curl python3; do
  command -v "$_c" >/dev/null 2>&1 || die "missing dependency: $_c"
done

KCTL_CFG="${KUBECONFIG:-$HOME/.kube/config}"
KCTX=""
SRC_URI=""
DST_URI=""
SRC_NS="";  SRC_CLUSTER=""
DST_NS="";  DST_CLUSTER=""
NAMESPACE=""
RELEASE=""
API_URL=""
API_PORT=27180
CHART="oci://ghcr.io/zijiren233/kb-mongosync-chart/kb-mongosync"
CHART_VERSION=""
CHART_DIR=""
IMAGE=""
MSYNC_VER=""
SETOPT=()
COMPONENT=""
WAIT_TIMEOUT=1800
ASSUME_YES=0
FORCE=0
WB_OFF=0
INSPECT_DST=0
SRC_MODE=""
DST_MODE=""

SUBCMD=""
WAIT_FOR="copy"
MODE=""

usage() {
  cat <<'EOF'
kb-mongosync: migrate MongoDB clusters via mongosync (Helm-deployed)

Input sides (each side independently, mixing is allowed):
  cluster side:  --src-cluster NAME [--src-ns NS]   (same for --dst-*)
                 namespace defaults to the kubeconfig context's namespace;
                 connection strings are discovered from KubeBlocks via kubectl
  static side:   --source-uri URI / --destination-uri URI
                 no kubectl discovery for that side
  both static = manual mode; both cluster = auto mode; one of each = hybrid
  (RBAC is only created for cluster sides)

Options:
  --kubeconfig PATH       kubeconfig for kubectl/helm (default $KUBECONFIG)
  --context NAME          context to select from the kubeconfig
  --namespace NS          release namespace (default: the source namespace,
                          which itself defaults to the kubeconfig context)
  --release NAME          helm release name (default msync-<src>-to-<dst>, or msync-manual)
  --chart URI             chart reference (default oci://ghcr.io/zijiren233/kb-mongosync-chart/kb-mongosync)
  --chart-version V       chart version (defaults to latest)
  --chart-dir PATH        use a local chart directory instead of --chart
  --image URI             override the tool image (repo:tag)
  --mongosync-version V   deploy image tag mongosync-V, one of the mongosync
                          builds published alongside the chart (default: the
                          chart's pinned version)
  --set K=V               extra helm --set values for deploy (repeatable)
  --api-url URL           mongosync API endpoint, skips kubectl port-forward
  --port N                local port-forward start port (default 27180)
  --timeout SECS          wait/commit timeout (default 1800)
  --for COND              wait condition: copy|lag|can-commit|committed
  --yes                   assume yes (required in non-interactive sessions)
  --force                 allow commit even if the source is not quiet
  --no-write-blocking     start without enableUserWriteBlocking (mongosync
                          then never blocks source writes during commit)
  -h | --help             show this help

Subcommands:
  check       preflight (auto mode only: clusters, versions, credentials, empty destination)
  deploy      helm upgrade --install with chart values built from the chosen mode
  render-conf print the mongosync config resolved from KBMS_* env (used by the image entrypoint)
  start       start the sync
  status      show sync state
  wait        wait for a condition (--for)
  verify      compare counts and dbHash on both sides (auto mode)
  inspect     show write rate, oplog quiescence, active writers, write-block
              state and inventory of the source (--dst: destination)
  commit      commit the migration (source write-blocked, then COMMITTED)
  block       fence the source against application writes now (pre-cutover step;
              writes fail fast until unblock)
  unblock     release the source write block (auto mode)
  teardown    helm uninstall the release
  rbac        print least-privilege Role/RoleBinding
  run         check, deploy, start, wait for copy, status

API-driving subcommands (start/status/wait/commit) also work inside the pod:
  kubectl exec -it <pod> -- kb-mongosync status
EOF
}

need_value() { [ $# -ge 2 ] || die "option $1 requires a value"; }

validate_uri() { # flag-name value; catches the misconfigurations that would
                 # otherwise surface only as a crashlooping mongosync pod
  local name="$1" val="$2"
  case "$val" in
    mongodb://*|mongodb+srv://*) : ;;
    *) die "$name must start with mongodb:// (value withheld)" ;;
  esac
  printf '%s' "$val" | LC_ALL=C grep -qE '^[[:print:]]+$' \
    || die "$name contains non-printable characters"
  printf '%s' "$val" | grep -qE '[[:space:]]' \
    && die "$name contains whitespace"
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig)    need_value "$@"; KCTL_CFG="$2"; KCFG_GIVEN=1; shift 2 ;;
    --context)       need_value "$@"; KCTX="$2"; shift 2 ;;
    --source-uri)    need_value "$@"; SRC_URI="$2"; shift 2 ;;
    --destination-uri) need_value "$@"; DST_URI="$2"; shift 2 ;;
    --src-ns)        need_value "$@"; SRC_NS="$2"; shift 2 ;;
    --src-cluster)   need_value "$@"; SRC_CLUSTER="$2"; shift 2 ;;
    --dst-ns)        need_value "$@"; DST_NS="$2"; shift 2 ;;
    --dst-cluster)   need_value "$@"; DST_CLUSTER="$2"; shift 2 ;;
    --namespace|-n)  need_value "$@"; NAMESPACE="$2"; shift 2 ;;
    --release)       need_value "$@"; RELEASE="$2"; shift 2 ;;
    --chart)         need_value "$@"; CHART="$2"; shift 2 ;;
    --chart-version) need_value "$@"; CHART_VERSION="$2"; shift 2 ;;
    --chart-dir)     need_value "$@"; CHART_DIR="$2"; shift 2 ;;
    --image)         need_value "$@"; IMAGE="$2"; shift 2 ;;
    --mongosync-version) need_value "$@"; MSYNC_VER="$2"; shift 2 ;;
    --set)           need_value "$@"; SETOPT+=(--set "$2"); shift 2 ;;
    --api-url)       need_value "$@"; API_URL="$2"; shift 2 ;;
    --port)          need_value "$@"; API_PORT="$2"; shift 2 ;;
    --timeout)       need_value "$@"; WAIT_TIMEOUT="$2"; shift 2 ;;
    --for)           need_value "$@"; WAIT_FOR="$2"; shift 2 ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --force)         FORCE=1; shift ;;
    --no-write-blocking) WB_OFF=1; shift ;;
    --dst)          INSPECT_DST=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               [ -z "$SUBCMD" ] || die "only one subcommand allowed: '$SUBCMD' and '$1'"
                     SUBCMD="$1"; shift ;;
  esac
done

[ -n "$SUBCMD" ] || { usage; exit 1; }

# Only subcommands that touch KubeBlocks clusters or build chart values need a
# full input mode; API-driving subcommands work standalone (also in-pod).
# Each side resolves independently: a static URI or a namespace+cluster pair;
# mixing the two (hybrid) is allowed. RBAC is only created for cluster sides.
# current context's default namespace (empty when unset or unreachable)
ctx_ns() {
  local args=()
  [ -n "$KCTL_CFG" ] && args=(--kubeconfig "$KCTL_CFG")
  [ -n "$KCTX" ] && args+=(--context "$KCTX")
  kubectl ${args[@]+"${args[@]}"} config view --minify -o jsonpath='{..namespace}' 2>/dev/null | head -n1
}

# a cluster side given without --src-ns/--dst-ns uses the kubeconfig
# context's default namespace, matching kubectl's own behavior (applies to
# every subcommand, including the API-driving ones that locate the release)
if { [ -n "$SRC_CLUSTER" ] && [ -z "$SRC_NS" ]; } || { [ -n "$DST_CLUSTER" ] && [ -z "$DST_NS" ]; }; then
  DEF_NS="$(ctx_ns)"
  : "${DEF_NS:=default}"
  [ -n "$SRC_NS" ] || SRC_NS="$DEF_NS"
  [ -n "$DST_NS" ] || DST_NS="$DEF_NS"
fi

case "$SUBCMD" in
  check|deploy|verify|block|unblock|rbac|run)
    if [ -n "$SRC_URI" ]; then
      [ -z "$SRC_NS" ] && [ -z "$SRC_CLUSTER" ] || die "source: pass either --source-uri or --src-ns/--src-cluster, not both"
      validate_uri --source-uri "$SRC_URI"
      SRC_MODE=uri
    elif [ -n "$SRC_NS" ] && [ -n "$SRC_CLUSTER" ]; then
      SRC_MODE=cluster
    elif [ -z "$SRC_NS" ] && [ -z "$SRC_CLUSTER" ]; then
      die "missing --src-ns (or use --source-uri for a static source)"
    else
      die "source side needs both --src-ns and --src-cluster"
    fi
    if [ -n "$DST_URI" ]; then
      [ -z "$DST_NS" ] && [ -z "$DST_CLUSTER" ] || die "destination: pass either --destination-uri or --dst-ns/--dst-cluster, not both"
      validate_uri --destination-uri "$DST_URI"
      DST_MODE=uri
    elif [ -n "$DST_NS" ] && [ -n "$DST_CLUSTER" ]; then
      DST_MODE=cluster
    elif [ -z "$DST_NS" ] && [ -z "$DST_CLUSTER" ]; then
      die "missing --dst-ns (or use --destination-uri for a static destination)"
    else
      die "destination side needs both --dst-ns and --dst-cluster"
    fi
    if [ "$SRC_MODE" = uri ] && [ "$DST_MODE" = uri ]; then MODE=manual
    elif [ "$SRC_MODE" = cluster ] && [ "$DST_MODE" = cluster ]; then MODE=auto
    else MODE=hybrid
    fi
    ;;
esac
if [ -z "$RELEASE" ]; then
  RELEASE="msync-${SRC_CLUSTER:-manual}-to-${DST_CLUSTER:-manual}"
fi
[ -n "$NAMESPACE" ] || NAMESPACE="${SRC_NS:-${DST_NS:-}}"

case "$SUBCMD" in
  deploy|teardown) command -v helm >/dev/null 2>&1 || die "missing dependency: helm" ;;
esac
if [ "${MODE:-}" = auto ]; then
  command -v kubectl >/dev/null 2>&1 || die "missing dependency: kubectl"
fi
if [ "${KCFG_GIVEN:-0}" -eq 1 ]; then
  [ -f "$KCTL_CFG" ] || die "kubeconfig not found: $KCTL_CFG"
  export KUBECONFIG="$KCTL_CFG"
elif [ -z "${KUBECONFIG:-}" ] && [ -f "$KCTL_CFG" ]; then
  export KUBECONFIG="$KCTL_CFG"
fi
if [ -n "$KCTX" ]; then
  kubectl config view --raw --minify --context="$KCTX" >"$KB_TMP/context.cfg" 2>/dev/null \
    || die "context not found in kubeconfig: $KCTX"
  export KUBECONFIG="$KB_TMP/context.cfg"
fi

kc() { kubectl "$@"; }
kc_never_fails() { "$@" 2>/dev/null || true; }

load_cluster() { # ns name
  local out
  if ! out="$(kc get cluster "$2" -n "$1" -o json 2>/dev/null)"; then
    die "cluster $1/$2 not found or access denied"
  fi
  printf '%s' "$out"
}

cluster_phase() { # ns name
  kc_never_fails kc get cluster "$2" -n "$1" -o jsonpath='{.status.phase}'
}

discover_component() { # ns cluster
  local cj; cj="$(load_cluster "$1" "$2")"
  if [ -n "$COMPONENT" ]; then
    printf '%s' "$COMPONENT"
  else
    printf '%s' "$cj" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["spec"]["componentSpecs"][0]["name"])'
  fi
}

component_pods() { # ns cluster component
  kc_never_fails kc get pods -n "$1" -o json | python3 -c '
import json,sys
cluster, comp = sys.argv[1], sys.argv[2]
d=json.load(sys.stdin)
names=[]
prefix=f"{cluster}-{comp}-"
for p in d.get("items",[]):
    n=p["metadata"]["name"]
    if n.startswith(prefix) and p.get("status",{}).get("phase")=="Running":
        tail=n[len(prefix):]
        if tail.isdigit(): names.append((int(tail), n))
for _,n in sorted(names): print(n)' "$2" "$3"
}

find_primary_pod() { # ns cluster component
  local p out
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    out="$(kc_never_fails kc exec "$p" -n "$1" -c "$3" -- \
      sh -c 'mongosh --quiet -u "$MONGODB_ROOT_USER" -p "$MONGODB_ROOT_PASSWORD" \
             --authenticationDatabase admin --eval "print(db.hello().isWritablePrimary)" 2>/dev/null' \
      | tail -n1 || true)"
    if [ "$out" = "true" ]; then printf '%s\n' "$p"; return 0; fi
  done < <(component_pods "$1" "$2" "$3")
  return 1
}

# JS travels via stdin so credentials stay in pod env and no quoting leaks.
mongosh_js() { # ns pod component js
  printf '%s' "$4" | kc exec -i "$2" -n "$1" -c "$3" -- \
    sh -c 'mongosh --quiet -u "$MONGODB_ROOT_USER" -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$(cat)"' \
    || die "mongosh failed on pod $2"
}

# Old KubeBlocks v1alpha1 Clusters carry clusterVersionRef instead of
# componentSpecs[].serviceVersion, so the CR cannot answer "which patch?".
# Ask the server: it is what mongosync validates against.
live_db_version() { # ns cluster component
  local pod
  pod="$(find_primary_pod "$1" "$2" "$3" || true)"
  [ -n "$pod" ] || return 1
  kc_never_fails kc exec "$pod" -n "$1" -c "$3" -- \
    sh -c 'mongosh --quiet -u "$MONGODB_ROOT_USER" -p "$MONGODB_ROOT_PASSWORD" \
           --authenticationDatabase admin --eval "print(db.version())" 2>/dev/null' \
    | tail -n1
}

read_secret() { # ns secret key
  kc_never_fails kc get secret "$2" -n "$1" -o jsonpath="{.data.$3}" | base64 -d
}

uri_safe() { echo "$1" | grep -qE '^[A-Za-z0-9._~-]+$'; }

build_uri() { # ns cluster component
  local ns="$1" cluster="$2" comp="$3" u p seeds rs pod fqdn
  rs="${cluster}-${comp}"
  u="$(read_secret "$ns" "${rs}-account-root" username)"
  p="$(read_secret "$ns" "${rs}-account-root" password)"
  [ -n "$u" ] && [ -n "$p" ] || die "secret ${ns}/${rs}-account-root missing username/password"
  uri_safe "$u" && uri_safe "$p" \
    || die "credentials contain URI-unsafe characters: $ns/${rs}-account-root"
  seeds=""
  while IFS= read -r pod; do
    [ -n "$pod" ] || continue
    fqdn="${pod}.${rs}-headless.${ns}.svc.cluster.local:27017"
    seeds="${seeds:+$seeds,}$fqdn"
  done < <(component_pods "$ns" "$cluster" "$comp")
  [ -n "$seeds" ] || die "no Running pod matching ${cluster}-${comp}-<N> in $ns"
  printf 'mongodb://%s:%s@%s/?replicaSet=%s' "$u" "$p" "$seeds" "$rs"
}

# mongosync API access: KBMS_API_URL/--api-url directly (also set in-pod by the
# entrypoint), or kubectl port-forward to the release pod.
API_BASE=""

release_pod() {
  kc_never_fails kc get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=kb-mongosync" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
run=[p for p in d.get("items",[]) if p.get("status",{}).get("phase")=="Running"]
print(run[0]["metadata"]["name"] if run else "")'
}

wait_release_pod_ready() { # timeout_secs
  local deadline=$(( $(date +%s) + $1 )) ready
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ready="$(kc_never_fails kc get pods -n "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=kb-mongosync" \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}')"
    [ "$ready" = "true" ] && return 0
    sleep 3
  done
  return 1
}

pf_up() {
  [ -n "$API_BASE" ] && return 0
  if [ -n "$API_URL" ]; then API_BASE="$API_URL"; return 0; fi
  if [ -n "${KBMS_API_URL:-}" ]; then API_BASE="$KBMS_API_URL"; return 0; fi
  command -v kubectl >/dev/null 2>&1 || die "no kubectl and no --api-url; cannot reach the API"
  [ -n "$NAMESPACE" ] || die "need --namespace (or --api-url) to locate the release"
  local pod p tried=0 i
  pod="$(release_pod)"
  [ -n "$pod" ] || die "no pod found for release $NAMESPACE/$RELEASE (run deploy first)"
  p="$API_PORT"
  while [ $tried -lt 10 ]; do
    if ! command -v nc >/dev/null 2>&1 || ! nc -z 127.0.0.1 "$p" 2>/dev/null; then
      # background kubectl directly: through the kc() wrapper $! would be the
      # subshell pid and killing it would orphan the kubectl child
      kubectl port-forward --address 127.0.0.1 -n "$NAMESPACE" pod/"$pod" "${p}:27180" \
        >/dev/null 2>"$KB_TMP/pf.err" &
      PF_PID=$!
      for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        if curl -s --max-time 3 "http://127.0.0.1:${p}/api/v1/progress" >/dev/null 2>&1; then
          API_BASE="http://127.0.0.1:${p}"
          info "port-forward ready: ${API_BASE} -> ${NAMESPACE}/${pod}:27180"
          return 0
        fi
        kill -0 "$PF_PID" 2>/dev/null || break
      done
      kill "$PF_PID" 2>/dev/null || true
      PF_PID=""
    fi
    p=$((p+1)); tried=$((tried+1))
  done
  die "port-forward failed; check kubectl get pod -n $NAMESPACE -l app.kubernetes.io/instance=${RELEASE}"
}

api_get_progress() {
  pf_up
  local body i
  for i in 1 2 3; do
    if body="$(curl -s --max-time 15 "${API_BASE}/api/v1/progress")"; then
      printf '%s' "$body"
      return 0
    fi
    [ "$i" -lt 3 ] && { warn "GET /api/v1/progress attempt $i failed; retrying"; sleep 3; }
  done
  die "GET /api/v1/progress failed"
}

api_post() { # path body
  pf_up
  curl -s --max-time 300 -X POST "${API_BASE}$1" -H 'Content-Type: application/json' -d "$2" \
    || die "POST $1 failed"
}

progress_field() { # field
  api_get_progress | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin).get("progress",{})
    v=d.get(sys.argv[1])
    print("" if v is None else v)
except Exception:
    print("")' "$1"
}

chart_ref() {
  if [ -n "$CHART_DIR" ]; then
    [ -d "$CHART_DIR" ] || die "chart dir not found: $CHART_DIR"
    printf '%s' "$CHART_DIR"
  else
    printf '%s' "$CHART"
  fi
}

cmd_check() {
  [ -n "$SRC_NS" ] || [ -n "$DST_NS" ] \
    || die "check requires at least one cluster side (full manual mode: verify your URIs yourself)"
  local fail=0 src_comp dst_comp src_phase dst_phase src_ver dst_ver dbs dst_primary src_primary meta out
  if [ -n "$SRC_NS" ]; then
    src_phase="$(cluster_phase "$SRC_NS" "$SRC_CLUSTER")"
    src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
    COMPONENT="$src_comp"
    [ "$src_phase" = "Running" ] || { warn "source cluster phase=$src_phase (need Running)"; fail=1; }
    src_ver="$(load_cluster "$SRC_NS" "$SRC_CLUSTER" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(d["spec"]["componentSpecs"][0].get("serviceVersion",""))')"
    info "source:      $SRC_NS/$SRC_CLUSTER component=$src_comp serviceVersion=${src_ver:-absent, asking the server}"
  else
    src_phase=""; src_comp=""; src_ver=""
    info "source:      static URI (phase/version/arbiter/collection checks skipped)"
  fi
  if [ -n "$DST_NS" ]; then
    dst_phase="$(cluster_phase "$DST_NS" "$DST_CLUSTER")"
    dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")"
    [ "$dst_phase" = "Running" ] || { warn "destination cluster phase=$dst_phase (need Running)"; fail=1; }
    dst_ver="$(load_cluster "$DST_NS" "$DST_CLUSTER" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(d["spec"]["componentSpecs"][0].get("serviceVersion",""))')"
    info "destination: $DST_NS/$DST_CLUSTER component=$dst_comp serviceVersion=${dst_ver:-absent, asking the server}"
  else
    dst_phase=""; dst_comp=""; dst_ver=""
    info "destination: static URI (phase/version/emptiness checks skipped)"
  fi

  if [ -n "$SRC_NS" ] && [ -z "$src_ver" ]; then
    out="$(live_db_version "$SRC_NS" "$SRC_CLUSTER" "$src_comp" || true)"
    case "$out" in
      [0-9]*.[0-9]*.[0-9]*) src_ver="$out"; info "source:      server reports version $src_ver" ;;
      *) warn "cannot determine source version (Cluster carries no serviceVersion, live query failed)"; fail=1 ;;
    esac
  fi
  if [ -n "$DST_NS" ] && [ -z "$dst_ver" ]; then
    out="$(live_db_version "$DST_NS" "$DST_CLUSTER" "$dst_comp" || true)"
    case "$out" in
      [0-9]*.[0-9]*.[0-9]*) dst_ver="$out"; info "destination: server reports version $dst_ver" ;;
      *) warn "cannot determine destination version (Cluster carries no serviceVersion, live query failed)"; fail=1 ;;
    esac
  fi

  if [ -n "$src_ver" ] && [ -n "$dst_ver" ]; then
    case "$(python3 -c '
import sys
def v(x):
    try: return tuple(int(i) for i in x.split(".")[:3])
    except Exception: return (0,0,0)
s, d = v(sys.argv[1]), v(sys.argv[2])
if s < (6,0,0): print("bad-src")
elif s < (6,0,17): print("low-src-patch")
elif not ((7,0,0) <= d): print("bad-dst")
else: print("ok")' "$src_ver" "$dst_ver")" in
      ok)           : ;;
      bad-src)      warn "mongosync requires source >= 6.0 (got $src_ver)"; fail=1 ;;
      low-src-patch) warn "source $src_ver is below mongosync's 6.0 floor: every downloadable build (1.13.1-1.16.0, including the bundled one) requires source >= 6.0.17; patch-upgrade the source first (>= 6.0.24 also satisfies newer mongosync)"; fail=1 ;;
      bad-dst)      warn "mongosync requires destination 7.0/8.0 (got $dst_ver)"; fail=1 ;;
      *)            warn "unparseable version (src=$src_ver dst=$dst_ver)"; fail=1 ;;
    esac
  fi
  info "note: every published mongosync build (1.13.1-1.16.0) requires source >= 6.0.17 and destination 7.0/8.0"

  if [ -n "$SRC_NS" ]; then
    src_primary="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp" || true)"
    if [ -z "$src_primary" ]; then
      warn "no primary pod found on source cluster"
      fail=1
    else
      out="$(mongosh_js "$SRC_NS" "$src_primary" "$src_comp" '
        print(rs.conf().members.filter(function(m){return m.arbiterOnly}).length)')"
      if [ "$out" = "0" ]; then
        info "source: no arbiter members"
      else
        warn "source has $out arbiter member(s); mongosync refuses replica sets with arbiters"
        fail=1
      fi
      out="$(mongosh_js "$SRC_NS" "$src_primary" "$src_comp" '
        const bad=[];
        for (const n of db.getMongo().getDBNames()) {
          if (["admin","config","local"].includes(n)) continue;
          const r=db.getSiblingDB(n).runCommand({listCollections:1, nameOnly:true, authorizedCollections:true});
          for (const c of r.cursor.firstBatch)
            if (c.type && c.type !== "collection") bad.push(n+"."+c.name+":"+c.type);
        }
        print(bad.join(","))')"
      if [ -n "$out" ]; then
        warn "non-plain collections on source (mongosync copies plain collections only): $out"
        fail=1
      else
        info "source: plain collections only"
      fi
    fi
  fi

  if [ -n "$DST_NS" ]; then
    dst_primary="$(find_primary_pod "$DST_NS" "$DST_CLUSTER" "$dst_comp" || true)"
    if [ -z "$dst_primary" ]; then
      warn "no primary pod found on destination cluster"
      fail=1
    else
      out="$(mongosh_js "$DST_NS" "$dst_primary" "$dst_comp" '
        const names=db.getMongo().getDBNames();
        const skip=["admin","config","local","__mdb_internal_mongosync","mongosync_reserved_for_internal_use"];
        print(names.filter(function(n){return !skip.includes(n)}).join(","));
        print("meta:"+names.filter(function(n){return ["__mdb_internal_mongosync","mongosync_reserved_for_internal_use"].includes(n)}).join(","))')"
      dbs="$(printf '%s\n' "$out" | sed -n 1p)"
      meta="$(printf '%s\n' "$out" | sed -n 2p | cut -d: -f2-)"
      if [ -n "$dbs" ]; then
        warn "destination not empty (user dbs: $dbs); full sync requires an empty destination"
        fail=1
      else
        info "destination is empty"
      fi
      if [ -n "$meta" ]; then
        info "destination holds leftover mongosync metadata ($meta): deploying again resumes that sync; for a fresh start drop it or recreate the destination"
      fi
    fi
  fi

  if [ -n "$SRC_NS" ]; then
    if build_uri "$SRC_NS" "$SRC_CLUSTER" "$src_comp" >/dev/null 2>&1; then
      info "source credentials ok"
    else
      warn "failed to read source credentials"; fail=1
    fi
  fi
  if [ -n "$DST_NS" ]; then
    if build_uri "$DST_NS" "$DST_CLUSTER" "$dst_comp" >/dev/null 2>&1; then
      info "destination credentials ok"
    else
      warn "failed to read destination credentials"; fail=1
    fi
  fi

  [ "$fail" -eq 0 ] && info "check passed" || die "check failed (see warnings above)"
}

cmd_deploy() {
  local extra=() src_comp dst_comp
  [ -n "$IMAGE" ] && [ -n "$MSYNC_VER" ] && die "--image and --mongosync-version are mutually exclusive"
  case "$MSYNC_VER" in
    ""|[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) : ;;
    *) die "--mongosync-version must look like X.Y or X.Y.Z (got '$MSYNC_VER')" ;;
  esac
  [ -n "$MSYNC_VER" ] && extra+=(--set-string "image.tag=mongosync-${MSYNC_VER}")
  [ -n "$IMAGE" ] && extra+=(--set-string "image.tag=${IMAGE##*:}")
  [ -n "$CHART_VERSION" ] && [ -z "$CHART_DIR" ] && extra+=(--version "$CHART_VERSION")
  extra+=("${SETOPT[@]}")

  info "writing chart values (connection strings never logged)"
  {
    if [ "$SRC_MODE" = uri ]; then
      printf 'source:\n  uri: "%s"\n' "$SRC_URI"
    else
      src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")" || die "source component discovery failed"
      printf 'source:\n  namespace: "%s"\n  cluster: "%s"\n  component: "%s"\n' "$SRC_NS" "$SRC_CLUSTER" "$src_comp"
    fi
    if [ "$DST_MODE" = uri ]; then
      printf 'destination:\n  uri: "%s"\n' "$DST_URI"
    else
      dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")" || die "destination component discovery failed"
      printf 'destination:\n  namespace: "%s"\n  cluster: "%s"\n  component: "%s"\n' "$DST_NS" "$DST_CLUSTER" "$dst_comp"
    fi
    if [ "$MODE" = manual ]; then
      printf 'serviceAccount:\n  create: false\nrbac:\n  create: false\n'
    fi
  } > "$KB_TMP/values.yaml"
  chmod 600 "$KB_TMP/values.yaml"

  info "helm upgrade --install $NAMESPACE/$RELEASE"
  helm upgrade --install "$RELEASE" "$(chart_ref)" -n "$NAMESPACE" \
    -f "$KB_TMP/values.yaml" --wait --timeout 5m "${extra[@]}" \
    || die "helm install failed"
  info "deploy done: release $NAMESPACE/$RELEASE (pod discovers and starts mongosync itself)"
}

# Render the mongosync config from the environment; used by the image
# entrypoint (KBMS_* env vars set by the chart) and runnable by hand.
# Each side resolves independently: KBMS_*_URI, or KBMS_*_NAMESPACE/CLUSTER.
cmd_render_conf() {
  local src_uri="${KBMS_SOURCE_URI:-}" dst_uri="${KBMS_DESTINATION_URI:-}"
  local port="${KBMS_PORT:-27180}" verbosity="${KBMS_VERBOSITY:-INFO}"
  [ -n "$src_uri$dst_uri${KBMS_SOURCE_NAMESPACE:-}${KBMS_SOURCE_CLUSTER:-}${KBMS_DESTINATION_NAMESPACE:-}${KBMS_DESTINATION_CLUSTER:-}" ] \
    || die "no KBMS_* configuration found in environment"
  if [ -z "$src_uri" ]; then
    [ -n "${KBMS_SOURCE_NAMESPACE:-}" ] && [ -n "${KBMS_SOURCE_CLUSTER:-}" ] \
      || die "source side needs KBMS_SOURCE_URI or KBMS_SOURCE_NAMESPACE/CLUSTER"
    src_uri="$(build_uri "${KBMS_SOURCE_NAMESPACE}" "${KBMS_SOURCE_CLUSTER}" \
      "${KBMS_SOURCE_COMPONENT:-$(discover_component "${KBMS_SOURCE_NAMESPACE}" "${KBMS_SOURCE_CLUSTER}")}")"
  fi
  if [ -z "$dst_uri" ]; then
    [ -n "${KBMS_DESTINATION_NAMESPACE:-}" ] && [ -n "${KBMS_DESTINATION_CLUSTER:-}" ] \
      || die "destination side needs KBMS_DESTINATION_URI or KBMS_DESTINATION_NAMESPACE/CLUSTER"
    dst_uri="$(build_uri "${KBMS_DESTINATION_NAMESPACE}" "${KBMS_DESTINATION_CLUSTER}" \
      "${KBMS_DESTINATION_COMPONENT:-$(discover_component "${KBMS_DESTINATION_NAMESPACE}" "${KBMS_DESTINATION_CLUSTER}")}")"
  fi
  printf '{\n  "cluster0": "%s",\n  "cluster1": "%s",\n  "port": %s,\n  "verbosity": "%s",\n  "disableTelemetry": true\n}\n' \
    "$src_uri" "$dst_uri" "$port" "$verbosity"
}

cmd_start() {
  local state resp body
  pf_up
  state="$(progress_field state)"
  case "$state" in
    RUNNING|COMMITTING|COMMITTED)
      info "state=$state already, start skipped (idempotent)"; return 0 ;;
    IDLE|"") : ;;
    *)
      warn "state=$state (not IDLE), refusing to start; inspect with status"
      return 1 ;;
  esac
  if [ "$WB_OFF" -eq 1 ]; then
    body='{"source":"cluster0","destination":"cluster1"}'
  else
    body='{"source":"cluster0","destination":"cluster1","enableUserWriteBlocking":true}'
  fi
  info "POST /api/v1/start {source: cluster0 -> destination: cluster1, enableUserWriteBlocking: $([ "$WB_OFF" -eq 1 ] && echo false || echo true)}"
  resp="$(api_post /api/v1/start "$body")"
  printf '%s' "$resp" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("success"):
    print("[start] accepted")
else:
    print("[start] FAILED:", d.get("error"), "-", d.get("errorDescription"), file=sys.stderr)
    sys.exit(1)'
  info "start accepted; watch with status/wait"
}

cmd_status() {
  pf_up
  api_get_progress | python3 -c '
import json,sys
try:
    p=json.load(sys.stdin)["progress"]
except Exception as e:
    print("failed to parse progress:", e, file=sys.stderr); sys.exit(1)
cc=p.get("collectionCopy") or {}
print("state        =", p.get("state"))
print("canCommit    =", p.get("canCommit"))
print("canWrite     =", p.get("canWrite"))
print("lagSeconds   =", p.get("lagTimeSeconds"))
print("info         =", p.get("info"))
if cc:
    print("copy         = %s / %s bytes" % (cc.get("estimatedCopiedBytes"), cc.get("estimatedTotalBytes")))
v=p.get("verification") or {}
if v: print("verification =", json.dumps(v)[:200])'
}

cmd_wait() {
  pf_up
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT )) state lag ok
  info "waiting for: $WAIT_FOR (timeout ${WAIT_TIMEOUT}s)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(progress_field state)"
    lag="$(progress_field lagTimeSeconds)"
    case "$WAIT_FOR" in
      copy)
        ok="$(api_get_progress | python3 -c '
import json,sys
cc=json.load(sys.stdin)["progress"].get("collectionCopy") or {}
t=cc.get("estimatedTotalBytes"); c=cc.get("estimatedCopiedBytes")
print("yes" if t and c and int(c)>=int(t) else "no")')"
        [ "$ok" = "yes" ] && { info "collection copy complete"; return 0; } ;;
      lag)
        [ -n "$lag" ] && [ "$lag" -le 1 ] 2>/dev/null && { info "lag=${lag}s"; return 0; } ;;
      can-commit)
        [ "$(progress_field canCommit)" = "True" ] && { info "canCommit=true"; return 0; } ;;
      committed)
        [ "$state" = "COMMITTED" ] && { info "state=COMMITTED"; return 0; } ;;
      *) die "unknown --for: $WAIT_FOR" ;;
    esac
    info "  ... state=$state lag=${lag:-n/a}"
    [ "$state" = "ERROR" ] && die "mongosync state=ERROR, aborting wait"
    sleep 10
  done
  die "timed out waiting for $WAIT_FOR (${WAIT_TIMEOUT}s)"
}

cmd_verify() {
  if [ "$SRC_MODE" != cluster ] || [ "$DST_MODE" != cluster ]; then
    cat <<'EOF'
verify needs both sides as KubeBlocks clusters (it execs mongosh on the pods).
With a static URI side, compare both sides yourself, e.g. per database:
  db.runCommand({dbHash: 1, collections: db.getCollectionNames()})
EOF
    exit 2
  fi
  local src_comp dst_comp sp dp out6 out8
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")"
  if kc get pod "$(release_pod)" -n "$NAMESPACE" >/dev/null 2>&1; then
    local lag; lag="$(progress_field lagTimeSeconds)"
    [ "$lag" = "0" ] || warn "lag=${lag:-n/a}s (results may drift while the source is written)"
  else
    warn "release pod not found, skipping lag check (offline comparison)"
  fi
  sp="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp" || true)"
  dp="$(find_primary_pod "$DST_NS" "$DST_CLUSTER" "$dst_comp" || true)"
  [ -n "$sp" ] || die "no primary pod on source"
  [ -n "$dp" ] || die "no primary pod on destination"
  local js='
    const out = {};
    for (const dbName of db.getMongo().getDBNames()) {
      if (["admin","config","local","__mdb_internal_mongosync","mongosync_reserved_for_internal_use"].includes(dbName)) continue;
      const d = db.getSiblingDB(dbName);
      const cols = d.getCollectionNames().filter(c => !c.startsWith("system."));
      out[dbName] = {hash: d.runCommand({dbHash: 1, collections: cols}).md5, collections: {}};
      for (const c of cols.sort()) {
        out[dbName].collections[c] = {count: d[c].countDocuments({}), idx: d[c].getIndexes().length};
      }
    }
    print(JSON.stringify(out));'
  out6="$(mongosh_js "$SRC_NS" "$sp" "$src_comp" "$js")"
  out8="$(mongosh_js "$DST_NS" "$dp" "$dst_comp" "$js")"
  printf '%s\n%s\n' "$out6" "$out8" | python3 -c '
import json,sys
a=json.loads(sys.stdin.readline()); b=json.loads(sys.stdin.readline())
ok=True
for name in sorted(set(a)|set(b)):
    if a.get(name)!=b.get(name):
        print("MISMATCH: db=%s" % name)
        print("  src:", json.dumps(a.get(name))[:400])
        print("  dst:", json.dumps(b.get(name))[:400])
        ok=False
print("verify:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)' || die "verify failed"
  info "verify passed"
}

oplog_user_ts() { # ns pod comp -> stable string for the last real user oplog entry
  mongosh_js "$1" "$2" "$3" '
    const e = db.getSiblingDB("local").oplog.rs.find({op: {$ne: "n"}}).sort({$natural: -1}).limit(10).toArray()
      .filter(x => x.ns !== "config.system.sessions" && !x.ns.startsWith("kbms_block_probe"))[0];
    print(e ? e.ts.toString() : "none")'
}

cmd_commit() {
  pf_up
  local state can_commit deadline
  state="$(progress_field state)"
  if [ "$state" = "COMMITTED" ]; then
    info "already COMMITTED (idempotent); run unblock to make the source writable again"
    return 0
  fi
  can_commit="$(progress_field canCommit)"
  [ "$can_commit" = "True" ] || die "canCommit=false (state=$state); run wait --for can-commit first"
  # mongosync 1.16 fatals (verifier race) if source writes land after final
  # verification begins. enableUserWriteBlocking fences ordinary users from
  # commit-receive on, but root/restore/__system bypass it, so the authoritative
  # check is oplog quiescence (no user ops over an 8s window) wherever the tool
  # can reach the clusters; lag is only the fallback gate in pure manual mode,
  # and strictly (all samples 0).
  local lag quiet0=0 i ts1 ts2 src_comp sp gns gcl
  gns="$SRC_NS"; gcl="$SRC_CLUSTER"
  if [ -z "$gns" ] && [ -n "${KBMS_SOURCE_NAMESPACE:-}" ]; then
    gns="${KBMS_SOURCE_NAMESPACE}"; gcl="${KBMS_SOURCE_CLUSTER:-}"
  fi
  if [ -n "$gns" ] && [ -n "$gcl" ]; then
    src_comp="${KBMS_SOURCE_COMPONENT:-$(discover_component "$gns" "$gcl")}"
    sp="$(find_primary_pod "$gns" "$gcl" "$src_comp" || true)"
    if [ -z "$sp" ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "cannot reach the source cluster to verify quiescence; --force given"
      else
        die "cannot reach the source cluster to verify quiescence (no primary pod); run commit from the laptop or use --force"
      fi
    else
      ts1="$(oplog_user_ts "$gns" "$sp" "$src_comp")"
      sleep 8
      ts2="$(oplog_user_ts "$gns" "$sp" "$src_comp")"
      if [ "${ts1:-x}" != "${ts2:-y}" ]; then
        if [ "$FORCE" -eq 1 ]; then
          warn "user writes still landing on source (oplog advanced); --force given, committing anyway"
        else
          die "user writes still landing on source (oplog advanced between samples); stop writers (or run block) and retry"
        fi
      fi
    fi
  else
    for i in 1 2 3; do
      lag="$(progress_field lagTimeSeconds)"
      case "${lag:-}" in
        0) quiet0=$((quiet0+1)) ;;
        *) quiet0=0 ;;
      esac
      [ "$i" -lt 3 ] && sleep 5
    done
    if [ "$quiet0" -lt 3 ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "manual mode cannot verify quiescence via the oplog and lag is not all-zero; --force given"
      else
        die "static-source mode cannot prove quiescence from the API alone (idle clusters sawtooth the lag via noop oplog entries; last=${lag:-n/a}); verify the source oplog yourself, then retry with --force"
      fi
    else
      warn "manual mode quiet check is strict lag-only; make sure writers are stopped yourself"
    fi
  fi
  cat >&2 <<EOF

About to commit the migration (POST /api/v1/commit). Notes:
  1. mongosync write-blocks the SOURCE when it receives commit (flag on:
     ordinary users fail fast; root/restore bypass it). On 1.16 a write that
     races the final verification aborts mongosync fatally, so this command
     checks the source is quiet first (oplog, lag in manual mode) unless
     --force.
  2. After COMMITTED the destination is writable and the source stays
     blocked until you run the unblock subcommand.
  3. Commit is final (reverse is only possible before commit).

EOF
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "non-interactive session: add --yes to confirm"
    printf 'Type yes to continue: ' >&2
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi
  info "POST /api/v1/commit"
  # the commit response body may come back empty (observed with a blocked
  # source); the state poll below is the source of truth either way
  api_post /api/v1/commit '{ }' | python3 -c '
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print("[commit] response unreadable; falling back to state polling", file=sys.stderr); sys.exit(0)
if not d.get("success"):
    print("[commit] FAILED:", d.get("error"), d.get("errorDescription",""), file=sys.stderr); sys.exit(1)
print("[commit] accepted, waiting for COMMITTED ...")' || die "commit request rejected"
  deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(progress_field state)"
    info "  ... state=$state lag=$(progress_field lagTimeSeconds)"
    case "$state" in
      COMMITTED)
        info "COMMITTED; destination writable (canWrite=$(progress_field canWrite))"
        info "next: switch the app to the destination -> (optional) unblock -> teardown"
        return 0 ;;
      ERROR) die "commit failed" ;;
    esac
    sleep 5
  done
  die "timed out waiting for COMMITTED (${WAIT_TIMEOUT}s)"
}

block_probe_js() { # "block" or "unblock"; verifies with a short-lived unprivileged user (root bypasses the block)
  if [ "$1" = block ]; then
    printf '
      const r = db.adminCommand({setUserWriteBlockMode: 1, global: true});
      const admin = db.getSiblingDB("admin");
      try { admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}}); } catch (e) {}
      admin.runCommand({createUser: "kbms_block_probe", pwd: "kbms-probe-pw", roles: [{role: "readWrite", db: "kbms_block_probe"}]});
      let w = "?";
      const c = new Mongo("localhost:27017");
      try {
        c.getDB("admin").auth("kbms_block_probe", "kbms-probe-pw");
        c.getDB("kbms_block_probe").c.insertOne({at: new Date()});
        w = "WRITABLE";
      } catch (e) { w = "BLOCKED"; }
      finally { try { c.close(); } catch (e) {} }
      try { db.getSiblingDB("kbms_block_probe").dropDatabase(); } catch (e) {}
      admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}});
      print("uwb=" + r.ok + " probe=" + w);'
  else
    printf '
      const admin = db.getSiblingDB("admin");
      try { admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}}); } catch (e) {}
      admin.runCommand({createUser: "kbms_block_probe", pwd: "kbms-probe-pw", roles: [{role: "readWrite", db: "kbms_block_probe"}]});
      // probe only: insert as the unprivileged user (readWrite cannot
      // dropDatabase, so keep any cleanup out of the probe try block)
      let w = "?"; let uwb = "-";
      for (let i = 0; i < 3 && w !== "WRITABLE"; i++) {
        const rr = db.adminCommand({setUserWriteBlockMode: 1, global: false});
        uwb = "ok:" + rr.ok;
        const c = new Mongo("localhost:27017");
        try {
          c.getDB("admin").auth("kbms_block_probe", "kbms-probe-pw");
          c.getDB("kbms_block_probe").c.insertOne({at: new Date()});
          w = "WRITABLE";
        } catch (e) { w = "BLOCKED"; if (i < 2) sleep(3000); }
        finally { try { c.close(); } catch (e) {} }
      }
      try { db.getSiblingDB("kbms_block_probe").dropDatabase(); } catch (e) {}
      admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}});
      print("uwb=" + uwb + " probe=" + w);'
  fi
}

cmd_block() {
  if [ "$SRC_MODE" != cluster ]; then
    cat <<'EOF'
block needs the source side as a KubeBlocks cluster. With a static source URI,
fence it yourself on the source primary:
  db.adminCommand({setUserWriteBlockMode: 1, global: true})
EOF
    exit 2
  fi
  local src_comp sp out
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  sp="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp" || true)"
  [ -n "$sp" ] || die "no primary pod on source"
  warn "application writes on the source will fail immediately (User writes blocked) until unblock"
  warn "privileged roles (root, restore, __system) bypass user write blocking; the commit gate still refuses to POST while any writer advances the oplog"
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "non-interactive session: add --yes to confirm"
    printf 'Type yes to continue: ' >&2
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi
  out="$(mongosh_js "$SRC_NS" "$sp" "$src_comp" "$(block_probe_js block)")"
  echo "$out" | tail -1
  echo "$out" | grep -q "uwb=1" && echo "$out" | grep -q "probe=BLOCKED" \
    || die "user write block did not engage (probe write succeeded or command failed)"
  info "source is fenced against application writes; next: commit --yes -> switch app -> unblock --yes"
}

cmd_unblock() {
  if [ "$SRC_MODE" != cluster ]; then
    cat <<'EOF'
unblock needs the source side as a KubeBlocks cluster. With a static source
URI, release it yourself on the source primary:
  db.adminCommand({setUserWriteBlockMode: 1, global: false})
EOF
    exit 2
  fi
  local src_comp sp out
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  sp="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp" || true)"
  [ -n "$sp" ] || die "no primary pod on source"
  warn "after unblocking, source and destination can diverge (the source holds stale data)"
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "non-interactive session: add --yes to confirm"
    printf 'Type yes to continue: ' >&2
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi
  out="$(mongosh_js "$SRC_NS" "$sp" "$src_comp" "$(block_probe_js unblock)")"
  echo "$out" | tail -1
  echo "$out" | grep -q "uwb=ok:1" && echo "$out" | grep -q "probe=WRITABLE" \
    || die "source is not writable after unblock (probe write failed)"
  info "source cluster is writable again"
}

# read-only check whether user writes are currently blocked (probe user is
# created and dropped; it never toggles the block state itself)
inspect_state_js() {
  printf '
    const admin = db.getSiblingDB("admin");
    let state = "unknown";
    try {
      try { admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}}); } catch (e) {}
      admin.runCommand({createUser: "kbms_block_probe", pwd: "kbms-probe-pw", roles: [{role: "readWrite", db: "kbms_block_probe"}]});
      const c = new Mongo("localhost:27017");
      try {
        c.getDB("admin").auth("kbms_block_probe", "kbms-probe-pw");
        c.getDB("kbms_block_probe").c.insertOne({at: new Date()});
        state = "OFF (cluster writable)";
      } catch (e) { state = "ON (user writes blocked)"; }
      finally { try { c.close(); } catch (e) {} }
    } catch (e) { state = "unknown (" + String(e.message || e).slice(0, 50) + ")"; }
    try { db.getSiblingDB("kbms_block_probe").dropDatabase(); } catch (e) {}
    try { admin.runCommand({dropUser: "kbms_block_probe", writeConcern: {w: "majority"}}); } catch (e) {}
    print("write block: " + state);'
}

inspect_writers_js() {
  printf '
    const seen = new Map();
    for (let k = 0; k < 4; k++) {
      const ops = db.getSiblingDB("admin").aggregate([{$currentOp: {allUsers: true}}]).toArray();
      for (const o of ops) {
        if (!o.command || !o.active) continue;
        const kind = Object.keys(o.command).filter(x => !x.startsWith("$"))[0];
        if (!["insert","update","delete","findAndModify"].includes(kind)) continue;
        const user = (o.effectiveUsers || []).map(u => u.user + "@" + (u.db || "?")).join(",") || "?";
        const app = (o.clientMetadata && o.clientMetadata.application && o.clientMetadata.application.name) || "-";
        const key = user + "|" + (o.client || "-") + "|" + (o.ns || "?");
        if (!seen.has(key)) seen.set(key, {user: user, addr: o.client || "-", app: app, ns: o.ns || "?", kind: kind, dur: o.microsecs_running || 0});
      }
      if (k < 3) sleep(1500);
    }
    print("in-flight write ops (4 samples over ~6s): " + (seen.size ? "" : "none caught"));
    for (const v of seen.values())
      print("  " + v.user + "  from " + v.addr + "  app:" + v.app + "  " + v.ns + " " + v.kind + " (" + Math.round(v.dur / 1000) + "ms)");
    if (!seen.size) print("  (bursty writers may fall between samples; check the oplog tail above/below)")'
}

inspect_activity_js() {
  printf '
    function userOps(n) {
      return db.getSiblingDB("local").oplog.rs.find({op: {$ne: "n"}}).sort({$natural: -1}).limit(n).toArray()
        .filter(e => e.ns !== "config.system.sessions" && !e.ns.startsWith("kbms_block_probe"));
    }
    function tsSecs(ts) {
      if (ts.t !== undefined) return ts.t;
      const m = ts.toString().match(/(\d+)/);
      return m ? parseInt(m[1]) : 0;
    }
    const oc1 = db.serverStatus().opcounters;
    const ts1 = (function() { const a = userOps(20); return a.length ? a[0].ts.toString() : ""; })();
    sleep(8000);
    const oc2 = db.serverStatus().opcounters;
    const recent = userOps(20).slice(0, 10);
    const ts2 = recent.length ? recent[0].ts.toString() : "";
    const r = function(k) { return ((oc2[k] - oc1[k]) / 8).toFixed(1); };
    const age = ts2 ? (Math.floor(Date.now() / 1000) - tsSecs(recent[0].ts)) : -1;
    const quiet = ts1 === ts2;
    print("write rate (8s window): insert " + r("insert") + "/s  update " + r("update") + "/s  delete " + r("delete") + "/s");
    print("oplog user ops: " + (age >= 0 ? "last " + age + "s ago" : "none") + "; window " + (quiet ? "QUIET" : "ACTIVE"));
    print("recent user ops (newest first):");
    if (!recent.length) print("  (none)");
    for (const e of recent)
      print("  " + new Date(tsSecs(e.ts) * 1000).toISOString() + "  " + e.op + "  " + e.ns);'
}

inspect_inventory_js() {
  printf '
    const skip = ["admin", "config", "local"];
    const meta = ["__mdb_internal_mongosync", "mongosync_reserved_for_internal_use"];
    const names = db.getMongo().getDBNames();
    const users = names.filter(n => !skip.includes(n) && !meta.includes(n)).sort();
    const leftovers = names.filter(n => meta.includes(n));
    print("inventory: " + (users.length ? users.length + " user db(s)" : "no user databases")
      + (leftovers.length ? "  [mongosync metadata present: " + leftovers.join(", ") + "; drop it for a fresh sync]" : ""));
    for (const n of users) {
      const d = db.getSiblingDB(n);
      const cols = d.getCollectionNames().filter(c => !c.startsWith("system.")).sort();
      if (!cols.length) { print("  " + n + ": (no collections)"); continue; }
      for (const c of cols)
        print("  " + n + "." + c + ": " + d[c].countDocuments({}) + " docs, " + d[c].getIndexes().length + " indexes");
    }'
}

cmd_inspect() {
  if [ "$INSPECT_DST" -eq 1 ] && [ -n "${DST_URI:-}" ]; then
    die "inspect --dst requires the destination as a KubeBlocks cluster (static URI: inspect it yourself)"
  fi
  if [ "$INSPECT_DST" -ne 1 ] && [ -n "${SRC_URI:-}" ]; then
    die "inspect requires auto mode (manual mode: check local.oplog.rs and \$currentOp yourself)"
  fi
  # coordinates from args on the laptop, from KBMS_* env in the release pod
  local ns cluster comp sp label out quiet
  if [ "$INSPECT_DST" -eq 1 ]; then
    ns="${DST_NS:-${KBMS_DESTINATION_NAMESPACE:-}}"
    cluster="${DST_CLUSTER:-${KBMS_DESTINATION_CLUSTER:-}}"
    label="destination"
  else
    ns="${SRC_NS:-${KBMS_SOURCE_NAMESPACE:-}}"
    cluster="${SRC_CLUSTER:-${KBMS_SOURCE_CLUSTER:-}}"
    label="source"
  fi
  [ -n "$ns" ] && [ -n "$cluster" ] \
    || die "inspect needs the $label cluster coordinates (--src-ns/--src-cluster or --dst-ns/--dst-cluster, or KBMS_* env in-pod)"
  if [ "$INSPECT_DST" -eq 1 ]; then
    comp="${KBMS_DESTINATION_COMPONENT:-$(discover_component "$ns" "$cluster")}"
  else
    comp="${KBMS_SOURCE_COMPONENT:-$(discover_component "$ns" "$cluster")}"
  fi
  sp="$(find_primary_pod "$ns" "$cluster" "$comp" || true)"
  [ -n "$sp" ] || die "no primary pod on $label cluster"
  info "inspecting $label: $ns/$cluster (primary $sp)"
  # state probe first: its createUser/dropUser ops must not pollute the
  # quiescence window below (same reasoning as running block before commit)
  out="$(mongosh_js "$ns" "$sp" "$comp" "$(inspect_state_js)")" && echo "$out"
  out="$(mongosh_js "$ns" "$sp" "$comp" "$(inspect_writers_js)")" && echo "$out"
  quiet="$(mongosh_js "$ns" "$sp" "$comp" "$(inspect_activity_js)")" && echo "$quiet"
  out="$(mongosh_js "$ns" "$sp" "$comp" "$(inspect_inventory_js)")" && echo "$out"
  if [ "$INSPECT_DST" -eq 1 ] && kc get pod "$(release_pod)" -n "$NAMESPACE" >/dev/null 2>&1; then
    info "sync: state=$(progress_field state || true) lag=$(progress_field lagTimeSeconds || true)s"
  fi
  if [ "$INSPECT_DST" -ne 1 ]; then
    if printf '%s' "$quiet" | grep -q "window QUIET"; then
      info "verdict: $label is quiet (no user writes over the 8s window)"
    else
      warn "verdict: $label is being written; stop writers (see above) before committing"
    fi
  fi
}

cmd_teardown() {
  if ! helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    info "release $NAMESPACE/$RELEASE not found (already removed)"
    return 0
  fi
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 2m \
    || die "helm uninstall failed (release $NAMESPACE/$RELEASE)"
  info "teardown done"
}

cmd_rbac() {
  [ -n "$NAMESPACE" ] || die "rbac needs --namespace"
  cat <<EOF
# Least-privilege Role/RoleBinding for kb-mongosync.
# The destination namespace needs the same Role.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kb-mongosync-operator
  namespace: $NAMESPACE
rules:
  - apiGroups: ["apps.kubeblocks.io"]
    resources: ["clusters"]
    verbs: ["get", "list"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods", "services", "secrets", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list"]
EOF
  info "helm needs its own rights to create deployments/services/secrets in $NAMESPACE"
}

cmd_run() {
  cmd_check
  cmd_deploy
  cmd_start
  WAIT_FOR="copy" cmd_wait
  cmd_status
  cat <<EOF

Next steps (each re-runnable):
  1) watch lag:      $0 ... status
  2) verify:         $0 ... verify            # best after stopping writers
  3) commit:         $0 ... commit --yes      # source write-blocked -> COMMITTED
  4) switch the app to the destination
  5) optional:       $0 ... unblock --yes
  6) cleanup:        $0 ... teardown
EOF
}

case "$SUBCMD" in
  check)      cmd_check ;;
  deploy)     cmd_deploy ;;
  render-conf) cmd_render_conf ;;
  start)      cmd_start ;;
  status)     cmd_status ;;
  wait)       cmd_wait ;;
  verify)     cmd_verify ;;
  inspect)    cmd_inspect ;;
  commit)     cmd_commit ;;
  block)      cmd_block ;;
  unblock)    cmd_unblock ;;
  teardown)   cmd_teardown ;;
  rbac)       cmd_rbac ;;
  run)        cmd_run ;;
  *)          usage; exit 1 ;;
esac
