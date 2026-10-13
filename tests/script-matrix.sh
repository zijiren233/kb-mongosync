#!/usr/bin/env bash
# Behavioral matrix for kb-mongosync.sh: argument validation, kubeconfig
# resolution, render-conf env handling and manual-mode gates. No cluster
# access needed; every cell runs the real script with a controlled env.
set -u
cd "$(dirname "$0")/.."
S="$PWD/kb-mongosync.sh"
TMP="$(mktemp -d)"
MOCK_PID=""
trap 'rm -rf "$TMP"; [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
mkdir -p "$TMP/home/.kube" "$TMP/nokube"
printf 'apiVersion: v1\nkind: Config\n' >"$TMP/home/.kube/config"
DEAD_API=http://127.0.0.1:1
PASS=0 FAIL=0 RC=0 OUT=""

ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
run() { OUT="$("$@" 2>&1)"; RC=$?; }
rc_is()      { [ "$RC" = "$1" ] && ok "$2" || bad "$2 (rc=$RC want=$1; last: $(echo "$OUT" | tail -1))"; }
has()        { echo "$OUT" | grep -qE "$1" && ok "$2" || bad "$2 (missing: $1; last: $(echo "$OUT" | tail -1))"; }
hasnt()      { echo "$OUT" | grep -qE "$1" && bad "$2 (unexpected: $1)" || ok "$2"; }

CLEAN=(env -u KUBECONFIG -u KBMS_SOURCE_URI -u KBMS_DESTINATION_URI -u KBMS_SOURCE_NAMESPACE -u KBMS_SOURCE_CLUSTER -u KBMS_SOURCE_COMPONENT -u KBMS_DESTINATION_NAMESPACE -u KBMS_DESTINATION_CLUSTER -u KBMS_DESTINATION_COMPONENT -u KBMS_API_URL)

echo "== argument validation =="
run "${CLEAN[@]}" "$S" --help;                     rc_is 0 "t01 help exits 0"; has "Subcommands:" "t01 help shows usage"
run "${CLEAN[@]}" "$S";                            rc_is 1 "t02 no subcommand exits 1"; has "kb-mongosync:" "t02 usage shown"
run "${CLEAN[@]}" "$S" --bogus status;             rc_is 1 "t03 unknown option"; has "unknown option" "t03 message"
run "${CLEAN[@]}" "$S" status start;               rc_is 1 "t04 two subcommands"; has "only one subcommand" "t04 message"
run "${CLEAN[@]}" "$S" status --port;              rc_is 1 "t05 option without value"; has "requires a value" "t05 message"
run "${CLEAN[@]}" "$S" --src-ns a --src-cluster c --dst-ns b deploy; rc_is 1 "t06 dst side missing cluster"; has "destination side needs both" "t06 message"
run "${CLEAN[@]}" "$S" --src-ns a --dst-ns b --dst-cluster c deploy;      rc_is 1 "t07 source side missing cluster"; has "source side needs both" "t07 message"
run "${CLEAN[@]}" "$S" --source-uri mongodb://a deploy; rc_is 1 "t08 dst side missing entirely"; has "missing --dst-ns" "t08 message"

echo "== kubeconfig resolution =="
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/nope" status; rc_is 1 "t09 explicit missing kubeconfig"; has "kubeconfig not found" "t09 message"
run env -u KUBECONFIG HOME="$TMP/nokube" KBMS_API_URL="$DEAD_API" "$S" status
rc_is 1 "t10 in-pod without any kubeconfig reaches API"; hasnt "kubeconfig not found" "t10 no kubeconfig die"; has "progress failed|failed to parse progress|GET /api/v1/progress failed" "t10 API-level failure reported"
run env -u KUBECONFIG HOME="$TMP/home" KBMS_SOURCE_URI=mongodb://u:p@a/ KBMS_DESTINATION_URI=mongodb://u:p@b/ "$S" render-conf
rc_is 0 "t11 ambient default kubeconfig adopted silently"; has '"cluster0": "mongodb://u:p@a/"' "t11 config rendered"
run env KUBECONFIG="$TMP/home/.kube/config" KBMS_SOURCE_URI=mongodb://u:p@a/ KBMS_DESTINATION_URI=mongodb://u:p@b/ "$S" render-conf
rc_is 0 "t12 preset KUBECONFIG untouched (in-pod)"; has '"cluster1": "mongodb://u:p@b/"' "t12 config rendered"
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" status; rc_is 1 "t13 status without namespace"; has "need --namespace" "t13 message"

