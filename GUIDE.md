# Agent identity with an external Keycloak: deployment guide

Goal: every agent has a workload identity (SPIFFE, from ZTWIM), every person signs in with Keycloak,
and one trace shows **user → agent → agent → OGX/model** with both identities on each hop.

Assumes OpenShift 4.22 with these operators **installed but not configured**: ZTWIM, OpenShift AI 3.5
(OGX, MaaS), Connectivity Link 1.5, Red Hat build of OpenTelemetry, Tempo, Cluster Observability
Operator, and (optional) Service Mesh 3. Details, doc links and known issues are in the comments of each YAML file.

## 0. Prepare (15 min)

```bash
cp vars.env.example vars.env && vi vars.env       # cluster, Keycloak, trust domain, namespaces
chmod +x render.sh verify.sh trace-query.sh
```

- **Keycloak**: import `00-keycloak-realm-clients.json` (after filling the `${...}` values), then note
  the console and gateway client secrets.
- **Decide the trust domain now.** It can't be changed later without rebuilding SPIRE.
- **FIPS cluster?** ZTWIM isn't supported there (KB 7144070). Stop and raise it.
- Every step: `./render.sh FILE --check` first, then `./render.sh FILE --apply`.

## 1. Workload identity (no downtime, ~15 min)

```bash
./render.sh 01-ztwim.yaml --apply                  # trust domain + cluster name: FIRST
oc get zerotrustworkloadidentitymanagers.operator.openshift.io cluster   # wait for it
./render.sh 02-spire.yaml --apply                  # server, agents, CSI driver, OIDC discovery
oc get pods -n zero-trust-workload-identity-manager -w   # spire-server-0, one spire-agent per node
./render.sh 03-agent-spiffe-ids.yaml --apply       # IDs for pods labelled agent-identity=true
```

Using SPIRE as the Service Mesh CA later? Set `CREATE_ONLY_MODE=true` on the ZTWIM Subscription
**before** `02` (see `13-service-mesh.yaml`).

## 2. Tracing (no downtime, ~20 min)

```bash
oc create namespace "$TRACING_NAMESPACE"
oc create secret generic tempo-s3 -n "$TRACING_NAMESPACE" --from-literal=bucket=<bucket> \
  --from-literal=endpoint=https://s3.<region>.amazonaws.com \
  --from-literal=access_key_id=<id> --from-literal=access_key_secret=<secret>
./render.sh 07-tempo.yaml --apply                  # wait: TempoStack agents Ready
./render.sh 08-opentelemetry.yaml --apply          # collector + Python Instrumentation
oc apply -f 09-tracing-ui.yaml                     # console: Observe -> Traces
oc adm groups new tracing-viewers <you>            # or a Keycloak group of that name after step 3
```

## 3. Sign-in switch (CHANGE WINDOW, ~30 min)

This turns off OpenShift's built-in OAuth for everyone. Keep the installer kubeconfig (it keeps
working), and back up: `oc get authentications.config.openshift.io cluster -o yaml > auth-backup.yaml`.

```bash
oc create configmap keycloak-ca -n openshift-config --from-file=ca-bundle.crt=keycloak-ca.crt   # private CA only
oc create secret generic keycloak-console-client -n openshift-config --from-literal=clientSecret=<console-secret>
./render.sh 04-openshift-external-oidc.yaml --apply
oc get co kube-apiserver -w                        # wait until Progressing=False (~20 min)
oc login https://api.<cluster>:6443 --exec-plugin=oc-oidc --issuer-url="$KEYCLOAK_ISSUER" \
  --client-id="$KEYCLOAK_CLI_CLIENT" --callback-port=8080 \
  --oidc-certificate-authority keycloak-ca.crt     # only if Keycloak uses a private CA
oc whoami                                          # your Keycloak user

oc create secret generic keycloak-gateway-client -n openshift-ingress --from-literal=clientSecret=<gateway-secret>
./render.sh 05-rhoai-gateway-oidc.yaml --apply     # RHOAI dashboard via Keycloak
```

**Copy login command.** With the `cli` client set (04), the console's Copy login command shows an
`oc login ... --exec-plugin oc-oidc` command for users. It leaves out two flags users may need:
`--oidc-certificate-authority <file>` when Keycloak's certificate is from a private CA (otherwise the
plugin fails with `x509: certificate signed by unknown authority`, even if you accept the API server's
certificate as insecure), and `--callback-port <port>`, where the port must be one of the Keycloak CLI client's
redirect URIs (`http://localhost:<port>`); any other port fails at Keycloak with "invalid parameter:
redirect_url". Register a second port for users whose 8080 is already taken. A self-signed API server certificate also needs
`--certificate-authority <api-ca>`. Seen on OpenShift 4.22.18 (OCPBUGS-147680). Either share the full command with
users, or add the CAs to their system trust store.

