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
run "${CLEAN[@]}" "$S" --src-cluster a --dst-ns b --dst-cluster c deploy; rc_is 1 "t06 auto mode missing --src-ns"; has "missing --src-ns" "t06 message"
run "${CLEAN[@]}" "$S" --src-ns a --dst-ns b --dst-cluster c deploy;      rc_is 1 "t07 auto mode missing --src-cluster"; has "missing --src-cluster" "t07 message"
run "${CLEAN[@]}" "$S" --source-uri mongodb://a deploy; rc_is 1 "t08 half manual uris"; has "manual mode needs both" "t08 message"

echo "== kubeconfig resolution =="
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/nope" status; rc_is 1 "t09 explicit missing kubeconfig"; has "kubeconfig not found" "t09 message"
run env -u KUBECONFIG HOME="$TMP/nokube" KBMS_API_URL="$DEAD_API" "$S" status
rc_is 1 "t10 in-pod without any kubeconfig reaches API"; hasnt "kubeconfig not found" "t10 no kubeconfig die"; has "progress failed|failed to parse progress|GET /api/v1/progress failed" "t10 API-level failure reported"
run env -u KUBECONFIG HOME="$TMP/home" KBMS_SOURCE_URI=mongodb://u:p@a/ KBMS_DESTINATION_URI=mongodb://u:p@b/ "$S" render-conf
rc_is 0 "t11 ambient default kubeconfig adopted silently"; has '"cluster0": "mongodb://u:p@a/"' "t11 config rendered"
run env KUBECONFIG="$TMP/home/.kube/config" KBMS_SOURCE_URI=mongodb://u:p@a/ KBMS_DESTINATION_URI=mongodb://u:p@b/ "$S" render-conf
rc_is 0 "t12 preset KUBECONFIG untouched (in-pod)"; has '"cluster1": "mongodb://u:p@b/"' "t12 config rendered"
run "${CLEAN[@]}" "$S" --kubeconfig "$TMP/home/.kube/config" status; rc_is 1 "t13 status without namespace"; has "need --namespace" "t13 message"

echo "== render-conf env matrix =="
run "${CLEAN[@]}" "$S" render-conf;                rc_is 1 "t14 no env"; has "no KBMS.* configuration" "t14 message"
run env -u KUBECONFIG KBMS_SOURCE_URI=mongodb://a "$S" render-conf; rc_is 1 "t15 half uri env"; has "needs both KBMS_SOURCE_URI" "t15 message"
run "${CLEAN[@]}" env KBMS_SOURCE_URI="mongodb://u:p@a/?replicaSet=r0" KBMS_DESTINATION_URI="mongodb://u:p@b/?replicaSet=r1" "$S" render-conf
rc_is 0 "t16 manual env renders"; has '"port": 27180' "t16 default port"; has '"verbosity": "INFO"' "t16 default verbosity"
run "${CLEAN[@]}" env KBMS_SOURCE_URI=mongodb://a KBMS_DESTINATION_URI=mongodb://b KBMS_PORT=2999 KBMS_VERBOSITY=TRACE "$S" render-conf
rc_is 0 "t17 env overrides honored"; has '"port": 2999' "t17 port"; has '"verbosity": "TRACE"' "t17 verbosity"
run env -u KUBECONFIG PATH=/usr/bin:/bin KBMS_SOURCE_NAMESPACE=a KBMS_SOURCE_CLUSTER=x KBMS_SOURCE_COMPONENT=mongodb KBMS_DESTINATION_NAMESPACE=b KBMS_DESTINATION_CLUSTER=y KBMS_DESTINATION_COMPONENT=mongodb "$S" render-conf
rc_is 1 "t18 sa env without kubectl fails"; hasnt '"cluster0"' "t18 no config printed"

echo "== manual-mode gates =="
URI_ARGS=(--source-uri mongodb://a --destination-uri mongodb://b)
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" verify;    rc_is 2 "t19 verify manual gate"; has "verify needs auto mode" "t19 hint"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" unblock;   rc_is 2 "t20 unblock manual gate"; has "unblock needs auto mode" "t20 hint"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" rbac;      rc_is 1 "t21 rbac manual gate"; has "rbac requires auto mode" "t21 message"
run "${CLEAN[@]}" "$S" "${URI_ARGS[@]}" check;     rc_is 1 "t22 check manual gate"; has "check requires auto mode" "t22 message"

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
STATE=os.environ["MOCK_STATE"]; POSTS=os.environ["MOCK_POSTS"]
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
            s=self._state(); s["state"]="RUNNING"; self._save(s)
        elif self.path=="/api/v1/commit":
            self._save({"state":"COMMITTED","canCommit":False,"canWrite":True,"lagTimeSeconds":0})
        self._send(200, {"success": True})
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1",18100),H).serve_forever()
PYEOF
MOCK_STATE="$TMP/state.json" MOCK_POSTS="$TMP/posts" python3 "$TMP/mock.py" &
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
grep -q "/api/v1/start" "$TMP/posts" && ok "m3 start POST issued" || bad "m3 start POST issued"
mock_state '{"state":"IDLE","canCommit":false}'
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m4 commit gated on canCommit"; has "canCommit=false" "m4 message"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":0}'
run "${CLEAN[@]}" "$S" "${API[@]}" commit </dev/null; rc_is 1 "m5 commit without --yes refused"; has "non-interactive" "m5 message"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 0 "m6 commit accepted"; has "COMMITTED" "m6 committed"
grep -q "/api/v1/commit" "$TMP/posts" && ok "m6 commit POST issued" || bad "m6 commit POST issued"
mock_state '{"state":"COMMITTED","canCommit":false,"canWrite":true}'
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for committed --timeout 5; rc_is 0 "m7 wait committed immediate"
run "${CLEAN[@]}" "$S" "${API[@]}" commit; rc_is 0 "m8 commit after COMMITTED idempotent"; has "already COMMITTED" "m8 message"
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for bogus; rc_is 1 "m9 unknown --for"; has "unknown --for" "m9 message"
mock_state '{"state":"RUNNING","canCommit":false,"lagTimeSeconds":5}'
run "${CLEAN[@]}" "$S" "${API[@]}" wait --for lag --timeout 1; rc_is 1 "m10 wait timeout"; has "timed out waiting for lag" "m10 message"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":20}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m11 commit refused while source not quiet"; has "source not quiet" "m11 message"
[ -s "$TMP/posts" ] && bad "m11 no commit POST issued" || ok "m11 no commit POST issued"
mock_state '{"state":"RUNNING","canCommit":true,"lagTimeSeconds":5}'
: >"$TMP/posts"
run "${CLEAN[@]}" "$S" "${API[@]}" commit --yes; rc_is 1 "m13 manual mode: nonzero lag refused (regression: v2 gate posted here)"; has "manual mode: lag was not 0" "m13 message"
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