echo "== context default namespace for cluster sides =="
mkdir -p "$TMP/ctxns"
cat >"$TMP/ctxns/config" <<'YAML'
apiVersion: v1
kind: Config
clusters:
- cluster: {server: "http://127.0.0.1:1"}
  name: c
contexts:
- context: {cluster: c, user: u, namespace: ctx-ns}
  name: c
current-context: c
users:
- name: u
  user: {}
YAML
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/ctxns/config" --src-cluster a --dst-cluster b rbac
rc_is 0 "t33 ns-less cluster sides adopt context ns"; has "in ctx-ns" "t33 ns used"
sed "s/, namespace: ctx-ns//" "$TMP/ctxns/config" > "$TMP/ctxns/no-ns"
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/ctxns/no-ns" --src-cluster a --dst-cluster b rbac
rc_is 0 "t34 context without ns falls back to default"; has "in default" "t34 fallback ns"
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/ctxns/config" -n cli-ns --src-cluster a --dst-cluster b rbac
rc_is 0 "t34a -n overrides the context ns"; has "in cli-ns" "t34a release ns used"

echo "== check version gating via fake kubectl =="
mkdir -p "$TMP/fakebin" "$TMP/fake"
cat >"$TMP/fakebin/kubectl" <<'KEOF'
#!/usr/bin/env bash
FAKE="${FAKE_DIR:?}"
stdin_data="$(cat 2>/dev/null || true)"
args="$*"
printf '%s\n' "$args" >> "${FAKE}/kcalls"
case "$1" in
  get)
    case "$2" in
      cluster)
        if printf '%s' "$args" | grep -q "status.phase"; then echo Running; exit 0; fi
        cat "${FAKE}/cluster-$3.json" || exit 1 ;;
      pods) cat "${FAKE}/pods.json" ;;
      pod) exit 1 ;;
      secret)
        if printf '%s' "$args" | grep -q username; then echo "dXNlcg=="; else echo "cGFzcw=="; fi ;;
    esac ;;
  exec)
    js="${stdin_data} ${args}"
    printf '%s\n' "$js" >> "${FAKE}/execlog"
    case "$js" in
      *"db.version()"*)
        [ -f "${FAKE}/ver-fail" ] && exit 1
        cat "${FAKE}/live-ver" ;;
      *"isWritablePrimary"*) echo true ;;
      *"arbiterOnly"*) echo 0 ;;
      *"listCollections"*) : ;;
      *"JSON.stringify"*) echo '{"bulk":{"collections":{"load0":{"count":100,"idx":1}}}}' ;;
      *"getDBNames"*)
        if [ -f "${FAKE}/dst-nonempty" ]; then printf 'otherdb\nmeta:\n'
        else printf '\nmeta:\n'; fi ;;
    esac ;;
esac
exit 0
KEOF
chmod +x "$TMP/fakebin/kubectl"
FAKE="$TMP/fake"
mkcluster() { # name serviceVersion (empty = omit, like old KubeBlocks format)
  local sv=""
  [ -n "$2" ] && sv="\"serviceVersion\": \"$2\","
  cat >"$FAKE/cluster-$1.json" <<EOF
{"apiVersion":"apps.kubeblocks.io/v1","kind":"Cluster","metadata":{"name":"$1","namespace":"n"},"spec":{"componentSpecs":[{"name":"mongodb",$sv"componentDefRef":"mongodb","replicas":1}]},"status":{"phase":"Running"}}
EOF
}
cat >"$FAKE/pods.json" <<'EOF'
{"items":[{"metadata":{"name":"srccl-mongodb-0"},"status":{"phase":"Running"}},{"metadata":{"name":"dstcl-mongodb-0"},"status":{"phase":"Running"}}]}
EOF
printf '6.0.9' >"$FAKE/live-ver"
CK=(--kubeconfig "$TMP/home/.kube/config" --src-ns n --src-cluster srccl --dst-ns n --dst-cluster dstcl)
FE=(env PATH="$TMP/fakebin:$PATH" FAKE_DIR="$FAKE")
mkcluster srccl 6.0.9; mkcluster dstcl 8.0.4
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" check
rc_is 0 "t35 version floors delegated to mongosync (no local gate)"; has "serviceVersion=6\.0\.9" "t35 versions displayed"; has "mongosync validates cluster versions itself at /start" "t35 authority noted"
mkcluster srccl ""
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" check
rc_is 0 "t36 missing serviceVersion falls back to live query"; has "asking the server" "t36 fallback noted"; has "server reports version 6\.0\.9" "t36 live version used"; has "check passed" "t36 still passes"
touch "$FAKE/ver-fail"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" check
rc_is 0 "t37 unknown version is a warning, not a gate"; has "cannot determine source version" "t37 message"; has "mongosync validates versions at start" "t37 defers to mongosync"
rm -f "$FAKE/ver-fail"
mkcluster srccl 6.0.20
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" check
rc_is 0 "t38 compliant versions pass"; has "check passed" "t38 passed"
rm -f "$FAKE/kcalls"
run "${CLEAN[@]}" "${FE[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" -n n2 --src-cluster srccl --dst-cluster dstcl check
rc_is 0 "t38a ns-less cluster sides adopt -n"
OUT="$(grep "cluster srccl" "$FAKE/kcalls")"
has "get cluster srccl -n n2" "t38a source looked up in n2"
OUT="$(grep "cluster dstcl" "$FAKE/kcalls")"
has "get cluster dstcl -n n2" "t38a destination looked up in n2"
run "${CLEAN[@]}" "${FE[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" -n n2 --src-ns n --src-cluster srccl --dst-cluster dstcl check
rc_is 0 "t38b explicit --src-ns beats -n"
OUT="$(grep "cluster srccl" "$FAKE/kcalls")"
has "get cluster srccl -n n -o" "t38b source keeps explicit ns"
OUT="$(grep "cluster dstcl" "$FAKE/kcalls")"
has "get cluster dstcl -n n2" "t38b destination still adopts -n"
mkcluster srccl 6.0.20