If the dashboard login loops or uses an old secret: `oc delete secret kube-auth-proxy-creds -n
openshift-ingress`, wait for it to return, `oc rollout restart deploy/kube-auth-proxy -n openshift-ingress`.

### Dev Spaces (if installed)

Dev Spaces signs in through the OpenShift OAuth server by default, so after step 3 its login fails until
it uses Keycloak (Dev Spaces install guide, "Use an external identity provider for authentication"):
a confidential Keycloak client `devspaces` (redirect `<cheURL>/oauth/callback`, web origin `<cheURL>`),
`devspaces` added to the audiences in 04 (another ~20 min API rollout), a Secret `oauth-secret` (key
`oAuthSecret`) and, for a private CA, a `keycloak-certs` ConfigMap labelled
`app.kubernetes.io/component=ca-bundle` in `openshift-devspaces`, then on the CheCluster:
`spec.networking.auth.oAuthClientName: devspaces`, `oAuthSecret: oauth-secret`,
`identityProviderURL: <issuer>`, `gateway.oAuthProxy.cookieExpireSeconds: 300`, and the oauth-proxy
env `OAUTH2_PROXY_CODE_CHALLENGE_METHOD=S256`. Dev Spaces, the DevWorkspace Operator and Web Terminal
must be installed in one namespace. A workspace gets a kubeconfig with the user's own token, which
isn't refreshed: `oc` in the workspace works for about 5 minutes after it starts (CRW-14511).

## 4. Models, OGX, agents (~30 min)

```bash
vi 06-maas-access.yaml                             # set <model> and <model-ns>
./render.sh 06-maas-access.yaml --apply            # Keycloak group + agent service accounts
./render.sh 10-ogx.yaml --check                    # add the PostgreSQL env first (see file notes)
./render.sh 10-ogx.yaml --apply
./render.sh 12-example-agent.yaml --apply          # replace the image with your agent
```

