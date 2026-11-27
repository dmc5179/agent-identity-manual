#!/usr/bin/env bash
# demo-run.sh - run the whole agent identity demo in order, for rehearsing or presenting.
#
#   ./demo-run.sh                # steps 0-4 below, in order
#   ./demo-run.sh --dry-run      # pre-flight and the plan of every step, no pods
#   ./demo-run.sh --skip-ogx     # leave out the OGX hop (step 3)
#   ./demo-run.sh --step N       # one step only: 0 pre-flight, 1 chain, 2 contrast, 3 OGX, 4 summary
#   ./demo-run.sh --pause        # wait for Enter between steps, for live presenting
#
# Steps:
#   0  pre-flight: ./verify.sh (a warning is fine, a failure stops the run), then a
#      ./demo-trace.sh --dry-run of the plain chain.
#   1  the agent chain: ./demo-trace.sh as DEMO_USER, with the MCP step when DEMO_MCP_TOOL is set.
#   2  the contrast run: the same chain plus --mcp-contrast, so one trace holds the allowed MCP
#      call and the refused one. Runs when DEMO_MCP_TOOL and DEMO_MCP_CONTRAST are set.
#   3  the OGX hop: ./ogx-token.sh "$DEMO_USER" mints the token (it prompts for the Keycloak
#      password once; the token stays in an environment variable and is never printed or
#      written), then ./demo-trace.sh --ogx-url ... [--ogx-mcp], then ./ogx-trace-check.sh
#      [--ogx-mcp] <trace id>. Runs when DEMO_OGX_URL is set.
#   4  the summary: step, trace ID, result, and how to open each trace in the console.
#
# Settings come from demo.env (copy demo.env.example): DEMO_USER, DEMO_AGENTS, DEMO_MCP_TOOL,
# DEMO_MCP_ARGS, DEMO_MCP_CONTRAST, DEMO_OGX_URL (unset or empty skips the OGX part) and
# DEMO_OGX_MCP (1 by default: the OGX hop hands OGX the MCP gateway as a tool server; set 0 to
# leave it out). vars.env supplies TRACING_NAMESPACE and the Keycloak settings ogx-token.sh reads.
# demo-trace.sh also reads demo.env itself, so each step passes empty --ogx-url or --mcp-contrast
# pins where a hop does not belong: the flags decide the shape of the run, and the plan in each
# banner is exactly what runs.
#
# The script exits non-zero when a step fails, and prints the summary either way.
#
# To rehearse without a cluster, point the helpers at stubs, for example:
#   DEMO_RUN_DEMO_TRACE=/tmp/stubs/demo-trace.sh DEMO_RUN_VERIFY=/tmp/stubs/verify.sh \
#   DEMO_RUN_OGX_TOKEN=/tmp/stubs/ogx-token.sh \
#   DEMO_RUN_OGX_TRACE_CHECK=/tmp/stubs/ogx-trace-check.sh ./demo-run.sh --dry-run
set -uo pipefail   # no -e: a failed step must not stop the summary from printing
cd "$(dirname "$0")" || exit 1

# The helpers: point these at stubs to rehearse the flow without a cluster (see the header).
RUN_VERIFY="${DEMO_RUN_VERIFY:-./verify.sh}"
RUN_DEMO_TRACE="${DEMO_RUN_DEMO_TRACE:-./demo-trace.sh}"
RUN_OGX_TOKEN="${DEMO_RUN_OGX_TOKEN:-./ogx-token.sh}"
RUN_OGX_CHECK="${DEMO_RUN_OGX_TRACE_CHECK:-./ogx-trace-check.sh}"

usage() { sed -n '2,34p' "$0"; }

DRY=0; SKIP_OGX=0; ONLY_STEP=""; PAUSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --skip-ogx) SKIP_OGX=1; shift ;;
    --step)
      [ $# -ge 2 ] || { echo "Error: --step needs a number (0-4)" >&2; exit 2; }
      ONLY_STEP="$2"; shift 2 ;;
    --pause) PAUSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$ONLY_STEP" in ""|0|1|2|3|4) ;; *) echo "Error: --step expects 0, 1, 2, 3 or 4" >&2; exit 2 ;; esac

