# Quick start: build the environment and run the demo

One page for the customer team preparing the demo with this repository. Steps, commands and
troubleshooting are in [GUIDE.md](GUIDE.md); the trace field names are in
[TRACE-FIELDS.md](TRACE-FIELDS.md).

## What the demo shows

- One trace carries the full call chain: a signed-in user, two or three agents with workload
  identities (SPIFFE IDs), and the model call into OGX.
- A platform-enforced identity check: the last agent calls a real MCP tool through the MCP gateway,
  and the MCP server applies that agent's own OpenShift RBAC.
- The contrast: a service account without role bindings makes the same call and is refused, next to
  the allowed call in the same trace.

## What to have ready

Put every value in `demo.env`, a copy of `demo.env.example`.

| Value | Setting | Example | Notes |
|---|---|---|---|
| Keycloak issuer | `KEYCLOAK_ISSUER` | `https://keycloak.example.com/realms/agents` | Must equal the token `iss` claim exactly |
| Keycloak CLI client | `KEYCLOAK_CLI_CLIENT` | `oc-cli` | Public client, redirect `http://localhost:8080` |
| Demo user | `DEMO_USER` | `alice` | In the `tracing-viewers` group, so it can see traces in the console; the presenter needs this user's Keycloak password |
| Two or three agents | `DEMO_AGENTS` | `agents/planner=Planner agents/researcher=Researcher tools/mcp-client=MCP-Client` | `namespace/serviceaccount=Display name`, in call order. The service accounts exist (file `12-example-agent.yaml`); the SPIFFE ID rule selects their pods |
| One MCP tool and its arguments | `DEMO_MCP_TOOL`, `DEMO_MCP_ARGS` | `openshift_pods_list_in_namespace`, `{"namespace":"$NS"}` | Registered on the MCP gateway; give the last agent's service account RBAC for the tool. `$NS` becomes the agent namespace |
| Contrast service account | `DEMO_MCP_CONTRAST` | `agents/demo-no-rbac=No-RBAC` | Create it with no role bindings, so the MCP server refuses its call |
| Guardrail test arguments | `DEMO_MCP_ARGS_GUARDED` | `{"namespace":"$NS","note":"contact alice@example.com"}` | With `17-nemo-mcp-guardrails.yaml` applied: the last agent repeats the tool call with these arguments and the gateway refuses them (403). Needs `DEMO_MCP_TOOL` |
| OGX URL | `DEMO_OGX_URL` | `http://ogx-service.agents.svc.cluster.local:8321` | `<OGXServer>-service.<namespace>.svc.cluster.local:8321`; the operator names the Service after the OGXServer |
| OGX model id | `DEMO_OGX_MODEL` | `vllm-inference/publishers/llm/models/qwen3-8b` | OGX prefixes `vllm-inference/` to the MaaS model id |
| Question for OGX | `DEMO_OGX_PROMPT` | `How many pods are running in the namespace $NS? Use the tool.` | Ask something the MCP tool can answer, so OGX records an `invoke_mcp_tool` span |
| Agent image (disconnected clusters) | `IMAGE` | `registry.example.com/demo/otel-spiffe-python:1` | Must contain the Python OpenTelemetry and SPIFFE libraries |

## Build order

Work through the GUIDE sections in this order, checking each file before applying it.

1. [0. Prepare](GUIDE.md#0-prepare-15-min) — 15 min: fill `vars.env`, import the Keycloak realm, decide the trust domain (immutable).
2. [1. Workload identity](GUIDE.md#1-workload-identity-no-downtime-15-min) — 15 min, no downtime: ZTWIM, then SPIRE, then the agent SPIFFE IDs.
3. [2. Tracing](GUIDE.md#2-tracing-no-downtime-20-min) — 20 min, no downtime: Tempo, the collector, the console Traces UI, the `tracing-viewers` group.
4. [3. Sign-in switch](GUIDE.md#3-sign-in-switch-change-window-30-min) — 30 min change window: external OIDC; the API server rolls out for about 20 minutes.
5. [4. Models, OGX, agents](GUIDE.md#4-models-ogx-agents-30-min) — 30 min: MaaS access, the OGX database and OGXServer, the example agents.
6. [8. MCP tools through the MCP gateway](GUIDE.md#8-mcp-tools-through-the-mcp-gateway): the MCP
   gateway (`16-mcp-gateway.yaml`, applied before `15-playground-mcp.yaml`), the MCP server and the
   gateway RBAC that the tool and contrast steps use.
7. [6. Verify](GUIDE.md#6-verify): `./verify.sh` reports one line per component; fix every failure before the demo.

## Run the demo

```bash
cp demo.env.example demo.env && vi demo.env
./demo-run.sh --dry-run       # pre-flight and the plan of every step, no pods
./demo-run.sh --pause         # the live run: waits for Enter between steps
```

- Log in fresh from a terminal or the console just before the run: a Keycloak-issued login lasts
  minutes, and an expired token stops the OGX token step. That step prompts once for the demo
  user's Keycloak password; the script never prints the token.
- To watch, open **Observe → Traces** in the console and pick the TempoStack and tenant. Widen the
  time range if a trace is missing from the list; raise the trace limit or sort by span count to
  bring the full OGX run to the top. `demo-run.sh` prints every trace ID to paste into TraceQL.
- To show usage and enforcement numbers on dashboards beside the traces, apply
  `14-console-dashboards.yaml` ([GUIDE 7](GUIDE.md#dashboards-for-the-demo)): the RHOAI Usage
  dashboard (Technology Preview) plus an `agent-gateways` dashboard for the MCP gateway.
- To show the identity check in the gen AI playground itself, apply `15-playground-mcp.yaml` and
  follow [Playground: one question, two users](GUIDE.md#playground-one-question-two-users): the same
  question asked as two users, pods for one and forbidden for the other.

## If something fails

- `./verify.sh` says which component is not Ready; fix it before re-running.
- Re-run one step only with `./demo-run.sh --step N`.
- The symptom table in [Troubleshooting](GUIDE.md#troubleshooting) covers most causes, from a pod
  with no SPIFFE socket to an OGX 401.
- For the span and field names on each hop, see [TRACE-FIELDS.md](TRACE-FIELDS.md) and
  [TRACE-FORMAT.md](TRACE-FORMAT.md).
