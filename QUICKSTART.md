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
| Guardrail test arguments | `DEMO_MCP_ARGS_GUARDED` | `{"namespace":"$NS","note":"contact alice@example.com"}` | With `15-nemo-mcp-guardrails.yaml` applied: the last agent repeats the tool call with these arguments and the gateway refuses them (403). Needs `DEMO_MCP_TOOL` |
| OGX URL | `DEMO_OGX_URL` | `http://ogx-service.agents.svc.cluster.local:8321` | `<OGXServer>-service.<namespace>.svc.cluster.local:8321`; the operator names the Service after the OGXServer |
| OGX model id | `DEMO_OGX_MODEL` | `vllm-inference/publishers/llm/models/qwen3-8b` | OGX prefixes `vllm-inference/` to the MaaS model id |
| Question for OGX | `DEMO_OGX_PROMPT` | `How many pods are running in the namespace $NS? Use the tool.` | Ask something the MCP tool can answer, so OGX records an `invoke_mcp_tool` span |
| Agent image (disconnected clusters) | `IMAGE` | `registry.example.com/demo/otel-spiffe-python:1` | Must contain the Python OpenTelemetry and SPIFFE libraries |

## Build order

Work through this list top to bottom; the file numbers match the apply order. Fill `vars.env` first
(copy `vars.env.example`), because every `render.sh` command reads it.

### Before you start: install these operators

| Operator | Needed by (files) | Ready when |
|---|---|---|
| Zero Trust Workload Identity Manager | 01–03, 12 | the CSV shows Succeeded: `oc get csv -A \| grep zero-trust-workload-identity-manager` |
| Red Hat build of Keycloak, or an existing Keycloak | 00, 04, 05, 10, 17 | the CSV shows Succeeded: `oc get csv -A \| grep keycloak`; with an existing Keycloak, the issuer answers `/.well-known/openid-configuration` |
| Red Hat build of Tempo | 07–09 | the CSV shows Succeeded: `oc get csv -A \| grep tempo` |
| Red Hat build of OpenTelemetry | 08, 10, 12 | the CSV shows Succeeded: `oc get csv -A \| grep opentelemetry` |
| Cluster Observability Operator | 09, 16 | the CSV shows Succeeded: `oc get csv -A \| grep cluster-observability` |
| Red Hat Connectivity Link 1.5 with the MCP gateway operator | 11, 14, 15, 17 | the CSVs show Succeeded: `oc get csv -A \| grep -e kuadrant -e mcp` |
| Red Hat OpenShift AI 3.5 with the TrustyAI, OGX and Models-as-a-Service components | 05, 06, 10, 12, 15, 17 | the CSV shows Succeeded: `oc get csv -A \| grep rhods`, and the DataScienceCluster lists those components as Managed |
| OpenShift Service Mesh 3 (only for the optional mesh step) | 13 | the CSV shows Succeeded: `oc get csv -A \| grep ossm` |

### Steps 0–20: apply in this order (step N applies file NN)

