#!/usr/bin/env bash
# kb-mongosync: drive mongosync to migrate MongoDB clusters managed by KubeBlocks.
# Every subcommand is idempotent; all state is derived from the cluster on each
# invocation, so any step can be safely retried or resumed.
set -Eeuo pipefail

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*" >&2; }
die()  { log "ERROR $*" >&2; exit 1; }

KB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kb-mongosync.XXXXXX")"
chmod 700 "$KB_TMP"
PF_PID=""

cleanup() {
  local rc=$?
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
  rm -rf "$KB_TMP"
  exit "$rc"
}
trap cleanup EXIT INT TERM

for _c in kubectl python3 curl nc; do
  command -v "$_c" >/dev/null 2>&1 || die "missing dependency: $_c"
done

KCTL_CFG="${KUBECONFIG:-$HOME/.kube/config}"
IMAGE=""
SRC_NS="";  SRC_CLUSTER=""
DST_NS="";  DST_CLUSTER=""
COMPONENT=""
NAME=""
API_PORT=27180
WAIT_TIMEOUT=1800
ASSUME_YES=0
FORCE=0

SUBCMD=""
WAIT_FOR="copy"

usage() {
  cat <<'EOF'
kb-mongosync —— KubeBlocks MongoDB 集群间 mongosync 迁移驱动器

全局参数:
  --kubeconfig PATH       kubeconfig（默认 $KUBECONFIG 或 ~/.kube/config）
  --image URI             工具镜像（deploy 必填，例如 ghcr.io/zijiren233/kb-mongosync:mongosync-1.16.0）
  --src-ns NS             源集群 namespace
  --src-cluster NAME      源集群名
  --dst-ns NS             目标集群 namespace
  --dst-cluster NAME      目标集群名
  --component NAME        覆盖自动发现的 component 名（默认 cluster 第一个 component）
  --name NAME             mongosync pod 名（默认 msync-<src>-to-<dst>）
  --port N                本地 API 端口起点（默认 27180，被占用时自动 +1）
  --timeout SECS          wait/commit 超时（默认 1800）
  --yes                   跳过交互确认（非交互环境必须）
  --force                 deploy 时允许替换已存在但配置不同的 pod
  -h | --help             本帮助

子命令（均可安全重复执行）:
  check     前置检查：集群 Running、版本、凭证、目标端空库
  deploy    部署/更新 mongosync pod 与配置 Secret（镜像方式，无需注入二进制）
  start     发起同步（已 RUNNING/COMMITTED 则跳过）
  status    输出同步状态摘要
  wait      等待条件：--for copy|lag|can-commit|committed
  verify    双端 counts + dbHash 一致性校验（建议 lag=0 后执行）
  commit    提交迁移：源端自动进入写阻塞 → COMMITTED → 目标端可写
  unblock   解除源端写阻塞（commit 后需要继续使用源集群时才执行）
  teardown  删除 mongosync pod 与配置 Secret
  rbac      打印本次迁移所需的最小权限 Role/RoleBinding（严格模式）
  run       check → deploy → start → wait copy → status
EOF
}

need_value() { [ $# -ge 2 ] || die "option $1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig)   need_value "$@"; KCTL_CFG="$2"; shift 2 ;;
    --image)        need_value "$@"; IMAGE="$2"; shift 2 ;;
    --src-ns)       need_value "$@"; SRC_NS="$2"; shift 2 ;;
    --src-cluster)  need_value "$@"; SRC_CLUSTER="$2"; shift 2 ;;
    --dst-ns)       need_value "$@"; DST_NS="$2"; shift 2 ;;
    --dst-cluster)  need_value "$@"; DST_CLUSTER="$2"; shift 2 ;;
    --component)    need_value "$@"; COMPONENT="$2"; shift 2 ;;
    --name)         need_value "$@"; NAME="$2"; shift 2 ;;
    --port)         need_value "$@"; API_PORT="$2"; shift 2 ;;
    --timeout)      need_value "$@"; WAIT_TIMEOUT="$2"; shift 2 ;;
    --for)          need_value "$@"; WAIT_FOR="$2"; shift 2 ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1 (see --help)" ;;
    *)              [ -z "$SUBCMD" ] || die "only one subcommand allowed: '$SUBCMD' and '$1'"
                    SUBCMD="$1"; shift ;;
  esac
done

[ -n "$SUBCMD" ] || { usage; exit 1; }
[ -f "$KCTL_CFG" ] || die "kubeconfig not found: $KCTL_CFG"
export KUBECONFIG="$KCTL_CFG"

