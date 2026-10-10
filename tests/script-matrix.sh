#!/usr/bin/env bash
# Behavioral matrix for kb-mongosync.sh: argument validation, kubeconfig
# resolution, render-conf env handling and manual-mode gates. No cluster
# access needed; every cell runs the real script with a controlled env.
set -u
cd "$(dirname "$0")/.."
S="$PWD/kb-mongosync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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

printf '\nscript-matrix: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
