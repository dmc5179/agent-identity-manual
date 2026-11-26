#!/usr/bin/env bash
# verify.sh - one line per component: what is configured and healthy. Read-only.
#   ./verify.sh
set -uo pipefail
cd "$(dirname "$0")"; [ -f vars.env ] && { set -a; . ./vars.env; set +a; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "ZTWIM / SPIRE"
chk "ZeroTrustWorkloadIdentityManager cluster exists" "oc get zerotrustworkloadidentitymanagers.operator.openshift.io cluster"
td=$(oc get zerotrustworkloadidentitymanagers.operator.openshift.io cluster -o jsonpath='{.spec.trustDomain}' 2>/dev/null); echo "    trust domain: ${td:-?}"
chk "spire-server running" "oc get pod spire-server-0 -n zero-trust-workload-identity-manager -o jsonpath='{.status.phase}' | grep -q Running"
na=$(oc get pods -n zero-trust-workload-identity-manager --no-headers 2>/dev/null | grep -c '^spire-agent.*Running'); nn=$(oc get nodes --no-headers | wc -l)
[ "$na" -eq "$nn" ] && ok "spire-agent on every node ($na/$nn)" || bad "spire-agent on $na of $nn nodes (tolerations?)"
iss=$(oc get spireservers.operator.openshift.io cluster -o jsonpath='{.spec.jwtIssuer}' 2>/dev/null)
chk "OIDC discovery answers at ${iss:-?}" "curl -skf ${iss}/.well-known/openid-configuration"
st=$(oc get clusterspiffeids.spire.spiffe.io agents -o jsonpath='{.status.stats.podsSelected}/{.status.stats.entryFailures}' 2>/dev/null); echo "    ClusterSPIFFEID agents: pods selected / failures = ${st:-not created}"

echo "Sign-in"
at=$(oc get authentications.config.openshift.io cluster -o jsonpath='{.spec.type}'); echo "    OpenShift authentication type: ${at:-IntegratedOAuth}"
oi=$(oc get gatewayconfigs.services.platform.opendatahub.io default-gateway -o jsonpath='{.spec.oidc.issuerURL} cookie.refresh={.spec.cookie.refresh}' 2>/dev/null); echo "    RHOAI gateway OIDC: ${oi:-not set}"

echo "Tracing"
chk "TempoStack agents Ready" "oc get tempostacks.tempo.grafana.com agents -n ${TRACING_NAMESPACE:-tracing} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
chk "OpenTelemetry collector running" "oc get deploy otel-collector -n ${TRACING_NAMESPACE:-tracing} -o jsonpath='{.status.readyReplicas}' | grep -q 1"
chk "Tracing UI plugin Available" "oc get uiplugins.observability.openshift.io distributed-tracing -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"

echo "MCP gateway (optional)"
url="${MCP_URL:-http://mcp-gateway-openshift-default.openshift-ingress.svc.cluster.local:8080/mcp}"
host="${MCP_HOST:-mcp.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
if [ "$(oc get mcpgatewayextensions.mcp.kuadrant.io -A --no-headers 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "    not installed"
else
  st=$(oc get mcpserverregistrations.mcp.kuadrant.io -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
  echo "    MCPServerRegistrations: $(grep -c . <<<"$st" || true), Ready: $(grep -c '^True$' <<<"$st" || true)"
  echo "    gateway $url (Host $host) is an in-cluster URL, not reachable from this workstation"
fi

echo "OGX"
oc get ogxservers.ogx.io -A --no-headers 2>/dev/null | awk '{print "    "$1"/"$2" "$3}' || true