Optional: `11-authpolicy-agent-or-user.yaml` (gateway accepts a Keycloak user OR a SPIRE agent) and
`13-service-mesh.yaml` (read it fully first: it can break OpenShift's Gateway API).

## 5. In your agent code

Each agent fetches its identity, tags its spans, and passes the user along:

```python
from opentelemetry import trace, baggage, context, propagate
from spiffe import WorkloadApiClient                     # pip install spiffe

spiffe_id = str(WorkloadApiClient().fetch_x509_svid().spiffe_id)
tracer = trace.get_tracer("agent-a")

def handle(user_id, call_next_agent):
    tok = context.attach(baggage.set_baggage("user.id", user_id))   # from the Keycloak token
    with tracer.start_as_current_span("agent-a.handle") as span:
        span.set_attribute("user.id", user_id)
        span.set_attribute("spiffe.id", spiffe_id)
        headers = {}; propagate.inject(headers)              # traceparent + baggage
        call_next_agent(headers)
    context.detach(tok)

# Receiving side: lowercase header names before extracting (urllib sends "Traceparent").
# ctx = propagate.extract({k.lower(): v for k, v in request_headers.items()})
# user = baggage.get_baggage("user.id", ctx)
```

For calls to another service, get a JWT-SVID with `fetch_jwt_svid(audience={"<audience>"})` and send it
as `Authorization: Bearer`. The receiver verifies it against `$SPIRE_JWT_ISSUER` (file 11 does this in
Connectivity Link).

## 6. Verify

```bash
./verify.sh                                        # one line per component
./trace-query.sh <trace-id>                        # user and SPIFFE ID on every hop
```

Or in the console: **Observe → Traces**, pick TempoStack `agents`, tenant `agents`, and filter on
`user.id` or `spiffe.id`.

## 7. Demo: a fresh trace on demand

`demo-trace.sh` makes a "user → agent → agent" trace for any agents, without touching their code. For
each agent, in order, it runs a short-lived pod **as that agent's service account**, so each step
carries the agent's real SPIFFE ID. The work is a stand-in: each agent's span shows a few steps (think,
tool lookup, call the next agent, write answer) on a staged timeline of a few seconds per agent, so the
console's timeline view reads like a real request. Those steps carry `demo.simulated=true`; `DEMO_PACE=2`
in `demo.env` doubles the timing.

```bash
cp demo.env.example demo.env && vi demo.env       # DEMO_USER and DEMO_AGENTS (namespace/serviceaccount=Name)
./demo-trace.sh --dry-run                          # shows the hops; checks the service accounts exist
./demo-trace.sh                                    # prints the trace ID, console link and the chain
./demo-trace.sh --user bob agents/planner=Planner agents/researcher=Researcher   # or on the command line
```

**Optional MCP step.** With an MCP gateway on the cluster, the last agent can make one real MCP
tool call through it, authenticated with its own service account token:

```bash
./demo-trace.sh --user alice --mcp-tool openshift_pods_list_in_namespace --mcp-args '{"namespace":"$NS"}' \
  agents/planner=Planner agents/researcher=Researcher
```

The trace then shows a `tools/call <tool>` span with the real duration and result
(`demo.simulated=false`, `mcp.tool.is_error`, `gen_ai.tool.name`). The MCP server for Red Hat
OpenShift runs the tool with the caller's token, so what the agent may see is decided by its own
RBAC: the one identity check in the demo the platform itself enforces. Leave `DEMO_MCP_TOOL` unset
and the step is skipped. `$NS` in the arguments becomes the agent's namespace.

For agents that are already instrumented and expose HTTP, `./demo-trace.sh --user alice --entry-url
https://<agent>` sends one request with a new trace and the user in baggage, and the real agents carry
it on.

What to say in the demo: each step shows *which agent* (its SPIFFE identity) acted for *which user*.
Those two labels are written by the agents (here, by the probe) and aren't yet verified by the platform.
Platform-verified identity on every step is a request to Red Hat.

The probe pods install `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http` and `spiffe`
with pip. On a disconnected cluster, set `IMAGE` in `demo.env` to an image that has them.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod has no `/spiffe-workload-api/spire-agent.sock` | No spire-agent on that node: keep `tolerations: [{operator: Exists}]` (02) |
| ClusterSPIFFEID selects 0 pods | Missing `className: zero-trust-workload-identity-manager-spire`, or the pod lacks `agent-identity: "true"` |
| SPIRE resource rejected: "must be of type string" | `managedRoute`, `k8sPSATEnabled` etc. are strings: quote `"true"` |
| `oc` login works, console shows no Copy login command | Needs the `cli` client in 04; known issue OCPBUGS-54761 (not seen on self-managed 4.22.18) |
| Copied login command fails: `x509: certificate signed by unknown authority` from `oidc discovery` | Add `--oidc-certificate-authority <keycloak-ca>` (and `--callback-port 8080`); the console omits them (OCPBUGS-147680) |
| Keycloak says "invalid parameter: redirect_url" after `oc login` | The `--callback-port` isn't a redirect URI on the CLI client: add `http://localhost:<port>` and `http://localhost:<port>/*` |
| A second DevWorkspace Operator shows Failed (`InterOperatorGroupOwnerConflict`) | Web Terminal and Dev Spaces were installed in different namespaces. Both depend on the DevWorkspace Operator, so all three must share one namespace (Dev Spaces install guide; KB 6994906). Reinstall Web Terminal in Dev Spaces' namespace (Subscription name must stay `web-terminal`) |
| Web Terminal stops working after 5 minutes | Its token isn't refreshed under external OIDC; reopen it (no fix yet, WTO-660) |
| MaaS key creation returns 500 | Authorino serving cert (RHOAIENG-103136): annotate its Service after Kuadrant reconciles, restart Authorino |
| Dashboard can't create MaaS keys for Keycloak users | With OpenShift direct authentication (step 3), Gen AI studio → API keys works: tested on RHOAI 3.5.2, 2026-11-25. RHAIRFE-3346 reports it unsupported for external OIDC users; if you hit that, create keys with the MaaS API. An empty 503 from the MaaS gateway shows up here as "unexpected end of JSON input" (see the 503 row) |
| Every MaaS request returns an empty 503 (`wasm_fail_stream` in the gateway log) | The gateway's Envoy never loaded the Kuadrant Wasm plugin (it fails closed), seen after a restart and on a newly created gateway: `oc rollout restart deployments.apps/maas-default-gateway-openshift-default -n openshift-ingress` |
| Requests through a Gateway other than MaaS (for example an MCP gateway) with a Kuadrant AuthPolicy all return 500; the Wasm log says "gRPC status code is not OK" | RHOAI turns on TLS for Authorino's gRPC port and patches only the MaaS gateway for it. Add an EnvoyFilter for your Gateway like `maas-default-gateway-authn-ssl` in `openshift-ingress` (RHOAIENG-103137) |
| OGX pod crash-loops with `storage.backends.*_postgres` errors | The default distribution needs PostgreSQL env (10) |
| Agent logs "Failed to export metrics/logs ... 404" | Collector takes traces only; 08 sets `OTEL_METRICS_EXPORTER`/`OTEL_LOGS_EXPORTER=none` |
| Trace query to Tempo times out | Query through the gateway or the console; NetworkPolicies block direct access |
| Agent B's span starts a new trace | Header names not lowercased before `propagate.extract` |

## Roll back the sign-in switch

```bash
oc replace -f auth-backup.yaml                     # with the installer kubeconfig; ~20 min rollout
oc patch gatewayconfigs.services.platform.opendatahub.io default-gateway --type=json -p '[{"op":"remove","path":"/spec/oidc"}]'
```