if [ -f vars.env ]; then set -a; . ./vars.env; set +a; fi
if [ -f demo.env ]; then set -a; . ./demo.env; set +a; fi

DEMO_USER="${DEMO_USER:-demo-user}"
DEMO_AGENTS="${DEMO_AGENTS:-}"
DEMO_MCP_TOOL="${DEMO_MCP_TOOL:-}"
DEMO_MCP_ARGS="${DEMO_MCP_ARGS:-}"
DEMO_MCP_CONTRAST="${DEMO_MCP_CONTRAST:-}"
DEMO_OGX_URL="${DEMO_OGX_URL:-}"
DEMO_OGX_MCP="${DEMO_OGX_MCP:-1}"
TRACING_NAMESPACE="${TRACING_NAMESPACE:-tracing}"
OGX_MCP_ENABLED=0
if [ "$DEMO_OGX_MCP" != "0" ]; then OGX_MCP_ENABLED=1; fi

AGENTS=()
[ -n "$DEMO_AGENTS" ] && read -r -a AGENTS <<<"$DEMO_AGENTS"
if [ "$ONLY_STEP" != "4" ] && [ "${#AGENTS[@]}" -eq 0 ]; then
  echo "Error: DEMO_AGENTS is empty. Copy demo.env.example to demo.env and list the agents in call order." >&2
  exit 2
fi

# The flags every step shares; each step adds its pins and its own flags.
BASE_CMD=(--user "$DEMO_USER" ${AGENTS[@]+"${AGENTS[@]}"})
if [ -n "$DEMO_MCP_TOOL" ]; then
  BASE_CMD+=(--mcp-tool "$DEMO_MCP_TOOL")
  [ -n "$DEMO_MCP_ARGS" ] && BASE_CMD+=(--mcp-args "$DEMO_MCP_ARGS")
fi

PLAN_CONTRAST=0
if [ -n "$DEMO_MCP_TOOL" ] && [ -n "$DEMO_MCP_CONTRAST" ]; then PLAN_CONTRAST=1; fi
PLAN_OGX=0
if [ -n "$DEMO_OGX_URL" ] && [ "$SKIP_OGX" -eq 0 ]; then PLAN_OGX=1; fi

if [ "$ONLY_STEP" = "2" ] && [ "$PLAN_CONTRAST" -eq 0 ]; then
  echo "Error: step 2 needs DEMO_MCP_TOOL and DEMO_MCP_CONTRAST in demo.env." >&2
  exit 2
fi
if [ "$ONLY_STEP" = "3" ] && [ -z "$DEMO_OGX_URL" ]; then
  echo "Error: step 3 needs DEMO_OGX_URL in demo.env." >&2
  exit 2
fi

declare -a TMP_FILES=()
declare -a TRACE=("" "" "" "")    # captured trace ID per step, index 0 unused
declare -a RESULT=("" "" "" "")   # per-step result, index 0-3
FAILED=0
TRACE_ID=""
trap 'rm -f ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT

if [ "$PLAN_CONTRAST" -eq 0 ]; then
  if [ -z "$DEMO_MCP_TOOL" ]; then RESULT[2]="skipped (DEMO_MCP_TOOL is not set)"
  else RESULT[2]="skipped (DEMO_MCP_CONTRAST is not set)"; fi
fi
if [ -z "$DEMO_OGX_URL" ]; then RESULT[3]="skipped (DEMO_OGX_URL is not set)"
elif [ "$SKIP_OGX" -eq 1 ]; then RESULT[3]="skipped (--skip-ogx)"; fi
if [ -n "$ONLY_STEP" ]; then
  for s in 0 1 2 3; do
    [ "$s" = "$ONLY_STEP" ] || RESULT[$s]="not run (--step $ONLY_STEP)"
  done
fi