echo "== deploy mongosync version selection =="
cat >"$TMP/fakebin/helm" <<'HEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DIR:?}/helm-args"
exit 0
HEOF
chmod +x "$TMP/fakebin/helm"
DEP=(--kubeconfig "$TMP/home/.kube/config" --src-ns n --src-cluster srccl --dst-ns n --dst-cluster dstcl --chart-dir "$PWD/charts/kb-mongosync")
rm -f "$FAKE/helm-args"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${DEP[@]}" --mongosync-version 1.15.0 deploy
rc_is 0 "t39 deploy with --mongosync-version"
grep -q -- "--set-string image.tag=mongosync-1.15.0" "$FAKE/helm-args" && ok "t39 tag passed to helm" || bad "t39 tag missing from helm args"
rm -f "$FAKE/helm-args"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${DEP[@]}" --mongosync-version 1.15 deploy
rc_is 0 "t40 two-component version accepted"
grep -q -- "--set-string image.tag=mongosync-1.15" "$FAKE/helm-args" && ok "t40 tag passed to helm" || bad "t40 tag missing from helm args"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${DEP[@]}" --mongosync-version abc deploy
rc_is 1 "t41 malformed version rejected"; has "must look like X.Y" "t41 message"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${DEP[@]}" --image ghcr.io/x/y:t1 --mongosync-version 1.15.0 deploy
rc_is 1 "t42 --image conflict rejected"; has "mutually exclusive" "t42 message"
run "${CLEAN[@]}" "${FE[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" --src-ns s1 --src-cluster srccl --dst-ns s2 --dst-cluster dstcl --chart-dir "$PWD/charts/kb-mongosync" deploy
rc_is 0 "t43a release ns falls back to source ns"
grep -q -- "-n s1" "$FAKE/helm-args" && ok "t43a helm got -n s1" || bad "t43a helm ns missing"
run "${CLEAN[@]}" "${FE[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" --source-uri "mongodb://u:p@a/" --dst-ns s2 --dst-cluster dstcl --chart-dir "$PWD/charts/kb-mongosync" deploy
rc_is 0 "t43b uri source: release ns falls back to destination ns"
grep -q -- "-n s2" "$FAKE/helm-args" && ok "t43b helm got -n s2" || bad "t43b helm ns missing"
run "${CLEAN[@]}" "${FE[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" --source-uri "mongodb://u:p@a/" --destination-uri "mongodb://u:p@b/" --chart-dir "$PWD/charts/kb-mongosync" deploy
rc_is 1 "t43c manual deploy without -n refused"; has "deploy needs --namespace" "t43c message"
mkcluster srccl 8.0.5; mkcluster dstcl 8.0.5
: >"$FAKE/execlog"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" verify --counts-only
rc_is 0 "t45 verify --counts-only passes"; has "counts only" "t45 mode noted"
[ "$(grep -c dbHash "$FAKE/execlog")" = "0" ] && ok "t45 no dbHash issued" || bad "t45 dbHash was issued"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" verify
rc_is 0 "t46 full verify passes"; [ "$(grep -c dbHash "$FAKE/execlog")" -ge "1" ] && ok "t46 dbHash issued once per side" || bad "t46 dbHash missing"

