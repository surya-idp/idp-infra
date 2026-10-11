#!/usr/bin/env bash
# End-to-end test of a running platform: is everything that `make up` builds really working?
#
#   make e2e            (or: tests/e2e.sh)      after `make up` has finished
#
# Read-only, except for one server-side dry run (nothing is created). Exit code 0 = every check
# passed; otherwise the failed checks are listed. It replaces the kind-era test_e2e.sh and is
# what a recovery drill ends with: `make down && make up && make e2e`.
#
# What it proves, section by section:
#   1  the cluster has its nodes, every Argo CD application is Synced and Healthy, no pod is stuck
#   2  every secret arrived from Secrets Manager (so Pod Identity works) and no ServiceAccount
#      still names an IAM role; Image Updater can log in to ECR
#   3  the flag API and Backstage run on their OWN database logins, the cache is reached over
#      TLS, and the flag API answers through the load balancer
#   4  the database master password exists in one namespace only
#   5  the admission policies are installed and reject a public image
#   6  identities: the flag API refuses a caller without a token and accepts Backstage's
#      ServiceAccount token; Backstage may read workloads but not Secrets
#   7  observability: Prometheus scrapes the services, nothing is firing, every component is up
#
# Needs: kubectl pointed at the cluster, curl, python3.
set -uo pipefail
pass=0; fail=0
ok()   { echo "  ok    $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
section() { echo; echo "== $*"; }

section "1. Cluster and Argo CD"
nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
[ "$nodes" -ge 3 ] && ok "$nodes nodes Ready" || bad "$nodes nodes Ready (expected 3)"
while read -r name sync health; do
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && ok "app $name" || bad "app $name: $sync / $health"
done < <(kubectl -n argocd get applications --no-headers 2>/dev/null | awk '{print $1,$2,$3}')
for app in aws-load-balancer-controller external-secrets kyverno db-operator monitoring-stack monitoring-loki monitoring-alloy monitoring-tempo image-updater platform-cluster feature-flag-dev idp-portal; do
  kubectl -n argocd get application "$app" >/dev/null 2>&1 || bad "app $app does not exist"
done
pending=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vc 'Running\|Completed')
[ "$pending" = "0" ] && ok "every pod Running or Completed" || { bad "$pending pods not Running:"; kubectl get pods -A --no-headers | grep -v 'Running\|Completed' | sed 's/^/          /'; }

section "2. Secrets and pod identities"
while read -r ns name status; do
  [ "$status" = "SecretSynced" ] && ok "ExternalSecret $ns/$name" || bad "ExternalSecret $ns/$name: $status"
done < <(kubectl get externalsecret -A --no-headers 2>/dev/null | awk '{print $1,$2,$6}')
annotated=$(kubectl get sa -A -o json 2>/dev/null | grep -c 'eks.amazonaws.com/role-arn')
[ "$annotated" = "0" ] && ok "no ServiceAccount names an IAM role (Pod Identity only)" || bad "$annotated ServiceAccounts still carry a role annotation"
token=$(kubectl -n argocd exec deploy/argocd-image-updater-controller -- /app/scripts/ecr-login.sh 2>/dev/null | cut -c1-4)
[ "$token" = "AWS:" ] && ok "Image Updater can log in to ECR" || bad "Image Updater ECR login failed"

