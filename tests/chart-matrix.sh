#!/usr/bin/env bash
# Renders every meaningful values combination with helm template and asserts
# the resulting objects. No cluster access needed.
set -u
cd "$(dirname "$0")/.."
CHART=charts/kb-mongosync
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

render() { # render <release-ns> <--set...>
  local ns="$1"; shift
  helm template rel -n "$ns" "$CHART" "$@" >"$TMP/out.yaml" 2>"$TMP/err"
}

objs() { # one "kind namespace name" line per rendered object; a single
         # template may emit several objects (e.g. rbac.yaml range loop)
  awk '
    function emit() { printf "%s %s %s\n", k, (ns==""?"-":ns), (n==""?"-":n) }
    /^kind: / { if (k != "") emit(); k=$2; n=ns="" }
    k != "" && /^  name: /      { if (n=="") n=$2 }
    k != "" && /^  namespace: / { if (ns=="") ns=$2 }
    END { if (k != "") emit() }
  ' "$TMP/out.yaml"
}

A()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
AN() { if eval "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

SA_MODE=(--set source.namespace=src-ns --set source.cluster=mg6
         --set destination.namespace=dst-ns --set destination.cluster=mg8)
MANUAL=(--set source.uri=mongodb://u:p@a/,?replicaSet=r0
        --set destination.uri=mongodb://u:p@b/?replicaSet=r1)

echo "== c01 sa mode, all namespaces same =="
render kb-db-test --set source.namespace=kb-db-test --set source.cluster=mg6 \
  --set destination.namespace=kb-db-test --set destination.cluster=mg8 || { bad "c01 render"; }
A "c01 kinds whitelist" 'objs | sort -u | diff - <(printf "Deployment - kb-mongosync\nRole kb-db-test kb-mongosync\nRoleBinding kb-db-test kb-mongosync\nServiceAccount - kb-mongosync\n" | sort)'
A "c01 one Role only (uniq src==dst)" '[ "$(objs | grep -c "^Role ")" = 1 ]'
A "c01 RoleBinding subject ns = release ns" 'grep -A2 "kind: ServiceAccount" "$TMP/out.yaml" | grep -q "namespace: kb-db-test"'
A "c01 SA-mode env, no uri env" 'grep -q "KBMS_SOURCE_NAMESPACE" "$TMP/out.yaml" && ! grep -q "KBMS_SOURCE_URI" "$TMP/out.yaml"'
A "c01 component env omitted by default" '! grep -q "KBMS_SOURCE_COMPONENT" "$TMP/out.yaml"'
A "c01 serviceAccountName set" 'grep -q "serviceAccountName: kb-mongosync" "$TMP/out.yaml"'
A "c01 Recreate strategy" 'grep -q "type: Recreate" "$TMP/out.yaml"'
A "c01 exec probes (localhost-only API)" 'grep -c "curl -sf http://127.0.0.1" "$TMP/out.yaml" | grep -q "^2$"'
A "c01 imagePullPolicy Always" 'grep -q "imagePullPolicy: Always" "$TMP/out.yaml"'
A "c01 default image" 'grep -q "image: \"ghcr.io/zijiren233/kb-mongosync:mongosync-1.16.0\"" "$TMP/out.yaml"'
AN "c01 no Service object" 'grep -q "^kind: Service$" "$TMP/out.yaml"'
AN "c01 no conf Secret in sa mode" 'grep -q "kind: Secret" "$TMP/out.yaml"'

echo "== c02 sa mode, all three namespaces different =="
render deploy-ns "${SA_MODE[@]}" || { bad "c02 render"; }
A "c02 Roles in src and dst ns" '[ "$(objs | awk "\$1==\"Role\"{print \$2}" | sort | paste -sd, -)" = "dst-ns,src-ns" ]'
A "c02 both bindings point at release-ns SA" '[ "$(grep -c "^    namespace: deploy-ns$" "$TMP/out.yaml")" = 2 ]'
A "c02 SA only in release ns" 'objs | grep -q "^ServiceAccount - kb-mongosync$"'
A "c02 Deployment rendered" 'objs | grep -q "^Deployment - kb-mongosync$"'

echo "== c03 sa mode, release ns == source ns != destination ns =="
render src-ns --set source.namespace=src-ns --set source.cluster=mg6 \
  --set destination.namespace=dst-ns --set destination.cluster=mg8 || { bad "c03 render"; }
A "c03 Roles in src-ns and dst-ns" '[ "$(objs | awk "\$1==\"Role\"{print \$2}" | sort | paste -sd, -)" = "dst-ns,src-ns" ]'
A "c03 bindings point at src-ns SA" '[ "$(grep -c "^    namespace: src-ns$" "$TMP/out.yaml")" = 2 ]'

echo "== c04 manual mode, sa+rbac off =="
render rel-ns "${MANUAL[@]}" --set serviceAccount.create=false --set rbac.create=false || { bad "c04 render"; }
A "c04 kinds whitelist" 'objs | sort -u | diff - <(printf "Deployment - kb-mongosync\nSecret - kb-mongosync-conf\n" | sort)'
A "c04 secret stringData carries uris" 'grep -A4 "stringData" "$TMP/out.yaml" | grep -q "mongodb://u:p@a/"'
A "c04 uri env from secretKeyRef" 'grep -q "secretKeyRef" "$TMP/out.yaml" && grep -q "key: sourceUri" "$TMP/out.yaml"'
A "c04 no cluster env" '! grep -q "KBMS_SOURCE_NAMESPACE" "$TMP/out.yaml"'
A "c04 default serviceAccount (name omitted)" '! grep -q "serviceAccountName" "$TMP/out.yaml"'
AN "c04 no Role/RoleBinding" 'grep -qE "^kind: Role" "$TMP/out.yaml"'

echo "== c05 manual mode, default sa create =="
render rel-ns "${MANUAL[@]}" || { bad "c05 render"; }
A "c05 SA created and used" 'objs | grep -q "^ServiceAccount - kb-mongosync$" && grep -q "serviceAccountName: kb-mongosync" "$TMP/out.yaml"'
AN "c05 still no Roles (namespaces empty)" 'grep -qE "^kind: Role" "$TMP/out.yaml"'

echo "== c06 sa mode, external SA name =="
render rel-ns "${SA_MODE[@]}" --set serviceAccount.create=false --set serviceAccount.name=custom-sa || { bad "c06 render"; }
A "c06 no SA object" '! objs | grep -q "^ServiceAccount"'
A "c06 deployment uses custom SA" 'grep -q "serviceAccountName: custom-sa" "$TMP/out.yaml"'
A "c06 bindings target custom SA" 'grep -B1 "namespace: rel-ns" "$TMP/out.yaml" | grep -q "name: custom-sa"'

echo "== c07 sa mode, rbac off =="
render rel-ns "${SA_MODE[@]}" --set rbac.create=false || { bad "c07 render"; }
A "c07 SA created, zero Role/RoleBinding" 'objs | grep -q "^ServiceAccount" && ! objs | grep -qE "^(Role|RoleBinding)"'

echo "== c08-c11 value overrides =="
render rel-ns "${SA_MODE[@]}" --set port=27999 || { bad "c08 render"; }
A "c08 port wired through env/container/probe" '[ "$(grep -c 27999 "$TMP/out.yaml")" -ge 4 ]'
render rel-ns "${SA_MODE[@]}" --set verbosity=DEBUG || { bad "c09 render"; }
A "c09 verbosity env" 'grep -q "value: \"DEBUG\"" "$TMP/out.yaml"'
render rel-ns "${SA_MODE[@]}" --set source.component=mongodb --set destination.component=mongodb || { bad "c10 render"; }
A "c10 component envs present" 'grep -q "KBMS_SOURCE_COMPONENT" "$TMP/out.yaml" && grep -q "KBMS_DESTINATION_COMPONENT" "$TMP/out.yaml"'
render rel-ns "${SA_MODE[@]}" --set resources.limits.memory=4Gi || { bad "c11 render"; }
A "c11 resources override" 'grep -q "memory: 4Gi" "$TMP/out.yaml"'
render rel-ns "${SA_MODE[@]}" --set nameOverride=foo || { bad "c12 render"; }
A "c12 nameOverride renames all objects" '[ "$(objs | awk "\$3!=\"-\"{print \$3}" | sort -u)" = "foo" ]'

echo "== c13-c14 lint =="
if helm lint "$CHART" "${SA_MODE[@]}" >"$TMP/lint1" 2>&1; then ok "c13 lint sa mode"; else bad "c13 lint sa mode"; cat "$TMP/lint1"; fi
if helm lint "$CHART" "${MANUAL[@]}" --set serviceAccount.create=false --set rbac.create=false >"$TMP/lint2" 2>&1; then ok "c14 lint manual mode"; else bad "c14 lint manual mode"; cat "$TMP/lint2"; fi

echo "== c18-c22 hardening fields and uri validation =="
render rel-ns "${SA_MODE[@]}" || { bad "c18 render"; }
A "c18 pod securityContext (restricted PSA compatible)" 'grep -q "runAsNonRoot: true" "$TMP/out.yaml" && grep -q "runAsUser: 10001" "$TMP/out.yaml" && grep -q "type: RuntimeDefault" "$TMP/out.yaml"'
A "c18 container securityContext" 'grep -q "allowPrivilegeEscalation: false" "$TMP/out.yaml" && grep -q "drop:" "$TMP/out.yaml"'
AN "c18 no imagePullSecrets by default" 'grep -q "imagePullSecrets" "$TMP/out.yaml"'
AN "c18 no nodeSelector by default" 'grep -q "nodeSelector" "$TMP/out.yaml"'
render rel-ns "${SA_MODE[@]}" --set imagePullSecrets[0].name=regcred \
  --set 'nodeSelector.kubernetes\.io/os=linux' --set tolerations[0].operator=Exists || { bad "c19 render"; }
A "c19 imagePullSecrets rendered" 'grep -A2 "imagePullSecrets" "$TMP/out.yaml" | grep -q "name: regcred"'
A "c19 nodeSelector rendered" 'grep -A2 "nodeSelector" "$TMP/out.yaml" | grep -q "kubernetes.io/os: linux"'
A "c19 tolerations rendered" 'grep -A2 "tolerations" "$TMP/out.yaml" | grep -q "operator: Exists"'
render rel-ns "${MANUAL[@]}" || { bad "c20 render"; }
A "c20 hardening present in manual mode too" 'grep -q "runAsNonRoot: true" "$TMP/out.yaml"'
AN "c21 bad uri scheme rejected" 'render rel-ns --set source.uri=foo://x --set destination.uri=mongodb://b'
A "c21 error mentions scheme" 'grep -q "must start with mongodb://" "$TMP/err"'

echo "== c15-c17 invalid configurations must fail =="
AN "c15 one uri side without the other cluster fields rejected" 'render rel-ns --set source.uri=mongodb://a'
A "c15 error mentions the incomplete side" 'grep -q "destination needs either uri or namespace+cluster" "$TMP/err"'
AN "c16 empty config rejected" 'render rel-ns'
A "c16 error mentions the incomplete side" 'grep -q "needs either uri or namespace+cluster" "$TMP/err"'
AN "c17 sa mode missing destination cluster rejected" 'render rel-ns --set source.namespace=a --set source.cluster=x --set destination.namespace=b'

echo "== c23 hybrid: static source uri + discovered destination =="
render rel-ns --set source.uri=mongodb://u:p@a/?replicaSet=r0 \
  --set destination.namespace=dst-ns --set destination.cluster=mg8 || { bad "c23 render"; }
A "c23 source uri env from secret" 'grep -q "KBMS_SOURCE_URI" "$TMP/out.yaml" && ! grep -q "KBMS_SOURCE_NAMESPACE" "$TMP/out.yaml"'
A "c23 destination cluster env" 'grep -q "KBMS_DESTINATION_NAMESPACE" "$TMP/out.yaml" && ! grep -q "KBMS_DESTINATION_URI" "$TMP/out.yaml"'
A "c23 secret carries sourceUri only" 'grep -q "^  sourceUri:" "$TMP/out.yaml" && ! grep -q "^  destinationUri:" "$TMP/out.yaml"'
A "c23 Role only in destination ns" '[ "$(objs | awk "\$1==\"Role\"{print \$2}" | sort | paste -sd, -)" = "dst-ns" ]'

echo "== c24 hybrid: discovered source + static destination uri =="
render rel-ns --set source.namespace=src-ns --set source.cluster=mg6 \
  --set destination.uri=mongodb://u:p@b/?replicaSet=r1 || { bad "c24 render"; }
A "c24 source cluster env" 'grep -q "KBMS_SOURCE_NAMESPACE" "$TMP/out.yaml" && ! grep -q "KBMS_SOURCE_URI" "$TMP/out.yaml"'
A "c24 destination uri env from secret" 'grep -q "KBMS_DESTINATION_URI" "$TMP/out.yaml" && ! grep -q "KBMS_DESTINATION_NAMESPACE" "$TMP/out.yaml"'
A "c24 secret carries destinationUri only" 'grep -q "^  destinationUri:" "$TMP/out.yaml" && ! grep -q "^  sourceUri:" "$TMP/out.yaml"'
A "c24 Role only in source ns" '[ "$(objs | awk "\$1==\"Role\"{print \$2}" | sort | paste -sd, -)" = "src-ns" ]'

printf '\nchart-matrix: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
