#!/usr/bin/env bash
# ogx-trace-check.sh - check one demo trace against every expectation TRACE-FORMAT.md's OGX
# sections list, and print PASS or FAIL for each. Read through the Tempo gateway, the same way
# trace-query.sh reads a trace (short-lived token for the trace-reader service account).
#   ./ogx-trace-check.sh [--ogx-mcp] <trace-id>
# --ogx-mcp adds the list_mcp_tools and invoke_mcp_tool checks; pass it when the demo run used
# demo-trace.sh's --ogx-mcp. User identity on OGX spans is reported as INFO either way:
# TRACE-FORMAT.md documents that OGX adds none.
set -euo pipefail
cd "$(dirname "$0")"; [ -f vars.env ] && { set -a; . ./vars.env; set +a; }
OGX_MCP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ogx-mcp) OGX_MCP=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) tid="$1"; shift ;;
  esac
done
tid="${tid:-}"; [ -n "$tid" ] || { sed -n '2,9p' "$0"; exit 2; }

ns="${TRACING_NAMESPACE:-tracing}"

read -r -d '' CHECK_PY <<'PY' || true
import json, os, sys

def val(v):
    for k in ("stringValue", "intValue", "boolValue", "doubleValue"):
        if k in v:
            return v[k]
    return "<composite>"

def parse(d):
    spans = []
    for b in d.get("batches", d.get("resourceSpans", [])):
        r = {a["key"]: val(a["value"]) for a in b["resource"]["attributes"]}
        svc = r.get("service.name", "?")
        for ss in b.get("scopeSpans", []):
            for s in ss["spans"]:
                a = {x["key"]: val(x["value"]) for x in s.get("attributes", [])}
                spans.append({"svc": svc, "name": s["name"], "id": s.get("spanId", ""),
                              "parent": s.get("parentSpanId", "") or "", "attrs": a})
    return spans

try:
    spans = parse(json.load(sys.stdin))
except (ValueError, KeyError, TypeError):
    spans = []

results, infos = [], []
def check(passed, label, detail=""):
    results.append((bool(passed), label, str(detail)))

if not spans:
    print("[FAIL] no spans in the gateway response — check the trace ID, and that the collector")
    print("       received the trace (demo-trace.sh prints the ID; give Tempo a minute)")
    sys.exit(1)

ogx = [s for s in spans if s["svc"] == "ogx"]
agents = [s for s in spans if s["svc"] != "ogx"]
services = sorted({s["svc"] for s in spans})

# One trace ID across the agents and OGX: the demo's last agent injected its traceparent into
# the OGX request, so OGX's spans must sit in the same trace as the agent spans.
check(bool(ogx) and bool(agents), "one trace ID covers the agents and OGX",
      "services in this trace: " + ", ".join(services) if ogx else
      "no service.name ogx — found: " + ", ".join(services))
check(bool(ogx), "service.name ogx on the OGX spans", "%d span(s)" % len(ogx))

srv = [s for s in ogx if s["name"] == "POST /v1/responses"]
names = ", ".join(sorted({s["name"] for s in ogx})) or "none"
if srv:
    a = srv[0]["attrs"]
    ok = (a.get("http.request.method") == "POST" and "http.route" in a
          and "http.response.status_code" in a)
    check(ok, "SERVER span POST /v1/responses with http.request.method, http.route, http.response.status_code",
          "method=%s route=%s status=%s" % (a.get("http.request.method"), a.get("http.route"),
                                            a.get("http.response.status_code")))
else:
    check(False, "SERVER span POST /v1/responses with http.request.method, http.route, http.response.status_code",
          "no such span; OGX spans found: " + names)