section "3. Apps: own database logins, cache over TLS, reachable"
user=$(kubectl -n feature-flag-dev exec deploy/feature-flag-api -- python -c "import os,urllib.parse as u; print(u.urlparse(os.environ['DATABASE_URL']).username)" 2>/dev/null)
case "$user" in feature-flag-service-*) ok "flag API connects as its own role ($user)";; *) bad "flag API database user is '$user' (expected feature-flag-service-...)";; esac
scheme=$(kubectl -n feature-flag-dev exec deploy/feature-flag-api -- python -c "import os; print(os.environ['REDIS_URL'].split(':')[0])" 2>/dev/null)
[ "$scheme" = "rediss" ] && ok "flag API uses TLS to the cache (rediss://)" || bad "cache URL scheme is '$scheme'"
kubectl get postgres,postgresuser -A --no-headers 2>/dev/null | sed 's/^/          /'
ready=$(kubectl -n backstage get deploy idp-portal -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${ready:-0}" = "1" ] && ok "Backstage is Ready" || bad "Backstage not Ready"
ALB=$(kubectl -n feature-flag-dev get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ALB/health")
[ "$code" = "200" ] && ok "ALB -> flag API /health 200 ($ALB)" || bad "ALB -> flag API /health returned $code"

section "4. The master password lives in one namespace"
others=$(kubectl get externalsecret -A -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(sorted({i['metadata']['namespace'] for i in d['items'] for r in i['spec'].get('data',[]) if r['remoteRef']['key']=='idp/db-creds'})))")
[ "$others" = "db-operator" ] && ok "idp/db-creds is read only in db-operator" || bad "idp/db-creds is read in: $others"

section "5. Admission policies"
kubectl get validatingpolicy,imagevalidatingpolicy --no-headers 2>/dev/null | awk '{print "          "$1}'
out=$(kubectl -n feature-flag-dev run policy-probe --image=nginx --dry-run=server 2>&1)
echo "$out" | grep -qi 'kyverno.*denied' && ok "a public nginx pod is rejected: $(echo "$out" | tr '\n' ' ' | cut -c1-160)" || bad "a public nginx pod was NOT rejected: $(echo "$out" | cut -c1-160)"

section "6. Identities"
# Without a token the flag API must say 401.
alb=$(kubectl -n feature-flag-dev get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$alb/flags" 2>/dev/null)
[ "$code" = "401" ] && ok "flag API refuses a caller without a token (401)" || bad "flag API /flags without a token: HTTP $code (expected 401)"
# With Backstage's projected ServiceAccount token (audience feature-flag-api) it must say 200.
code=$(kubectl -n backstage exec deploy/idp-portal -- node -e '
const fs = require("fs");
const token = fs.readFileSync(process.env.FLAG_API_TOKEN_FILE, "utf8").trim();
fetch(process.env.FLAG_API_URL + "/flags", { headers: { Authorization: "Bearer " + token } })
  .then(r => console.log(r.status)).catch(e => console.log("error " + e.message));' 2>/dev/null | tail -1)
[ "$code" = "200" ] && ok "flag API accepts Backstage's ServiceAccount token" || bad "flag API with Backstage's ServiceAccount token: $code (expected 200)"
sa=system:serviceaccount:backstage:idp-portal
[ "$(kubectl auth can-i list pods -A --as=$sa 2>/dev/null)" = "yes" ] && ok "Backstage may read pods (Kubernetes tab)" || bad "Backstage may not list pods"
[ "$(kubectl auth can-i get secrets -A --as=$sa 2>/dev/null)" = "no" ] && ok "Backstage may not read Secrets" || bad "Backstage CAN read Secrets"
[ "$(kubectl auth can-i delete pods -A --as=$sa 2>/dev/null)" = "no" ] && ok "Backstage may not delete pods" || bad "Backstage CAN delete pods"
n=$(kubectl -n argocd get imageupdater --no-headers 2>/dev/null | wc -l)
[ "$n" -ge 2 ] && ok "$n ImageUpdaters (golden-path services and the platform's own apps)" || bad "$n ImageUpdaters (expected 2)"

section "7. Observability"
# The Prometheus image has no wget or curl, so query it through a port-forward.
kubectl -n monitoring port-forward svc/kps-prometheus 19090:9090 >/dev/null 2>&1 &
pf=$!; sleep 4
up=$(curl -s --max-time 10 'http://localhost:19090/api/v1/query' --data-urlencode 'query=up{job="monitoring/idp-services"}' | python3 -c "
import sys,json
r=json.load(sys.stdin)['data']['result']
print(sum(1 for x in r if x['value'][1]=='1'), len(r))" 2>/dev/null)
firing=$(curl -s --max-time 10 'http://localhost:19090/api/v1/alerts' | python3 -c "
import sys,json
print(' '.join(sorted({a['labels']['alertname'] for a in json.load(sys.stdin)['data']['alerts'] if a['state']=='firing' and a['labels']['alertname']!='Watchdog'})))" 2>/dev/null)
kill $pf 2>/dev/null
set -- $up
[ "${1:-0}" -ge 1 ] && [ "${1:-0}" = "${2:-x}" ] && ok "Prometheus scrapes $1 service pod(s), all up" || bad "service scrape targets up/total: ${1:-0}/${2:-0}"
[ -z "$firing" ] && ok "no alert firing (besides Watchdog)" || bad "alerts firing: $firing"
r=$(kubectl -n monitoring get statefulset alertmanager-kps-alertmanager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${r:-0}" -ge 1 ] && ok "alertmanager Ready" || bad "alertmanager not Ready"
for d in kps-grafana alert-receiver alloy; do
  r=$(kubectl -n monitoring get deploy $d -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge 1 ] && ok "$d Ready" || bad "$d not Ready"
done
for s in loki tempo; do
  r=$(kubectl -n monitoring get statefulset $s -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge 1 ] && ok "$s Ready" || bad "$s not Ready"
done

echo
echo "passed: $pass   failed: $fail"
echo "Memory per node:"; kubectl top nodes 2>/dev/null | sed 's/^/  /'
[ "$fail" = "0" ]