kc() { kubectl "$@"; }

# Run a read-only probe; empty output on failure instead of aborting.
kc_never_fails() { "$@" 2>/dev/null || true; }

require_migration_args() {
  [ -n "$SRC_NS" ]     || die "missing --src-ns"
  [ -n "$SRC_CLUSTER" ]|| die "missing --src-cluster"
  [ -n "$DST_NS" ]     || die "missing --dst-ns"
  [ -n "$DST_CLUSTER" ]|| die "missing --dst-cluster"
  [ -n "$NAME" ] || NAME="msync-${SRC_CLUSTER}-to-${DST_CLUSTER}"
  case "$SUBCMD" in deploy) [ -n "$IMAGE" ] || die "deploy requires --image";; esac
}

load_cluster() { # ns name
  local out
  if ! out="$(kc get cluster "$2" -n "$1" -o json 2>/dev/null)"; then
    die "cluster $1/$2 not found or access denied (check KB / RBAC)"
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

component_pods() { # ns cluster component -> Running pods sorted by ordinal
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

# JS is piped via stdin so credentials stay in pod env and no quoting leaks.
mongosh_js() { # ns pod component js
  printf '%s' "$4" | kc exec -i "$2" -n "$1" -c "$3" -- \
    sh -c 'mongosh --quiet -u "$MONGODB_ROOT_USER" -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$(cat)"' \
    || die "mongosh failed on pod $2"
}

read_secret() { # ns secret key
  kc_never_fails kc get secret "$2" -n "$1" -o jsonpath="{.data.$3}" | base64 -d
}

uri_safe() { echo "$1" | grep -qE '^[A-Za-z0-9._~-]+$'; }

build_uri() { # ns cluster component -> mongodb://user:pass@seed1,seed2.../?replicaSet=rs
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

PF_LOCAL_PORT=""

pf_up() {
  [ -n "$PF_LOCAL_PORT" ] && return 0
  local p="$API_PORT" tried=0 i
  while [ $tried -lt 10 ]; do
    if ! nc -z 127.0.0.1 "$p" 2>/dev/null; then
      kc port-forward --address 127.0.0.1 -n "$SRC_NS" pod/"$NAME" "${p}:27180" \
        >/dev/null 2>"$KB_TMP/pf.err" &
      PF_PID=$!
      for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        if curl -s --max-time 3 "http://127.0.0.1:${p}/api/v1/progress" >/dev/null 2>&1; then
          PF_LOCAL_PORT="$p"
          info "port-forward ready: 127.0.0.1:${p} -> ${SRC_NS}/${NAME}:27180"
          return 0
        fi
        kill -0 "$PF_PID" 2>/dev/null || break
      done
      kill "$PF_PID" 2>/dev/null || true
      PF_PID=""
    fi
    p=$((p+1)); tried=$((tried+1))
  done
  die "port-forward failed (pod not ready or all ports busy); check: kubectl logs -n $SRC_NS $NAME"
}

api_get_progress() {
  pf_up
  curl -s --max-time 15 "http://127.0.0.1:${PF_LOCAL_PORT}/api/v1/progress" \
    || die "GET /api/v1/progress failed"
}

api_post() { # path body
  pf_up
  curl -s --max-time 300 -X POST "http://127.0.0.1:${PF_LOCAL_PORT}$1" \
    -H 'Content-Type: application/json' -d "$2" \
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

cmd_check() {
  require_migration_args
  local fail=0 src_comp dst_comp src_phase dst_phase src_ver dst_ver dbs dst_primary
  src_phase="$(cluster_phase "$SRC_NS" "$SRC_CLUSTER")"
  dst_phase="$(cluster_phase "$DST_NS" "$DST_CLUSTER")"
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")"
  COMPONENT="$src_comp"

  [ "$src_phase" = "Running" ] || { warn "source cluster phase=$src_phase (need Running)"; fail=1; }
  [ "$dst_phase" = "Running" ] || { warn "destination cluster phase=$dst_phase (need Running)"; fail=1; }

  src_ver="$(load_cluster "$SRC_NS" "$SRC_CLUSTER" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(d["spec"]["componentSpecs"][0].get("serviceVersion",""))')"
  dst_ver="$(load_cluster "$DST_NS" "$DST_CLUSTER" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(d["spec"]["componentSpecs"][0].get("serviceVersion",""))')"
  info "source:      $SRC_NS/$SRC_CLUSTER component=$src_comp serviceVersion=$src_ver"
  info "destination: $DST_NS/$DST_CLUSTER component=$dst_comp serviceVersion=$dst_ver"

  case "$(python3 -c '
import sys
def v(x):
    try: return tuple(int(i) for i in x.split(".")[:3])
    except Exception: return (0,0,0)
s, d = v(sys.argv[1]), v(sys.argv[2])
if s < (6,0,0): print("bad-src")
elif not ((7,0,0) <= d): print("bad-dst")
else: print("ok")' "$src_ver" "$dst_ver")" in
    ok)       : ;;
    bad-src)  warn "mongosync requires source >= 6.0 (got $src_ver)"; fail=1 ;;
    bad-dst)  warn "mongosync requires destination 7.0/8.0 (got $dst_ver)"; fail=1 ;;
    *)        warn "unparseable version (src=$src_ver dst=$dst_ver)"; fail=1 ;;
  esac
  info "note: src 6.0.20 + dst 8.0.4 => max usable mongosync is 1.16.0 (1.17+ needs src >= 6.0.24)"

  dst_primary="$(find_primary_pod "$DST_NS" "$DST_CLUSTER" "$dst_comp")"
  if [ -z "$dst_primary" ]; then
    warn "no primary pod found on destination cluster"
    fail=1
  else
    dbs="$(mongosh_js "$DST_NS" "$dst_primary" "$dst_comp" '
      print(db.getMongo().getDBNames().filter(n =>
        !["admin","config","local","__mdb_internal_mongosync","mongosync_reserved_for_internal_use"].includes(n)).join(","))')"
    if [ -n "$dbs" ]; then
      warn "destination not empty (user dbs: $dbs); full sync requires an empty destination"
      fail=1
    else
      info "destination is empty"
    fi
  fi

  build_uri "$SRC_NS" "$SRC_CLUSTER" "$src_comp" >/dev/null \
    && info "source credentials ok (${SRC_NS}, ${SRC_CLUSTER}-...-account-root)" \
    || { warn "failed to read source credentials"; fail=1; }
  build_uri "$DST_NS" "$DST_CLUSTER" "$dst_comp" >/dev/null \
    && info "destination credentials ok (${DST_NS}, ${DST_CLUSTER}-...-account-root)" \
    || { warn "failed to read destination credentials"; fail=1; }

  [ "$fail" -eq 0 ] && info "check passed" || die "check failed (see warnings above)"
}