# The demo's last agent opened a CLIENT span and injected its traceparent into the request, so
# the OGX SERVER span's parent must be that client span.
if srv:
    parent = srv[0]["parent"]
    par = [s for s in spans if s["id"] == parent]
    check(bool(parent) and bool(par),
          "the OGX SERVER span's parent is the agent's client span (traceparent propagated)",
          ("parent: %s (service %s)" % (par[0]["name"], par[0]["svc"])) if par
          else ("root span — no traceparent arrived" if not parent
                else "parent span id %s not in this trace" % parent))
else:
    check(False, "the OGX SERVER span's parent is the agent's client span (traceparent propagated)",
          "no POST /v1/responses span to check")

chat = [s for s in ogx if s["name"].startswith("chat ")
        and any(k.startswith("gen_ai.") for k in s["attrs"])]
if chat:
    keys = sorted({k for s in chat for k in s["attrs"] if k.startswith("gen_ai.")})
    check(True, "inference spans (chat <model>) carry gen_ai.* attributes",
          "%d span(s); %s" % (len(chat), ", ".join(keys)))
else:
    plain = [s["name"] for s in ogx if s["name"].startswith("chat ")]
    check(False, "inference spans (chat <model>) carry gen_ai.* attributes",
          ("no gen_ai.* attributes on: " + ", ".join(sorted(set(plain)))) if plain
          else "no chat spans in the trace (did the request reach a model?)")

if os.environ.get("OGX_MCP") == "1":
    lst = [s for s in ogx if s["name"] == "list_mcp_tools"]
    if lst:
        a = lst[0]["attrs"]
        check("server_label" in a and "server_url" in a,
              "list_mcp_tools with server_label and server_url",
              "server_label=%s server_url=%s" % (a.get("server_label"), a.get("server_url")))
    else:
        check(False, "list_mcp_tools with server_label and server_url",
              "no list_mcp_tools span (tools entry missing, or the gateway was unreachable)")
    inv = [s for s in ogx if s["name"] == "invoke_mcp_tool"]
    if inv:
        a = inv[0]["attrs"]
        ok = all(k in a for k in ("server_label", "server_url", "tool_name"))
        check(ok, "invoke_mcp_tool with server_label, server_url and tool_name",
              "server_label=%s server_url=%s tool_name=%s" % (a.get("server_label"),
                                                              a.get("server_url"), a.get("tool_name")))
    else:
        check(False, "invoke_mcp_tool with server_label, server_url and tool_name",
              "no invoke_mcp_tool span (the model did not call a tool in this request)")
else:
    infos.append("MCP span checks skipped; pass --ogx-mcp if the demo run used it")

# TRACE-FORMAT.md documents that OGX adds no user identity to spans. Either way is INFO.
ui = [s for s in ogx if "user.id" in s["attrs"]]
infos.append("user identity on OGX spans: %s"
             % ("present on %d span(s), TRACE-FORMAT.md documents none" % len(ui) if ui
                else "absent (as TRACE-FORMAT.md documents)"))

for ok, label, detail in results:
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", label, (" — " + detail) if detail else ""))
for line in infos:
    print("[INFO] " + line)
npass = sum(1 for ok, _, _ in results if ok)
nfail = len(results) - npass
print("Summary: %d PASS, %d FAIL, %d INFO (expectations from TRACE-FORMAT.md)"
      % (npass, nfail, len(infos)))
sys.exit(1 if nfail else 0)
PY

oc create sa trace-reader -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc create clusterrolebinding trace-reader --clusterrole=tempo-agents-traces-reader \
  --serviceaccount="$ns":trace-reader --dry-run=client -o yaml | oc apply -f - >/dev/null
tok="$(oc create token trace-reader -n "$ns" --duration=10m)"
oc port-forward -n "$ns" svc/tempo-agents-gateway 18080:8080 >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null' EXIT; sleep 3

curl -sk -H "Authorization: Bearer $tok" \
  "https://localhost:18080/api/traces/v1/agents/tempo/api/traces/$tid" \
  | OGX_MCP="$OGX_MCP" python3 -c "$CHECK_PY"