banner() {
  local n="$1" title="$2"; shift 2
  echo ""
  echo "========================================================================"
  printf 'Step %s: %s\n' "$n" "$title"
  if [ $# -gt 0 ]; then
    printf 'Watch for: %s\n' "$1"; shift
    local line
    for line in "$@"; do printf '           %s\n' "$line"; done
  fi
  echo "========================================================================"
}

pause_between() {
  [ "$PAUSE" -eq 1 ] || return 0
  [ -t 0 ] || return 0   # no pause when stdin is not the terminal (it may carry a password)
  printf 'Press Enter for the next step (Ctrl-C stops the demo): '
  read -r _ || true
}

# run_trace_cmd COMMAND...: stream the command's output to the console, capture the "Trace ID:"
# line it prints into TRACE_ID, and return the command's exit status.
run_trace_cmd() {
  TRACE_ID=""
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/demo-run-trace.XXXXXX")"
  TMP_FILES+=("$tmp")
  "$@" | tee "$tmp" || rc=$?
  TRACE_ID="$(sed -n 's/^Trace ID: \([0-9a-fA-F]\{1,\}\).*/\1/p' "$tmp" | tail -n 1)"
  return "$rc"
}

note_trace() {   # note_trace STEP: remember the captured trace ID for the summary
  [ -n "$TRACE_ID" ] && TRACE[$1]="$TRACE_ID"
  return 0
}

mark_ok() {      # mark_ok STEP: record ok, or "planned" under --dry-run
  if [ "$DRY" -eq 1 ]; then RESULT[$1]="planned (dry run)"; else RESULT[$1]="ok"; fi
}

# The plain-chain pins: an empty --ogx-url and --mcp-contrast keep those hops out of the runs
# that are not about them, whatever demo.env sets.
step0() {
  banner 0 "Pre-flight" \
    "verify.sh checks every component: a warning is fine, a failure stops the run" \
    "the dry run lists the hops demo-trace.sh would make, without creating pods"
  local rc=0 tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/demo-run-verify.XXXXXX")"
  TMP_FILES+=("$tmp")
  if "$RUN_VERIFY" | tee "$tmp"; then :; else rc=1; fi
  if grep -q '✗' "$tmp"; then
    echo "verify.sh reported a failed check (✗); fix it before presenting." >&2
    rc=1
  fi
  local -a cmd=("${BASE_CMD[@]}" --dry-run --ogx-url "" --mcp-contrast "")
  if ! run_trace_cmd "$RUN_DEMO_TRACE" "${cmd[@]}"; then rc=1; fi
  if [ "$rc" -eq 0 ]; then mark_ok 0; fi
  return "$rc"
}

step1() {
  local -a notices=(
    "each hop is a short-lived pod running as that agent's own service account"
    "every span carries user.id in baggage and the agent's SPIFFE ID"
  )
  if [ -n "$DEMO_MCP_TOOL" ]; then
    notices+=("the last agent makes one real MCP tools/call with its own token: its RBAC decides what the tool returns")
  fi
  banner 1 "The agent chain" "${notices[@]}"
  local -a cmd=("${BASE_CMD[@]}" --ogx-url "" --mcp-contrast "")
  [ "$DRY" -eq 1 ] && cmd+=(--dry-run)
  if ! run_trace_cmd "$RUN_DEMO_TRACE" "${cmd[@]}"; then
    echo "The agent chain failed." >&2
    return 1
  fi
  note_trace 1
  mark_ok 1
  return 0
}

step2() {
  banner 2 "The contrast run" \
    "one trace holds two calls to the same tool: the agent's allowed call and the refusal" \
    "the contrast account has no RBAC, so its span carries mcp.tool.is_error=true"
  local -a cmd=("${BASE_CMD[@]}" --mcp-contrast "$DEMO_MCP_CONTRAST" --ogx-url "")
  [ "$DRY" -eq 1 ] && cmd+=(--dry-run)
  if ! run_trace_cmd "$RUN_DEMO_TRACE" "${cmd[@]}"; then
    echo "The contrast run failed." >&2
    return 1
  fi
  note_trace 2
  mark_ok 2
  return 0
}

step3() {
  local -a notices=(
    "the last agent ends with one real request to OGX, and OGX's spans continue the same trace"
    "the token carries the ogx-api audience: the agent's service account token would not work"
  )
  if [ "$OGX_MCP_ENABLED" -eq 1 ]; then
    notices+=("with --ogx-mcp, OGX also calls the MCP gateway: list_mcp_tools and invoke_mcp_tool spans join the trace")
  fi
  notices+=("an OGX request takes about 5 s without tools, and 15-17 s with one MCP tool call")
  banner 3 "The OGX hop" "${notices[@]}"
  local -a cmd=("${BASE_CMD[@]}" --ogx-url "$DEMO_OGX_URL" --mcp-contrast "")
  if [ "$OGX_MCP_ENABLED" -eq 1 ]; then cmd+=(--ogx-mcp); fi
  [ "$DRY" -eq 1 ] && cmd+=(--dry-run)
  if [ "$DRY" -eq 1 ]; then
    echo "Dry run: the token mint is skipped, so the plan reports the token as MISSING."
    unset DEMO_OGX_TOKEN
    if run_trace_cmd "$RUN_DEMO_TRACE" "${cmd[@]}"; then mark_ok 3; return 0; fi
    echo "The OGX hop plan failed." >&2
    return 1
  fi
  printf 'Minting the OGX token for %s (enter the Keycloak password when prompted).\n' "$DEMO_USER"
  local tok
  tok="$("$RUN_OGX_TOKEN" "$DEMO_USER")" || { echo "ogx-token.sh did not produce a token." >&2; return 1; }
  if [ -z "$tok" ]; then
    echo "ogx-token.sh returned an empty token." >&2
    return 1
  fi
  # The token lives in the environment only: never printed, never written to a file.
  export DEMO_OGX_TOKEN="$tok"
  if ! run_trace_cmd "$RUN_DEMO_TRACE" "${cmd[@]}"; then
    echo "The OGX hop failed." >&2
    return 1
  fi
  note_trace 3
  mark_ok 3
  local -a chk=("$RUN_OGX_CHECK")
  if [ "$OGX_MCP_ENABLED" -eq 1 ]; then chk+=(--ogx-mcp); fi
  chk+=("$TRACE_ID")
  if ! "${chk[@]}"; then
    echo "ogx-trace-check.sh reported FAIL for trace $TRACE_ID." >&2
    return 1
  fi
  return 0
}

print_summary() {
  banner 4 "Summary" "every trace the run produced, and how to open each one in the console"
  printf '%-4s %-14s %-34s %s\n' "Step" "What" "Trace ID" "Result"
  printf '%-4s %-14s %-34s %s\n' "0" "pre-flight" "-" "${RESULT[0]:-not run}"
  printf '%-4s %-14s %-34s %s\n' "1" "the chain" "${TRACE[1]:--}" "${RESULT[1]:-not run}"
  printf '%-4s %-14s %-34s %s\n' "2" "contrast" "${TRACE[2]:--}" "${RESULT[2]:-not run}"
  printf '%-4s %-14s %-34s %s\n' "3" "OGX hop" "${TRACE[3]:--}" "${RESULT[3]:-not run}"
  echo ""
  echo "Console: Observe > Traces; TempoStack agents, tenant agents (namespace $TRACING_NAMESPACE)."
  echo "Search a trace ID, or TraceQL: { span.user.id = \"$DEMO_USER\" } for every span of this user."
  if [ -n "${TRACE[3]}" ]; then
    echo "The OGX spans: { resource.service.name = \"ogx\" }."
  fi
  echo "More TraceQL tips: GUIDE.md, section 7."
  if [ "$DRY" -eq 1 ]; then
    echo "Dry run: no pods were created and no traces were written."
  fi
  return 0
}

run_step() {
  case "$1" in
    0) step0 ;; 1) step1 ;; 2) step2 ;; 3) step3 ;;
  esac
}

STEPS=()
if [ -n "$ONLY_STEP" ]; then
  if [ "$ONLY_STEP" != "4" ]; then STEPS=("$ONLY_STEP"); fi
else
  STEPS=(0 1)
  [ "$PLAN_CONTRAST" -eq 1 ] && STEPS+=(2)
  [ "$PLAN_OGX" -eq 1 ] && STEPS+=(3)
fi

first=1
for s in ${STEPS[@]+"${STEPS[@]}"}; do
  if [ "$first" -eq 0 ]; then pause_between; fi
  first=0
  if run_step "$s"; then :; else
    RESULT[$s]="FAILED"
    FAILED=1
    echo "Step $s failed; the summary follows." >&2
    break
  fi
done
if [ "$first" -eq 0 ]; then pause_between; fi

for s in 0 1 2 3; do
  if [ -z "${RESULT[$s]}" ]; then RESULT[$s]="not run"; fi
done
print_summary
exit "$FAILED"