cmd_deploy() {
  require_migration_args
  [ -n "$IMAGE" ] || die "deploy requires --image"
  local src_comp dst_comp secret_name="${NAME}-conf" existing cur_image
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")"

  info "building mongosync config (credentials go through a Secret, never logs)"
  {
    printf '{\n'
    printf '  "cluster0": "%s",\n' "$(build_uri "$SRC_NS" "$SRC_CLUSTER" "$src_comp")"
    printf '  "cluster1": "%s",\n' "$(build_uri "$DST_NS" "$DST_CLUSTER" "$dst_comp")"
    printf '  "port": 27180,\n  "verbosity": "INFO",\n  "disableTelemetry": true\n}\n'
  } > "$KB_TMP/conf.json"
  chmod 600 "$KB_TMP/conf.json"

  existing="$(kc_never_fails kc get secret "$secret_name" -n "$SRC_NS" -o jsonpath='{.data.conf\.json}' | base64 -d)"
  if [ "$existing" = "$(cat "$KB_TMP/conf.json")" ]; then
    info "config Secret already up to date, skipping"
  else
    if kc get secret "$secret_name" -n "$SRC_NS" >/dev/null 2>&1; then
      info "config changed, replacing Secret (running pod needs teardown + deploy to pick it up)"
      kc delete secret "$secret_name" -n "$SRC_NS" >/dev/null
    fi
    kc create secret generic "$secret_name" -n "$SRC_NS" \
      --from-file=conf.json="$KB_TMP/conf.json" >/dev/null \
      || die "failed to create config Secret"
    info "config Secret created: $SRC_NS/$secret_name"
  fi

  if kc get pod "$NAME" -n "$SRC_NS" >/dev/null 2>&1; then
    cur_image="$(kc_never_fails kc get pod "$NAME" -n "$SRC_NS" -o jsonpath='{.spec.containers[0].image}')"
    if [ "$cur_image" = "$IMAGE" ]; then
      info "pod already exists with same image, skipping (teardown first to recreate)"
      kc wait "pod/$NAME" -n "$SRC_NS" --for=condition=Ready --timeout=180s >/dev/null \
        || warn "pod exists but not Ready; kubectl describe pod -n $SRC_NS $NAME"
      return 0
    fi
    if [ "$FORCE" -eq 1 ]; then
      warn "pod image differs ($cur_image -> $IMAGE), --force replacing"
      kc delete pod "$NAME" -n "$SRC_NS" >/dev/null
    else
      die "pod exists with a different image ($cur_image); add --force to replace"
    fi
  fi

  info "deploying mongosync pod (image $IMAGE)"
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $NAME
  namespace: $SRC_NS
  labels:
    app: $NAME
    kb-mongosync/source: $SRC_CLUSTER
    kb-mongosync/destination: $DST_CLUSTER
spec:
  containers:
    - name: mongosync
      image: $IMAGE
      args: ["--config", "/etc/mongosync/conf.json", "--acceptDisclaimer"]
      ports:
        - containerPort: 27180
          name: api
      readinessProbe:
        httpGet: {path: /api/v1/progress, port: api}
        periodSeconds: 5
        failureThreshold: 60
      resources:
        limits: {cpu: "1", memory: 2Gi}
        requests: {cpu: 200m, memory: 512Mi}
      volumeMounts:
        - name: conf
          mountPath: /etc/mongosync
          readOnly: true
  volumes:
    - name: conf
      secret: {secretName: $secret_name}
EOF
  kc wait "pod/$NAME" -n "$SRC_NS" --for=condition=Ready --timeout=300s >/dev/null \
    || die "pod not Ready; check kubectl logs -n $SRC_NS $NAME"
  info "deploy done: $SRC_NS/$NAME"
}

