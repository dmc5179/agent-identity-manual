#!/usr/bin/env bash
# demo-trace.sh - produce a fresh "user -> agent -> agent" trace for the demo.
#
#   ./demo-trace.sh [--user alice] [--dry-run] AGENT [AGENT ...]
#   ./demo-trace.sh [--user alice] --entry-url URL
#   ./demo-trace.sh [--dry-run]              use DEMO_USER and DEMO_AGENTS from demo.env
#
# AGENT is namespace/serviceaccount[=display-name], for example:
#   ./demo-trace.sh --user alice agents/planner=Planner agents/researcher=Researcher tools/mcp-client
#
# Probe mode (default): for each AGENT, in order, a short-lived pod runs in that namespace AS that
# service account. It fetches the agent's real SPIFFE ID from SPIRE, records its span tagged with
# user.id and spiffe.id, and hands the trace context (W3C traceparent + baggage) to the next hop.
# The identities are the agents' real ones; the work is a stand-in. Each agent's span holds a few
# steps ("think", "tool lookup", "call <next agent>", "write answer") so the console's timeline reads
# like a real request: each agent's "call" step contains the next agent's whole span. The pods run
# one after another, so the timing is planned up front and recorded with explicit timestamps; those
# steps carry demo.simulated=true. DEMO_PACE scales the timing (default 1.0: about 3-5 s per agent).
#
# Entry mode (--entry-url): sends one request to a real, instrumented agent with a new trace context
# and user.id in W3C baggage, so the trace continues through the real agents.
#
# demo.env (optional, see demo.env.example): DEMO_USER, DEMO_AGENTS, IMAGE, OTLP_ENDPOINT.
# Command-line values win over demo.env.
# --dry-run prints the hops and the pods it would create, and changes nothing.
#
# Prints the trace ID, a console link, and (if trace-query.sh works) the chain.
# Needs: oc logged in with rights to create pods in the agents' namespaces; the tracing stack (07-09);
# pods able to reach the collector; pip access from the probe image (or set IMAGE to one that has
# opentelemetry-sdk, opentelemetry-exporter-otlp-proto-http and spiffe installed).
set -euo pipefail
cd "$(dirname "$0")"; [ -f vars.env ] && { set -a; . ./vars.env; set +a; }
[ -f demo.env ] && { set -a; . ./demo.env; set +a; }
usage() { sed -n '2,29p' "$0"; }

USER_ID="${DEMO_USER:-demo-user}"; ENTRY_URL=""; DRY=0; AGENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_ID="$2"; shift 2 ;;
    --entry-url) ENTRY_URL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) AGENTS+=("$1"); shift ;;
  esac
