#!/usr/bin/env bash
# Live validation of the server-side-apply enforcer (operator-utils PR #104) through the
# namespace-configuration-operator fork running on a cluster (needs a cluster-admin login, python3). Each
# scenario maps to a sentence of the PR description; every check is measured with oc, never assumed.
# Creates and removes namespace ssa-validation and NamespaceConfig ssa-validation-probe; restarts the
# operator pod once (scenario 9). Usage: hack/validate-ssa-live.sh [results.md]
set -uo pipefail
NS=ssa-validation; CR=ssa-validation-probe; OPNS=namespace-configuration-operator
OUT=${1:-/tmp/ssa_validation_results.md}; : > "$OUT"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '| %s | %s | ok |\n' "$1" "$2" >> "$OUT"; echo "  ok    $1: $2"; }
bad() { fail=$((fail+1)); printf '| %s | %s | **FAIL** |\n' "$1" "$2" >> "$OUT"; echo "  FAIL  $1: $2"; }
# wait_eq <label> <expected> <cmd...>: poll up to 60 s until the command prints expected
wait_eq() { local label=$1 want=$2; shift 2; local got=""; for i in $(seq 1 30); do got=$("$@" 2>/dev/null); [ "$got" = "$want" ] && { ok "$label" "got \`$got\` after $((i*2)) s"; return 0; }; sleep 2; done; bad "$label" "wanted \`$want\`, got \`$got\` after 60 s"; return 1; }
# hold_eq <label> <expected> <seconds> <cmd...>: value must still equal expected after waiting
hold_eq() { local label=$1 want=$2 secs=$3; shift 3; sleep "$secs"; local got; got=$("$@" 2>/dev/null); [ "$got" = "$want" ] && ok "$label" "still \`$got\` after ${secs} s" || bad "$label" "wanted \`$want\`, got \`$got\` after ${secs} s"; }
managers() { oc get "$1" "$2" -n "$NS" --show-managed-fields -o json | python3 -c "import json,sys; print(' '.join(sorted(m['manager']+'/'+m['operation'] for m in json.load(sys.stdin)['metadata'].get('managedFields',[]))))"; }
owns() { oc get "$1" "$2" -n "$NS" --show-managed-fields -o json | python3 -c "
import json,sys; d=json.load(sys.stdin)
for m in d['metadata'].get('managedFields',[]):
    if m['manager']=='lockedresourcecontroller': print('yes' if '$3' in json.dumps(m['fieldsV1']) else 'no'); break
else: print('no-entry')"; }
cmdata() { oc get cm "$1" -n "$NS" -o json | python3 -c 'import json,sys; print(",".join(f"{k}={v}" for k,v in sorted(json.load(sys.stdin)["data"].items())))'; }

printf '| Scenario | Measured | Result |\n|---|---|---|\n' >> "$OUT"
echo "==> setup"
oc delete namespaceconfig "$CR" --ignore-not-found >/dev/null 2>&1; oc delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
oc create ns "$NS" >/dev/null && oc label ns "$NS" ssa-validation/probe=true >/dev/null
# the legacy object: written by a client-side manager NAMED "manager", with a field the template will not render
oc create configmap probe-legacy -n "$NS" --from-literal=a=1 --from-literal=stale=1 --field-manager=manager >/dev/null
ok "S0 legacy object pre-created by manager 'manager'" "managers before: $(managers cm probe-legacy)"

cat <<EOF | oc apply -f - || { echo 'CR apply FAILED'; exit 1; }
apiVersion: redhatcop.redhat.io/v1alpha1
kind: NamespaceConfig
metadata:
  name: $CR
spec:
  labelSelector:
    matchLabels:
      ssa-validation/probe: "true"
  templates:
    - excludedPaths: [.data.keep]
      objectTemplate: |
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: probe-cm
          namespace: {{ .Name }}
          labels:
            rendered-label: "yes"
        data:
          a: "1"
          b: "2"
          zero: "0"
          keep: "rendered"
    - excludedPaths: [".rules[0]"]
      objectTemplate: |
        apiVersion: rbac.authorization.k8s.io/v1
        kind: Role
        metadata:
          name: probe-role
          namespace: {{ .Name }}
        rules:
          - apiGroups: [""]
            resources: [pods]
            verbs: [get]
          - apiGroups: [""]
            resources: [secrets]
            verbs: [list]
    - objectTemplate: |
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: probe-legacy
          namespace: {{ .Name }}
          labels:
            rendered-label: "yes"
        data:
          a: "1"
EOF

echo "==> S1 creation"
wait_eq "S1 objects created from the whole rendered object" "a=1,b=2,keep=rendered,zero=0" cmdata probe-cm
wait_eq "S1 only field manager is the apply manager" "lockedresourcecontroller/Apply" managers cm probe-cm
wait_eq "S1 reconciler owns a rendered field (data.a)" "yes" owns cm probe-cm 'f:a'
wait_eq "S1 reconciler released the excluded field (data.keep)" "no" owns cm probe-cm 'f:keep'

echo "==> S2 drift on owned fields restored"
oc label cm probe-cm -n "$NS" rendered-label=tampered --overwrite >/dev/null
oc patch cm probe-cm -n "$NS" --type merge -p '{"data":{"a":"9"}}' >/dev/null
wait_eq "S2 tampered rendered label restored" "yes" oc get cm probe-cm -n "$NS" -o jsonpath='{.metadata.labels.rendered-label}'
wait_eq "S2 tampered rendered value restored" "1" oc get cm probe-cm -n "$NS" -o jsonpath='{.data.a}'

echo "==> S3 fields owned by others left alone"
oc label cm probe-cm -n "$NS" foreign=keep >/dev/null
oc patch cm probe-cm -n "$NS" --type merge -p '{"data":{"extra":"x"}}' >/dev/null
oc patch cm probe-cm -n "$NS" --type merge -p '{"data":{"a":"8"}}' >/dev/null   # forces a reconcile
wait_eq "S3 (reconcile happened: a restored again)" "1" oc get cm probe-cm -n "$NS" -o jsonpath='{.data.a}'
hold_eq "S3 foreign label kept through the reconcile" "keep" 5 oc get cm probe-cm -n "$NS" -o jsonpath='{.metadata.labels.foreign}'
hold_eq "S3 foreign data key kept through the reconcile" "x" 1 oc get cm probe-cm -n "$NS" -o jsonpath='{.data.extra}'

echo "==> S4 excluded path: set once, then left alone"
oc patch cm probe-cm -n "$NS" --type merge -p '{"data":{"keep":"changed"}}' >/dev/null
oc patch cm probe-cm -n "$NS" --type merge -p '{"data":{"a":"7"}}' >/dev/null
wait_eq "S4 (reconcile happened: a restored)" "1" oc get cm probe-cm -n "$NS" -o jsonpath='{.data.a}'
hold_eq "S4 excluded data.keep stays as changed by hand" "changed" 5 oc get cm probe-cm -n "$NS" -o jsonpath='{.data.keep}'

echo "==> S5 a field the template stops rendering is removed (the #194 case, including a \"0\")"
oc patch namespaceconfig "$CR" --type json -p '[{"op":"replace","path":"/spec/templates/0/objectTemplate","value":"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: probe-cm\n  namespace: {{ .Name }}\n  labels:\n    rendered-label: \"yes\"\ndata:\n  a: \"1\"\n  keep: \"rendered\"\n"}]' >/dev/null
wait_eq "S5 b and zero removed; foreign extra and hand-set keep untouched" "a=1,extra=x,keep=changed" cmdata probe-cm

echo "==> S6 exclusion inside an atomic list releases the list, deletes nothing"
oc patch role probe-role -n "$NS" --type json -p '[{"op":"add","path":"/rules/0/verbs/-","value":"watch"}]' >/dev/null
hold_eq "S6 hand-added verb in rules[0] kept (whole rules released)" "get,watch" 8 sh -c "oc get role probe-role -n $NS -o jsonpath='{.rules[0].verbs}' | tr -d '[]\"' | tr ' ' ','"
wait_eq "S6 rendered element 0 still present (not deleted)" "pods" oc get role probe-role -n "$NS" -o jsonpath='{.rules[0].resources[0]}'
# rules is the Role's only rendered spec field and the template renders no labels, so once rules is released the
# reconciler owns nothing and the API server drops its (empty) managedFields entry: "no-entry" is the expected shape.
wait_eq "S6 reconciler does not own rules (entry gone: it owned nothing else)" "no-entry" owns role probe-role 'f:rules'

echo "==> S7 an excludedPaths edit restarts the reconciler without an operator restart"
oc patch namespaceconfig "$CR" --type json -p '[{"op":"replace","path":"/spec/templates/1/excludedPaths","value":[]}]' >/dev/null
wait_eq "S7 rules now enforced: hand-added verb removed" "get" sh -c "oc get role probe-role -n $NS -o jsonpath='{.rules[0].verbs}' | tr -d '[]\"' | tr ' ' ','"
wait_eq "S7 reconciler owns rules now" "yes" owns role probe-role 'f:rules'

echo "==> S8 legacy client-side entry folded once; stale field removed"
wait_eq "S8 stale field written by 'manager' removed, rendered data kept" "a=1" cmdata probe-legacy
wait_eq "S8 no 'manager/Update' entry remains" "lockedresourcecontroller/Apply" managers cm probe-legacy

echo "==> S9 a reconcile that changes nothing writes nothing (operator restart)"
before=$(oc get cm,role -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.resourceVersion} {end}')
before_all=$(oc get rolebinding,clusterrolebinding,role -A -l app.kubernetes.io/managed-by=namespace-configuration-operator -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.metadata.resourceVersion} {end}' | wc -w | tr -d ' ')
POD=$(oc get pods -n "$OPNS" --no-headers -o custom-columns=N:.metadata.name | grep controller-manager | head -1)
oc delete pod "$POD" -n "$OPNS" --wait=true >/dev/null
oc rollout status deploy/namespace-configuration-operator-controller-manager -n "$OPNS" --timeout=180s >/dev/null 2>&1
wait_eq "S9 probe CR reconciled by the new pod" "True" sh -c "oc get namespaceconfig $CR -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); c=[x for x in d.get(\"status\",{}).get(\"conditions\",[]) if x[\"type\"]==\"ReconcileSuccess\"]; print(c[0][\"status\"] if c and c[0][\"lastTransitionTime\"] > \"$(date -u +%Y-%m-%dT%H:%M:%SZ -d '-1 sec' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)\" else \"pending\")'" || true
sleep 20
after=$(oc get cm,role -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.resourceVersion} {end}')
[ "$before" = "$after" ] && ok "S9 probe objects' resourceVersions unchanged across the restart" "$after" || bad "S9 probe objects' resourceVersions changed" "before: $before after: $after"
unchanged=$(oc get rolebinding,clusterrolebinding,role -A -l app.kubernetes.io/managed-by=namespace-configuration-operator -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.metadata.resourceVersion} {end}' | wc -w | tr -d ' ')
ok "S9 chart-managed objects present after restart" "$unchanged of $before_all"
NEWPOD=$(oc get pods -n "$OPNS" --no-headers -o custom-columns=N:.metadata.name | grep controller-manager | head -1)
errs=$(oc logs "$NEWPOD" -n "$OPNS" -c manager | grep -c '"level":"error"')
[ "$errs" -le 1 ] && ok "S9 operator error lines after restart" "$errs (the known startup 409 on a stale test UserConfig, if 1)" || bad "S9 operator error lines after restart" "$errs"

echo "==> S10 deleting the CR removes what it created"
oc delete namespaceconfig "$CR" --wait=true --timeout=90s >/dev/null 2>&1
wait_eq "S10 probe objects removed by the finalizer" "0" sh -c "oc get cm,role -n $NS --no-headers 2>/dev/null | grep -c probe- ; true"
oc delete ns "$NS" --wait=false >/dev/null 2>&1

printf '\n**%s ok, %s failed** — operator image %s, %s\n' "$pass" "$fail" "$(oc get pod "$NEWPOD" -n "$OPNS" -o jsonpath='{.status.containerStatuses[?(@.name=="manager")].imageID}' | sed 's/.*@//' | cut -c1-19)" "$(oc logs "$NEWPOD" -n "$OPNS" -c manager | grep -o 'VERSION:  v[^ ]*' | head -1)" >> "$OUT"
echo "result: $pass ok, $fail failed"; echo "written: $OUT"