cmd_start() {
  require_migration_args
  local state resp
  state="$(progress_field state)"
  case "$state" in
    RUNNING|COMMITTING|COMMITTED)
      info "state=$state already, start skipped (idempotent)"; return 0 ;;
    IDLE|"") : ;;
    *)
      warn "state=$state (not IDLE), refusing to start; inspect with status"
      return 1 ;;
  esac
  info "POST /api/v1/start {source: cluster0 -> destination: cluster1}"
  resp="$(api_post /api/v1/start '{"source":"cluster0","destination":"cluster1"}')"
  printf '%s' "$resp" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("success"):
    print("[start] accepted")
else:
    print("[start] FAILED:", d.get("error"), "-", d.get("errorDescription"), file=sys.stderr)
    sys.exit(1)'
  info "start accepted; watch with status/wait (copy phase then incremental lag)"
}

cmd_status() {
  require_migration_args
  if ! kc get pod "$NAME" -n "$SRC_NS" >/dev/null 2>&1; then
    die "pod $SRC_NS/$NAME not found, run deploy first"
  fi
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
  require_migration_args
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
    [ "$state" = "ERROR" ] && die "mongosync state=ERROR, aborting wait (kubectl logs -n $SRC_NS $NAME)"
    sleep 10
  done
  die "timed out waiting for $WAIT_FOR (${WAIT_TIMEOUT}s)"
}

cmd_verify() {
  require_migration_args
  local src_comp dst_comp sp dp out6 out8
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER")"
  if kc get pod "$NAME" -n "$SRC_NS" >/dev/null 2>&1; then
    local lag; lag="$(progress_field lagTimeSeconds)"
    [ "$lag" = "0" ] || warn "lag=${lag:-n/a}s (results may drift while source is written; rerun after stopping writers)"
  else
    warn "mongosync pod not found, skipping lag check (offline comparison only)"
  fi
  sp="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp")"
  dp="$(find_primary_pod "$DST_NS" "$DST_CLUSTER" "$dst_comp")"
  [ -n "$sp" ] || die "no primary pod on source"
  [ -n "$dp" ] || die "no primary pod on destination"
  local js='
    const skip = ["admin","config","local","__mdb_internal_mongosync","mongosync_reserved_for_internal_use"];
    const out = {};
    for (const dbName of db.getMongo().getDBNames()) {
      if (skip.includes(dbName)) continue;
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

cmd_commit() {
  require_migration_args
  local state can_commit deadline
  state="$(progress_field state)"
  if [ "$state" = "COMMITTED" ]; then
    info "already COMMITTED (idempotent); run the unblock subcommand to make the source writable again"
    return 0
  fi
  can_commit="$(progress_field canCommit)"
  [ "$can_commit" = "True" ] || die "canCommit=false (state=$state); run wait --for can-commit first"
  cat >&2 <<EOF

About to commit the migration (POST /api/v1/commit). Notes:
  1. mongosync immediately enables user write-block on the SOURCE cluster.
     During the COMMITTING window (usually seconds, minutes at high lag)
     writes to the source will fail. Stop or degrade write traffic first
     if the workload cannot tolerate write errors.
  2. After COMMITTED the destination is writable (canWrite=true) and the
     source stays write-blocked until you run the unblock subcommand.
  3. Commit is final (reverse is only possible before commit).

EOF
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "non-interactive session: add --yes to confirm"
    printf 'Type yes to continue: ' >&2
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi
  info "POST /api/v1/commit"
  api_post /api/v1/commit '{ }' | python3 -c '
import json,sys
d=json.load(sys.stdin)
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
      ERROR) die "commit failed (kubectl logs -n $SRC_NS $NAME)" ;;
    esac
    sleep 5
  done
  die "timed out waiting for COMMITTED (${WAIT_TIMEOUT}s)"
}