done
if [ ${#AGENTS[@]} -eq 0 ] && [ -n "${DEMO_AGENTS:-}" ]; then read -r -a AGENTS <<<"$DEMO_AGENTS"; fi
[ -n "$ENTRY_URL" ] || [ ${#AGENTS[@]} -gt 0 ] || { usage; exit 2; }

NS_TRACING="${TRACING_NAMESPACE:-tracing}"
OTLP="${OTLP_ENDPOINT:-http://otel-collector.${NS_TRACING}.svc.cluster.local:4318}"
IMAGE="${IMAGE:-registry.access.redhat.com/ubi9/python-312}"
PIP="${PIP_PACKAGES:-opentelemetry-sdk opentelemetry-exporter-otlp-proto-http spiffe}"
RUN_ID="$(date +%s)"
DEMO_T0="$(date +%s%N)"; DEMO_PACE="${DEMO_PACE:-1.0}"

# One hop: read context from env, open a span as this agent, print the context for the next hop.
read -r -d '' HOP_PY <<'PY' || true
import os
from opentelemetry import trace, baggage, context, propagate
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from spiffe import WorkloadApiClient

import json
from opentelemetry.trace import SpanKind
name, user, step = os.environ["AGENT_NAME"], os.environ["USER_ID"], os.environ["STEP"]
plan, t0 = json.loads(os.environ["DEMO_PLAN"]), int(os.environ["DEMO_T0"])
at = lambda sec: t0 + int(sec * 1e9)          # planned offset (s) -> epoch ns
import time
for _try in range(15):                         # SPIRE registers a new pod a few seconds after it starts
    try:
        sid = str(WorkloadApiClient().fetch_x509_svid().spiffe_id); break
    except Exception:
        if _try == 14: raise
        time.sleep(2)
tp = TracerProvider(resource=Resource.create({"service.name": name}))
tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=os.environ["OTLP"] + "/v1/traces")))
trace.set_tracer_provider(tp)
carrier = {k: v for k, v in (("traceparent", os.environ.get("TRACEPARENT", "")),
                             ("baggage", os.environ.get("BAGGAGE", ""))) if v}
ctx = propagate.extract(carrier) if carrier else context.get_current()
if not baggage.get_baggage("user.id", ctx):
    ctx = baggage.set_baggage("user.id", user, ctx)
tok = context.attach(ctx)
tracer = trace.get_tracer("demo-trace")
ids = {"user.id": baggage.get_baggage("user.id") or user, "spiffe.id": sid}
span = tracer.start_span(f"{name}.handle", kind=SpanKind.SERVER, start_time=at(plan["start"]),
                         attributes={**ids, "demo.step": int(step)})
sctx = trace.set_span_in_context(span)
out = {}
for w in plan["steps"]:
    kind = SpanKind.CLIENT if w.get("call") else SpanKind.INTERNAL
    child = tracer.start_span(w["name"], context=sctx, kind=kind, start_time=at(w["start"]),
                              attributes={**ids, "demo.simulated": True})
    if w.get("call"):                          # the next agent's span nests under this step
        propagate.inject(out, context=trace.set_span_in_context(child, sctx))
    child.end(end_time=at(w["end"]))
if not out:
    propagate.inject(out, context=sctx)
tid = format(span.get_span_context().trace_id, "032x")
span.end(end_time=at(plan["end"]))
context.detach(tok); tp.shutdown()
print("DEMO_TRACEPARENT=" + out.get("traceparent", ""))
print("DEMO_BAGGAGE=" + out.get("baggage", ""))
print("DEMO_TRACE_ID=" + tid)
print("DEMO_SPIFFE_ID=" + sid)
PY

TRACEPARENT=""; BAGGAGE=""; TRACE_ID=""

# The timeline: one JSON plan per hop (offsets in seconds from DEMO_T0). Built from the last agent
# back, because each agent's "call" step has to last as long as the next agent's whole span.
plan_hops() {
  DEMO_PACE="$DEMO_PACE" python3 -I -c '
import json, os, random, sys
names, pace = sys.argv[1:], float(os.environ["DEMO_PACE"])
r = lambda a, b: round(random.uniform(a, b) * pace, 3)
def build(i):
    # plan for hop i starting at offset 0, and its duration
    t, steps = 0.05, []
    for n, a, b in (("think", 1.2, 2.4), ("tool lookup", 0.6, 1.4)):
        d = r(a, b); steps.append({"name": n, "start": t, "end": t + d}); t += d + 0.05
    if i + 1 < len(names):
        sub, sd = build(i + 1)
        steps.append({"name": "call " + names[i + 1], "start": t, "end": t + sd + 0.2, "call": True,
                      "sub": sub, "sub_start": t + 0.1})
        t += sd + 0.25
    d = r(0.4, 1.0); steps.append({"name": "write answer", "start": t, "end": t + d}); t += d + 0.05
    return {"start": 0, "steps": steps, "end": t}, t
def shift(p, off):
    return {"start": p["start"] + off, "end": p["end"] + off,
            "steps": [{k: (v + off if k in ("start", "end") else v) for k, v in s.items()
                       if k not in ("sub", "sub_start")} for s in p["steps"]]}
plans, off = [], 0.0
p = build(0)[0]
while p:
    plans.append(shift(p, off))
    call = next((s for s in p["steps"] if s.get("call")), None)
    p, off = (call["sub"], off + call["sub_start"]) if call else (None, off)
for x in plans:
    print(json.dumps(x, separators=(",", ":")))' "$@"
}

if [ $DRY -eq 1 ]; then
  echo "Dry run: user.id=$USER_ID  collector=$OTLP  image=$IMAGE"
  if [ -n "$ENTRY_URL" ]; then echo "  would call $ENTRY_URL with traceparent + baggage user.id=$USER_ID"; exit 0; fi
  step=0
  for a in "${AGENTS[@]}"; do
    step=$((step + 1)); spec="${a%%=*}"; disp="${a#*=}"; [ "$disp" = "$a" ] && disp="${spec#*/}"
    ns="${spec%%/*}"; sa="${spec#*/}"
    if oc get sa "$sa" -n "$ns" >/dev/null 2>&1; then ok="exists"; else ok="NOT FOUND"; fi
    echo "  hop $step: $disp -> pod demo-hop-${RUN_ID}-${step} in $ns as serviceaccount $sa ($ok)"
    echo "          expected spiffe.id: spiffe://<trust-domain>/ns/$ns/sa/$sa"
  done
  exit 0
fi

if [ -n "$ENTRY_URL" ]; then
  TRACE_ID="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"; SPAN_ID="$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
  echo "==> Calling $ENTRY_URL as user $USER_ID"
  curl -sk -o /dev/null -w "    HTTP %{http_code}\n" -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
    -H "baggage: user.id=${USER_ID}" "$ENTRY_URL"
else
  names=(); for a in "${AGENTS[@]}"; do spec="${a%%=*}"; d="${a#*=}"; [ "$d" = "$a" ] && d="${spec#*/}"; names+=("$d"); done
  mapfile -t PLANS < <(plan_hops "${names[@]}")
  step=0
  for a in "${AGENTS[@]}"; do
    step=$((step + 1)); spec="${a%%=*}"; disp="${a#*=}"; [ "$disp" = "$a" ] && disp="${spec#*/}"
    ns="${spec%%/*}"; sa="${spec#*/}"
    oc get sa "$sa" -n "$ns" >/dev/null 2>&1 || { echo "service account $ns/$sa not found" >&2; exit 1; }
    echo "==> Hop $step: $disp (namespace $ns, service account $sa)"
    pod="demo-hop-${RUN_ID}-${step}"
    AGENT_NAME="$disp" STEP="$step" NS="$ns" SA="$sa" POD="$pod" IMAGE="$IMAGE" PIP="$PIP" OTLP="$OTLP" \
    USER_ID="$USER_ID" TRACEPARENT="$TRACEPARENT" BAGGAGE="$BAGGAGE" HOP_PY="$HOP_PY" \
    DEMO_T0="$DEMO_T0" DEMO_PLAN="${PLANS[$((step - 1))]}" python3 -I -c '
import json, os
e = os.environ
env = [{"name": k, "value": e[k]} for k in ("AGENT_NAME", "USER_ID", "STEP", "OTLP", "TRACEPARENT", "BAGGAGE", "HOP_PY", "DEMO_T0", "DEMO_PLAN")]
env += [{"name": "SPIFFE_ENDPOINT_SOCKET", "value": "unix:///spiffe-workload-api/spire-agent.sock"},
        {"name": "HOME", "value": "/tmp"}]
print(json.dumps({"apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": e["POD"], "namespace": e["NS"], "labels": {"agent-identity": "true", "app": "demo-trace"}},
  "spec": {"serviceAccountName": e["SA"], "restartPolicy": "Never",
    "securityContext": {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "hop", "image": e["IMAGE"], "env": env,
      "command": ["bash", "-c", "pip install -q --disable-pip-version-check --target /tmp/py " + e["PIP"]
                  + " >/dev/null 2>&1; PYTHONPATH=/tmp/py python3 -c \"$HOP_PY\""],
      "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}},
      "volumeMounts": [{"name": "spiffe", "mountPath": "/spiffe-workload-api", "readOnly": True}]}],
    "volumes": [{"name": "spiffe", "csi": {"driver": "csi.spiffe.io", "readOnly": True}}]}}))' | oc apply -f - >/dev/null
    for _ in $(seq 1 60); do
      ph=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
      case "$ph" in Succeeded|Failed) break ;; esac; sleep 3
    done
    out=$(oc logs "$pod" -n "$ns" 2>&1 || true)
    oc delete pod "$pod" -n "$ns" --wait=false >/dev/null 2>&1 || true
    TRACEPARENT=$(sed -n 's/^DEMO_TRACEPARENT=//p' <<<"$out"); BAGGAGE=$(sed -n 's/^DEMO_BAGGAGE=//p' <<<"$out")
    TRACE_ID=$(sed -n 's/^DEMO_TRACE_ID=//p' <<<"$out"); sid=$(sed -n 's/^DEMO_SPIFFE_ID=//p' <<<"$out")
    [ -n "$TRACEPARENT" ] || { echo "    hop failed:"; tail -5 <<<"$out" | sed 's/^/    /'; exit 1; }
    echo "    spiffe.id: $sid"
  done
fi

echo
echo "Trace ID: $TRACE_ID   (user.id = $USER_ID)"
CONSOLE="$(oc whoami --show-console 2>/dev/null || true)"
[ -n "$CONSOLE" ] && echo "Console:  $CONSOLE/observe/traces  (TempoStack agents, tenant agents; search the trace ID or user.id)"
if [ -x ./trace-query.sh ] && [ -z "$ENTRY_URL" ]; then
  sleep 10; echo; ./trace-query.sh "$TRACE_ID" || true
fi