0. **Keycloak realm** ([GUIDE 0](GUIDE.md#0-prepare-15-min)) — creates the realm's clients, groups and token mappers that every later step trusts.
   Import: in Keycloak, Realm settings → Action → Partial import with `00-keycloak-realm-clients.json`, after filling the `${...}` values (or `kcadm`).
   Check: `curl -skf "$KEYCLOAK_ISSUER/.well-known/openid-configuration"` answers for the realm, and the Clients tab lists the imported clients.
1. **Workload identity** ([GUIDE 1](GUIDE.md#1-workload-identity-no-downtime-15-min)) — sets the SPIFFE trust domain and cluster name that every later identity object reads.
   Command: `./render.sh 01-ztwim.yaml --check && ./render.sh 01-ztwim.yaml --apply`
   Check: `oc get zerotrustworkloadidentitymanagers.operator.openshift.io cluster` shows the singleton with your trust domain.
2. **SPIRE** ([GUIDE 1](GUIDE.md#1-workload-identity-no-downtime-15-min)) — deploys the SPIRE server, one agent per node, the CSI driver and the OIDC discovery provider.
   Command: `./render.sh 02-spire.yaml --check && ./render.sh 02-spire.yaml --apply`
   Check: `oc get pods -n zero-trust-workload-identity-manager` shows `spire-server-0` Running and one `spire-agent` per node.
3. **Agent SPIFFE IDs** ([GUIDE 1](GUIDE.md#1-workload-identity-no-downtime-15-min)) — gives pods labeled `agent-identity: "true"` an explicit SPIFFE ID and a 5-minute JWT TTL.
   Command: `./render.sh 03-agent-spiffe-ids.yaml --check && ./render.sh 03-agent-spiffe-ids.yaml --apply`
   Check: `oc get clusterspiffeids.spire.spiffe.io agents` shows the entry; its `podsSelected` count rises once agent pods run.
4. **Sign-in switch (CHANGE WINDOW)** ([GUIDE 3](GUIDE.md#3-sign-in-switch-change-window-30-min)) — moves OpenShift sign-in to Keycloak; the API server rolls out for about 20 minutes and built-in OAuth goes off for everyone.
   Command: the CA ConfigMap and console Secret from the file header first, then `./render.sh 04-openshift-external-oidc.yaml --check && ./render.sh 04-openshift-external-oidc.yaml --apply`
   Check: `oc get co kube-apiserver` shows Progressing=False after the rollout, and `oc whoami` shows the Keycloak user.
5. **RHOAI dashboard sign-in** ([GUIDE 3](GUIDE.md#3-sign-in-switch-change-window-30-min)) — points the RHOAI dashboard gateway at Keycloak.
   Command: the gateway client Secret from the file header first, then `./render.sh 05-rhoai-gateway-oidc.yaml --check && ./render.sh 05-rhoai-gateway-oidc.yaml --apply`
   Check: `oc get gatewayconfigs.services.platform.opendatahub.io default-gateway -o jsonpath='{.spec.oidc.issuerURL}'` prints the Keycloak issuer.
6. **MaaS access** ([GUIDE 4](GUIDE.md#4-models-ogx-agents-30-min)) — lets your Keycloak group and the agent service accounts use the model.
   Command: set `<model>` and `<model-ns>` in the file, then `./render.sh 06-maas-access.yaml --check && ./render.sh 06-maas-access.yaml --apply`
   Check: `oc get maasauthpolicies,maassubscriptions -n models-as-a-service` lists the objects for your model.
7. **Tempo** ([GUIDE 2](GUIDE.md#2-tracing-no-downtime-20-min)) — the trace store with the `agents` tenant behind a gateway.
   Command: the `tempo-s3` Secret from the file header first, then `./render.sh 07-tempo.yaml --check && ./render.sh 07-tempo.yaml --apply`
   Check: `oc get tempostacks.tempo.grafana.com agents -n $TRACING_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` prints True.
8. **OpenTelemetry collector** ([GUIDE 2](GUIDE.md#2-tracing-no-downtime-20-min)) — receives OTLP from the agents and OGX and writes to the `agents` tenant.
   Command: `./render.sh 08-opentelemetry.yaml --check && ./render.sh 08-opentelemetry.yaml --apply`
   Check: `oc get deploy otel-collector -n $TRACING_NAMESPACE -o jsonpath='{.status.readyReplicas}'` prints 1.
9. **Traces UI** ([GUIDE 2](GUIDE.md#2-tracing-no-downtime-20-min)) — turns on console Observe → Traces for the TempoStack; give readers the `tracing-viewers` group.
    Command: `./render.sh 09-tracing-ui.yaml --check && ./render.sh 09-tracing-ui.yaml --apply`, then `oc adm groups new tracing-viewers <you>` (a Keycloak group of that name, since the switch has run).
    Check: `oc get uiplugins.observability.openshift.io distributed-tracing -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'` prints True.
10. **OGX server** ([GUIDE 4](GUIDE.md#4-models-ogx-agents-30-min)) — the model server that accepts only Keycloak tokens and traces to the collector; its database Secret, MaaS key and ingress CA come first (commands in GUIDE 4).
    Command: `./render.sh 10-ogx.yaml --check && ./render.sh 10-ogx.yaml --apply`
    Check: `oc get ogxservers.ogx.io ogx -n $OGX_NAMESPACE` shows the server, with an available replica about a minute later.
11. **Gateway policy (optional)** ([GUIDE 4](GUIDE.md#4-models-ogx-agents-30-min)) — an Authorino AuthPolicy that accepts a Keycloak user or a SPIRE agent at one of your HTTPRoutes.
    Command: set `<route-to-protect>`, then `./render.sh 11-authpolicy-agent-or-user.yaml --check && ./render.sh 11-authpolicy-agent-or-user.yaml --apply`
    Check: `oc get authpolicies.kuadrant.io agent-or-user -n $AGENT_NAMESPACE` finds the policy.
12. **Example agents** ([GUIDE 4](GUIDE.md#4-models-ogx-agents-30-min)) — the agent namespace, service accounts and a demo agent wired for SPIFFE, tracing and MaaS.
    Command: `./render.sh 12-example-agent.yaml --check && ./render.sh 12-example-agent.yaml --apply`
    Check: `oc get pods -n $AGENT_NAMESPACE` shows the agent pods Running.
13. **Service Mesh (optional)** ([GUIDE 4](GUIDE.md#4-models-ogx-agents-30-min)) — OpenShift Service Mesh 3 for agent-to-agent mTLS; read the whole file first, because it can break the cluster's Gateway API.
    Command: `./render.sh 13-service-mesh.yaml --check && ./render.sh 13-service-mesh.yaml --apply`
    Check: `oc get istiocni default && oc get istio agents-mesh` finds both control plane objects.
14. **MCP server and gateway** ([GUIDE 8](GUIDE.md#8-mcp-tools-through-the-mcp-gateway)) — installs the MCP gateway objects and registers the MCP server for Red Hat OpenShift on it, so tool calls are authenticated and RBAC-checked.
    Command: the Helm install from the file header first, then `./render.sh 14-mcp-gateway.yaml --check && ./render.sh 14-mcp-gateway.yaml --apply`
    Check: `oc get mcpserverregistrations.mcp.kuadrant.io -A` shows every registration with Ready=True.
15. **Guardrails (optional)** ([GUIDE 8](GUIDE.md#guardrails-on-tool-calls-nemo)) — checks every tool call's arguments and results against NeMo built-in rails at the gateway.
    Command: `./render.sh 15-nemo-mcp-guardrails.yaml --check && ./render.sh 15-nemo-mcp-guardrails.yaml --apply`, then the annotation command at the end of the file header.
    Check: `oc get mcpgatewayextensions mcp-gateway -n mcp-gateway` shows Ready after the annotation.
16. **Dashboards (optional)** ([GUIDE 7](GUIDE.md#dashboards-for-the-demo)) — usage and enforcement dashboards beside the traces; the file's five commented `oc patch` commands go first.
    Command: `./render.sh 16-console-dashboards.yaml --check && ./render.sh 16-console-dashboards.yaml --apply`
    Check: `oc get persesdashboard dashboard-5-agent-gateways-admin -n redhat-ods-monitoring` finds the dashboard.
17. **Playground (optional)** ([GUIDE 8](GUIDE.md#playground-one-question-two-users)) — registers the MCP gateway in the gen AI playground and gives the second demo user edit on the playground's project.
    Command: the ConfigMap commands from the file header first, then `./render.sh 17-playground-mcp.yaml --check && ./render.sh 17-playground-mcp.yaml --apply`
    Check: `oc get rolebinding playground-second-user-edit -n <playground-namespace>` finds the `edit` binding.
18. **Verify** ([GUIDE 6](GUIDE.md#6-verify)) — one line per component; fix every failure before the demo.
    Command: `./verify.sh`
19. **Rehearse** ([GUIDE 7](GUIDE.md#7-demo-a-fresh-trace-at-any-time)) — pre-flight and the plan of every step, with no pods created.
    Command: `./demo-run.sh --dry-run`
20. **Present** ([GUIDE 7](GUIDE.md#7-demo-a-fresh-trace-at-any-time)) — the live run; it waits for Enter between steps (see Run the demo).
    Command: `./demo-run.sh --pause`

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
  `16-console-dashboards.yaml` ([GUIDE 7](GUIDE.md#dashboards-for-the-demo)): the RHOAI Usage
  dashboard (Technology Preview) plus an `agent-gateways` dashboard for the MCP gateway.
- To show the identity check in the gen AI playground itself, apply `17-playground-mcp.yaml` and
  follow [Playground: one question, two users](GUIDE.md#playground-one-question-two-users): the same
  question asked as two users, pods for one and forbidden for the other.

## If something fails

- `./verify.sh` says which component is not Ready; fix it before re-running.
- Re-run one step only with `./demo-run.sh --step N`.
- The symptom table in [Troubleshooting](GUIDE.md#troubleshooting) covers most causes, from a pod
  with no SPIFFE socket to an OGX 401.
- For the span and field names on each hop, see [TRACE-FIELDS.md](TRACE-FIELDS.md) and
  [TRACE-FORMAT.md](TRACE-FORMAT.md).