echo "== render-conf env matrix =="
run "${CLEAN[@]}" "$S" render-conf;                rc_is 1 "t14 no env"; has "no KBMS.* configuration" "t14 message"
run env -u KUBECONFIG KBMS_SOURCE_URI=mongodb://a "$S" render-conf; rc_is 1 "t15 dst env missing"; has "destination side needs" "t15 message"
run "${CLEAN[@]}" env KBMS_SOURCE_URI="mongodb://u:p@a/?replicaSet=r0" KBMS_DESTINATION_URI="mongodb://u:p@b/?replicaSet=r1" "$S" render-conf
rc_is 0 "t16 manual env renders"; has '"port": 27180' "t16 default port"; has '"verbosity": "INFO"' "t16 default verbosity"
run "${CLEAN[@]}" env KBMS_SOURCE_URI=mongodb://a KBMS_DESTINATION_URI=mongodb://b KBMS_PORT=2999 KBMS_VERBOSITY=TRACE "$S" render-conf
rc_is 0 "t17 env overrides honored"; has '"port": 2999' "t17 port"; has '"verbosity": "TRACE"' "t17 verbosity"
run env -u KUBECONFIG PATH=/usr/bin:/bin KBMS_SOURCE_NAMESPACE=a KBMS_SOURCE_CLUSTER=x KBMS_SOURCE_COMPONENT=mongodb KBMS_DESTINATION_NAMESPACE=b KBMS_DESTINATION_CLUSTER=y KBMS_DESTINATION_COMPONENT=mongodb "$S" render-conf
rc_is 1 "t18 sa env without kubectl fails"; hasnt '"cluster0"' "t18 no config printed"

