#!/usr/bin/env bash
# verify.sh - one line per component: what is configured and healthy. Read-only.
#   ./verify.sh
set -uo pipefail
cd "$(dirname "$0")"; [ -f vars.env ] && { set -a; . ./vars.env; set +a; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
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
sv=$(oc get ogxservers.ogx.io -A --no-headers 2>/dev/null | awk 'NR==1{print $1, $2}')
if [ -z "$sv" ]; then
  echo "    not installed - skipping OGX checks"
else
  read -r ons oname <<<"$sv"; ns="${OGX_NAMESPACE:-$ons}"
  chk "OGXServer $oname exists in $ns" "oc get ogxservers.ogx.io $oname -n $ns"
  ar=$(oc get deployments.apps "$oname" -n "$ns" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [ "${ar:-0}" -ge 1 ] && ok "deployment $oname has an available replica" || bad "deployment $oname has no available replica"
  # Secret keys are checked by name only, never by value.
  pk=$(oc get secret ogx-postgres -n "$ns" -o go-template='{{range $k,$_ := .data}}{{$k}} {{end}}' 2>/dev/null)
  [[ " $pk " == *" password "* ]] && ok "secret ogx-postgres has key password" || bad "secret ogx-postgres has no key password"
  mk=$(oc get secret ogx-maas-key -n "$ns" -o go-template='{{range $k,$_ := .data}}{{$k}} {{end}}' 2>/dev/null)
  [[ " $mk " == *" apikey "* ]] && ok "secret ogx-maas-key has key apikey" || bad "secret ogx-maas-key has no key apikey"
  cm=$(oc get ogxservers.ogx.io "$oname" -n "$ns" -o jsonpath='{.spec.tls.trust.caCertificates[0].name}' 2>/dev/null)
  if [ -n "$cm" ]; then
    chk "configmap $cm exists and is labeled ogx.io/watch=true" "oc get configmap $cm -n $ns -o jsonpath='{.metadata.labels.ogx\\.io/watch}' | grep -qx true"
  else
    echo "    spec.tls.trust.caCertificates is not set"
  fi
  ev=$(oc get ogxservers.ogx.io "$oname" -n "$ns" -o jsonpath='{range .spec.workload.overrides.env[*]}{.name}{"\n"}{end}' 2>/dev/null)
  grep -qx OTEL_SERVICE_NAME <<<"$ev" && ok "env OTEL_SERVICE_NAME is set" || bad "env OTEL_SERVICE_NAME is not set"
  grep -qx PGSSLMODE <<<"$ev" && ok "env PGSSLMODE is set" || warn "env PGSSLMODE is not set - RDS refuses plaintext connections"
  if [ -n "${KEYCLOAK_ISSUER:-}" ]; then
    if kc=$(curl -skf "$KEYCLOAK_ISSUER/.well-known/openid-configuration" 2>/dev/null) && [ -n "$kc" ]; then
      grep -q '"ogx-api"' <<<"$kc" && ok "Keycloak realm advertises the ogx-api scope" || warn "Keycloak realm does not advertise the ogx-api scope - OGX tokens need it"
    else
      warn "Keycloak realm discovery at $KEYCLOAK_ISSUER/.well-known/openid-configuration failed"
    fi
  fi
fi