cmd_unblock() {
  require_migration_args
  local src_comp sp
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER")"
  sp="$(find_primary_pod "$SRC_NS" "$SRC_CLUSTER" "$src_comp")"
  [ -n "$sp" ] || die "no primary pod on source"
  warn "after unblocking, source and destination can diverge (the source holds stale data). Only unblock for archive/rollback use."
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "non-interactive session: add --yes to confirm"
    printf 'Type yes to continue: ' >&2
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi
  mongosh_js "$SRC_NS" "$sp" "$src_comp" \
    'print("setUserWriteBlockMode ok=" + db.adminCommand({setUserWriteBlockMode: 1, global: false}).ok)'
  info "source cluster is writable again"
}

cmd_teardown() {
  require_migration_args
  kc delete pod "$NAME" -n "$SRC_NS" --ignore-not-found >/dev/null
  kc delete secret "${NAME}-conf" -n "$SRC_NS" --ignore-not-found >/dev/null
  info "teardown done (idempotent)"
}

cmd_rbac() {
  require_migration_args
  local src_comp dst_comp
  src_comp="$(discover_component "$SRC_NS" "$SRC_CLUSTER" 2>/dev/null || echo "<component>")" || src_comp="<component>"
  dst_comp="$(discover_component "$DST_NS" "$DST_CLUSTER" 2>/dev/null || echo "<component>")" || dst_comp="<component>"
  cat <<EOF
# Generated by "kb-mongosync rbac" - least-privilege Role/RoleBinding.
# Apply with: kubectl apply -f <file>
# Cross-namespace migration: the destination namespace needs the same Role.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kb-mongosync-operator
  namespace: $SRC_NS
rules:
  - apiGroups: ["apps.kubeblocks.io"]
    resources: ["clusters"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/portforward"]
    verbs: ["create", "get"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kb-mongosync-operator
  namespace: $SRC_NS
subjects:
  - kind: User
    name: <kc-user>          # see: kubectl auth whoami
roleRef:
  kind: Role
  name: kb-mongosync-operator
  apiGroup: rbac.authorization.k8s.io
EOF
  [ "$SRC_NS" = "$DST_NS" ] || printf '\n# Duplicate the Role/RoleBinding above in namespace %s (destination).\n' "$DST_NS"
  info "source ns: $SRC_NS (component $src_comp), destination ns: $DST_NS (component $dst_comp)"
}

cmd_run() {
  cmd_check
  cmd_deploy
  cmd_start
  WAIT_FOR="copy" cmd_wait
  cmd_status
  cat <<EOF

Next steps (each re-runnable):
  1) watch incremental lag:  $0 ... status
  2) consistency check:      $0 ... verify            # best after stopping writers
  3) commit the migration:   $0 ... commit --yes      # source auto write-blocked -> COMMITTED
  4) switch the app connection string to the destination
  5) optional, re-enable source writes: $0 ... unblock --yes
  6) cleanup:                $0 ... teardown
EOF
}

case "$SUBCMD" in
  check)    cmd_check ;;
  deploy)   cmd_deploy ;;
  start)    cmd_start ;;
  status)   cmd_status ;;
  wait)     cmd_wait ;;
  verify)   cmd_verify ;;
  commit)   cmd_commit ;;
  unblock)  cmd_unblock ;;
  teardown) cmd_teardown ;;
  rbac)     cmd_rbac ;;
  run)      cmd_run ;;
  *)        usage; exit 1 ;;
esac
