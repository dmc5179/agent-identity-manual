#!/usr/bin/env bash
# trace-query.sh - print one trace as "service / span / user.id / spiffe.id", read through the Tempo
# gateway (direct queries are blocked by Tempo's NetworkPolicies). Uses a short-lived token for a
# reader service account it creates once (tracing/trace-reader).
#   ./trace-query.sh <trace-id>
set -euo pipefail
cd "$(dirname "$0")"; [ -f vars.env ] && { set -a; . ./vars.env; set +a; }
ns="${TRACING_NAMESPACE:-tracing}"; tid="${1:?usage: trace-query.sh <trace-id>}"
oc create sa trace-reader -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create clusterrolebinding trace-reader --clusterrole=tempo-agents-traces-reader \
  --serviceaccount="$ns":trace-reader --dry-run=client -o yaml | oc apply -f - >/dev/null
tok="$(oc create token trace-reader -n "$ns" --duration=10m)"
oc port-forward -n "$ns" svc/tempo-agents-gateway 18080:8080 >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null' EXIT; sleep 3
curl -sk -H "Authorization: Bearer $tok" \
  "https://localhost:18080/api/traces/v1/agents/tempo/api/traces/$tid" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for b in d.get("batches", d.get("resourceSpans", [])):
    r = {a["key"]: a["value"].get("stringValue") for a in b["resource"]["attributes"]}
    for ss in b.get("scopeSpans", []):
        for s in ss["spans"]:
            a = {x["key"]: x["value"].get("stringValue") for x in s.get("attributes", [])}
            print("%-10s %-18s %-5s user.id=%-10s spiffe.id=%s" % (r.get("service.name"), s["name"],
                  "child" if s.get("parentSpanId") else "root", a.get("user.id"), a.get("spiffe.id")))'