echo "== manual-mode gates =="
URI_ARGS=(--source-uri mongodb://a --destination-uri mongodb://b)
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" verify;    rc_is 2 "t19 verify manual gate"; has "verify needs both sides" "t19 hint"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" unblock;   rc_is 2 "t20 unblock manual gate"; has "unblock needs the source side" "t20 hint"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" block;    rc_is 2 "t26 block manual gate"; has "block needs the source side" "t26 hint"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" inspect;  rc_is 1 "t27 inspect manual gate"; has "inspect requires auto mode" "t27 message"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" rbac;      rc_is 1 "t21 rbac without namespace"; has "rbac needs --namespace" "t21 message"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" check;     rc_is 1 "t22 check manual gate"; has "check requires at least one cluster side" "t22 message"

echo "== hybrid side resolution =="
run "${CLEAN[@]}" "$S" --source-uri mongodb://a --src-ns n --dst-ns b --dst-cluster c deploy
rc_is 1 "t28 source conflict rejected"; has "not both" "t28 message"
run "${CLEAN[@]}" "$S" --source-uri mongodb://a --dst-ns b --dst-cluster c deploy
rc_is 1 "t29 hybrid passes resolution (dies at dst discovery)"; has "destination component discovery failed" "t29 message"
run "${CLEAN[@]}" env KBMS_SOURCE_URI="mongodb://u:p@a/?replicaSet=r0" KBMS_DESTINATION_NAMESPACE=b KBMS_DESTINATION_CLUSTER=y KBMS_DESTINATION_COMPONENT=mongodb "$S" render-conf
rc_is 1 "t30 hybrid env: uri source accepted, dst side reaches discovery"; has "secret b/y-mongodb-account-root" "t30 dst discovery attempted"
run "${CLEAN[@]}" env KBMS_SOURCE_NAMESPACE=a KBMS_SOURCE_CLUSTER=x KBMS_SOURCE_COMPONENT=mongodb KBMS_DESTINATION_URI="mongodb://u:p@b/?replicaSet=r1" "$S" render-conf
rc_is 1 "t31 hybrid env: uri destination accepted, src side reaches discovery"; has "secret a/x-mongodb-account-root" "t31 src discovery attempted"

echo "== uri and context validation =="
run "${CLEAN[@]}" "$S" --source-uri foo://x --destination-uri mongodb://b deploy
rc_is 1 "t23 uri scheme rejected"; has "must start with mongodb://" "t23 message"
run "${CLEAN[@]}" "$S" --source-uri "mongodb://a b" --destination-uri mongodb://b deploy
rc_is 1 "t24 uri whitespace rejected"; has "whitespace" "t24 message"
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" --context nope status
rc_is 1 "t25 unknown context rejected"; has "context not found" "t25 message"

echo "== api subcommands against a mock mongosync =="
cat >"$TMP/mock.py" <<'PYEOF'
import http.server, json, os
STATE=os.environ["MOCK_STATE"]; POSTS=os.environ["MOCK_POSTS"]; NF=os.environ["MOCK_NOFLAG"]
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b=json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def _state(self):
        try:
            with open(STATE) as f: return json.load(f)
        except Exception: return {"state":"IDLE"}
    def _save(self,d):
        with open(STATE,"w") as f: json.dump(d,f)
    def do_GET(self):
        if self.path.startswith("/api/v1/progress"): self._send(200, {"progress": self._state()})
        else: self._send(404, {"error":"not found"})
    def do_POST(self):
        n=int(self.headers.get("Content-Length",0)); body=self.rfile.read(n).decode()
        with open(POSTS,"a") as f: f.write(self.path+" "+body+"\n")
        if self.path=="/api/v1/start":
            if os.path.exists(NF) and "enableUserWriteBlocking" in body:
                self._send(400, {"error":"Unrecognized key in request: enableUserWriteBlocking"}); return
            s=self._state(); s["state"]="RUNNING"; self._save(s)
        elif self.path=="/api/v1/pause":
            s=self._state(); s["state"]="PAUSED"; self._save(s)
        elif self.path=="/api/v1/resume":
            s=self._state(); s["state"]="RUNNING"; self._save(s)
        elif self.path=="/api/v1/commit":
            self._save({"state":"COMMITTED","canCommit":False,"canWrite":True,"lagTimeSeconds":0})
            self.send_response(200); self.end_headers(); self.wfile.flush(); return
        self._send(200, {"success": True})
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1",18100),H).serve_forever()
PYEOF
MOCK_STATE="$TMP/state.json" MOCK_POSTS="$TMP/posts" MOCK_NOFLAG="$TMP/noflag" python3 "$TMP/mock.py" &
MOCK_PID=$!
sleep 1
API=(--api-url http://127.0.0.1:18100)
mock_state() { printf '%s' "$1" >"$TMP/state.json"; : >"$TMP/posts"; }

mock_state '{"state":"IDLE","canCommit":false,"canWrite":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" status; rc_is 0 "m1 status parses mock"; has "state        = IDLE" "m1 idle state"
mock_state '{"state":"RUNNING","canCommit":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" start; rc_is 0 "m2 start idempotent skip"; has "start skipped" "m2 skip message"
[ -s "$TMP/posts" ] && bad "m2 no start POST while RUNNING" || ok "m2 no start POST while RUNNING"
mock_state '{"state":"IDLE","canCommit":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" start; rc_is 0 "m3 start accepted"; has "start accepted" "m3 message"
grep -q "/api/v1/start" "$TMP/posts" && grep -q "enableUserWriteBlocking" "$TMP/posts" && ok "m3 start POST issued with write blocking" || bad "m3 start POST issued"
mock_state '{"state":"IDLE","canCommit":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" start --no-write-blocking; rc_is 0 "m3b start accepted (no blocking)"
grep -q "/api/v1/start" "$TMP/posts" && ! grep -q "enableUserWriteBlocking" "$TMP/posts" && ok "m3b POST omits enableUserWriteBlocking" || bad "m3b POST body"
mock_state '{"state":"IDLE","canCommit":false}'
: >"$TMP/noflag"
run "${CLEAN[@]}" "$S" "${API[@]}" start; rc_is 0 "m15 start adapts when the flag is rejected (mongosync 1.20+)"
has "dropped enableUserWriteBlocking" "m15 adaptation noted"
[ "$(grep -c "enableUserWriteBlocking" "$TMP/posts")" = "1" ] && ok "m15 retry dropped the flag" || bad "m15 retry kept the flag"
rm -f "$TMP/noflag"
mock_state '{"state":"IDLE","canCommit":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m4 commit gated on canCommit"; has "canCommit=false" "m4 message"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":0}'
run "${CLEAN[@]}" "$S" "${API[@]}" commit </dev/null; rc_is 1 "m5 commit without --yes refused"; has "non-interactive" "m5 message"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 0 "m6 commit accepted"; has "COMMITTED" "m6 committed"
grep -q "/api/v1/commit" "$TMP/posts" && ok "m6 commit POST issued" || bad "m6 commit POST issued"
mock_state '{"state":"COMMITTED","canCommit":false,"canWrite":true}'
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for committed --timeout 5; rc_is 0 "m7 wait committed immediate"
run "${CLEAN[@]}" "$S" "${API[@]}" commit; rc_is 0 "m8 commit after COMMITTED idempotent"; has "already COMMITTED" "m8 message"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":0}'
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for copy --timeout 5; rc_is 0 "m16 wait copy completes for empty source (canCommit)"; has "collection copy complete" "m16 message"
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" pause; rc_is 0 "m17 pause issues POST when RUNNING"
grep -q "/api/v1/pause {}" "$TMP/posts" && ok "m17 pause POST issued" || bad "m17 pause POST missing"
run "${CLEAN[@]}" "$S" "${API[@]}" pause; has "pause skipped" "m17b idempotent skip reuses state"
mock_state '{"state":"PAUSED","canCommit":false,"lagTimeSeconds":0}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" resume; rc_is 0 "m18 resume issues POST when PAUSED"
grep -q "/api/v1/resume {}" "$TMP/posts" && ok "m18 resume POST issued" || bad "m18 resume POST missing"
mock_state '{"state":"IDLE","canCommit":false,"lagTimeSeconds":0}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" start --no-embedded-verify; rc_is 0 "m19 start with --no-embedded-verify"
grep -q '"verification":{"enabled":false}' "$TMP/posts" && ok "m19 verification disabled in POST" || bad "m19 verification flag missing"
mock_state '{"state":"IDLE","canCommit":false,"lagTimeSeconds":0}'
run "${CLEAN[@]}" "$S" "${API[@]}" pause; rc_is 1 "m20 pause refused when IDLE"; has "requires RUNNING" "m20 message"
mock_state '{"state":"IDLE","canCommit":false,"lagTimeSeconds":0}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" start --include-ns sales --include-ns "hr,people,org"; rc_is 0 "m21 start with namespace filters"
grep -o 'includeNamespaces.*' "$TMP/posts" | head -1 > "$TMP/m21body"
grep -q '"includeNamespaces":\[{"database": "sales"}, {"database": "hr", "collections": \["people", "org"\]}\]' "$TMP/posts" && ok "m21 filter JSON correct" || { bad "m21 filter JSON wrong: $(cat "$TMP/m21body")"; }
run "${CLEAN[@]}" "$S" "${API[@]}" start --include-ns a --exclude-ns b
rc_is 1 "m22 mixing filters rejected"; has "mutually exclusive" "m22 message"
: >"$FAKE/dst-nonempty"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" check
rc_is 1 "t47 unfiltered check rejects non-empty destination"; has "destination not empty" "t47 message"
run "${CLEAN[@]}" "${FE[@]}" "$S" "${CK[@]}" --include-ns mydb check
rc_is 0 "t47b filtered check allows non-empty destination"; has "outside the filter is allowed" "t47b note"
rm -f "$FAKE/dst-nonempty"
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for bogus; rc_is 1 "m9 unknown --for"; has "unknown --for" "m9 message"
mock_state '{"state":"RUNNING","canCommit":false,"lagTimeSeconds":5}'
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for lag --timeout 1; rc_is 1 "m10 wait timeout"; has "timed out waiting for lag" "m10 message"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":20}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m11 manual mode: nonzero lag refused"; has "static-source mode cannot prove quiescence" "m11 message"
[ -s "$TMP/posts" ] && bad "m11 no commit POST issued" || ok "m11 no commit POST issued"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":5}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m13 manual mode: nonzero lag refused (regression: v2 gate posted here)"; has "static-source mode cannot prove quiescence" "m13 message"
[ -s "$TMP/posts" ] && bad "m13 no commit POST issued" || ok "m13 no commit POST issued"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":20}'
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes --force; rc_is 0 "m12 --force overrides quiet gate"; has "manual mode" "m12 warns about manual mode"; has "COMMITTED" "m12 committed"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":0}'
: >"$TMP/posts"
run env -u KUBECONFIG KBMS_SOURCE_NAMESPACE=no-such-ns KBMS_SOURCE_CLUSTER=x "$S" "${API[@]}" commit --yes
rc_is 1 "m14 unreachable source fails closed (no silent skip)"; has "not found or access denied|cannot reach" "m14 message"
[ -s "$TMP/posts" ] && bad "m14 no commit POST issued" || ok "m14 no commit POST issued"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""

printf '\nscript-matrix: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
