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
- **Decide the trust domain now.** It cannot be changed later without rebuilding SPIRE.
- **FIPS cluster?** ZTWIM is not supported there (KB 7144070). Stop and raise it.
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

This turns off OpenShift's built-in OAuth for everyone. Keep the installation program's kubeconfig (it keeps
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
users, or add the CAs to their system truststore.

If the dashboard login loops or uses an old secret: `oc delete secret kube-auth-proxy-creds -n
openshift-ingress`, wait for it to return, `oc rollout restart deploy/kube-auth-proxy -n openshift-ingress`.

**Groups and access.** After the switch there are no OpenShift `User` or `Group` objects: group
membership comes only from the token's `groups` claim, so `oc get groups` no longer tells you who is in
what. RoleBindings and ClusterRoleBindings whose subject is a Group keep working only when a Keycloak
group of exactly that name exists and holds the users (04 maps the claim with no prefix, and the realm's
group mapper has full path off, so `maas-users` stays `maas-users`). Before the change window, list every
binding to a Group and create those groups in Keycloak with their members:

```bash
oc get clusterrolebindings,rolebindings -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.subjects[?(@.kind=="Group")].name}{"\n"}{end}' \
  | grep -v ': $' | grep -v 'system:'
```
Groups that came from an htpasswd provider or an LDAP group sync
stop applying the moment the switch completes. A user's own name keeps matching because 04 uses
`preferred_username` with no prefix.

**Other apps that sign in through OpenShift.** Anything that uses an OpenShift OAuth client or an
oauth-proxy sidecar stops at a login page after the switch, because there is no OAuth server to send it
to. List them before the window (`oc get oauthclients`, and Deployments with an `oauth-proxy`
container) and move each one to its own Keycloak client. Two common ones: Open WebUI has native OIDC
(`OPENID_PROVIDER_URL`, `OAUTH_CLIENT_ID`, a groups claim for roles), and OpenShift GitOps cannot use
Dex's OpenShift connector any more: set `spec.oidcConfig` on the ArgoCD CR against Keycloak and remove
`spec.sso` (the two together fail validation). Keep the Argo CD admin password until Keycloak sign-in is
proven. Dev Spaces follows.

The Argo CD client is a confidential client with standard flow on, direct access grants off, and no
PKCE requirement: Argo CD's server-side flow sends no `code_challenge_method`, so requiring PKCE fails
every sign-in. Argo CD requests the scope named `groups`, so the realm needs a client scope with that
name (include in token scope, one group membership mapper), assigned as a default client scope of the
client. Put the client secret in a Secret of its own in the instance namespace, labeled
`app.kubernetes.io/part-of: argocd`, and point `spec.oidcConfig.clientSecretRef` at it. Switching an
existing instance is a one-time `oc patch` that removes `spec.sso`, then a restart of the instance's
server Deployment before its sessions verify against the root CA.

**OpenShift Lightspeed** needs each user's uid to be a UUID (OCPBUGS-141930). Keycloak's `sub` claim
is one, so the default mapping works; do not map the uid to another claim.

### Dev Spaces (if installed)

Dev Spaces signs in through the OpenShift OAuth server by default, so after step 3 its login fails until
it uses Keycloak (Dev Spaces install guide, "Use an external identity provider for authentication"):
a confidential Keycloak client `devspaces` (redirect `<cheURL>/oauth/callback`, web origin `<cheURL>`),
`devspaces` added to the audiences in 04 (another ~20 min API rollout), a Secret `oauth-secret` (key
`oAuthSecret`) and, for a private CA, a `keycloak-certs` ConfigMap labeled
`app.kubernetes.io/component=ca-bundle` in `openshift-devspaces`, then on the CheCluster:
`spec.networking.auth.oAuthClientName: devspaces`, `oAuthSecret: oauth-secret`,
`identityProviderURL: <issuer>`, `gateway.oAuthProxy.cookieExpireSeconds: 300`, and the oauth-proxy
env `OAUTH2_PROXY_CODE_CHALLENGE_METHOD=S256`. Dev Spaces, the DevWorkspace Operator and Web Terminal
must be installed in one namespace. A workspace gets a kubeconfig with the user's own token, which
is not refreshed: `oc` in the workspace works for about 5 minutes after it starts (CRW-14511).

## 4. Models, OGX, agents (~30 min)

```bash
vi 06-maas-access.yaml                             # set <model> and <model-ns>
./render.sh 06-maas-access.yaml --apply            # Keycloak group + agent service accounts
./render.sh 10-ogx.yaml --check                    # add the PostgreSQL environment variables first (see file notes)
./render.sh 10-ogx.yaml --apply
./render.sh 12-example-agent.yaml --apply          # replace the image with your agent
```

When auth is on, OGX (10-ogx.yaml) accepts only Keycloak tokens whose `aud` claim includes the
`ogx-api` audience; how to mint one for the demo is in section 5.

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

In the console instead: **Observe → Traces**, pick TempoStack `agents`, tenant `agents`, and filter on
`user.id` or `spiffe.id`.

## 7. Demo: a fresh trace at any time

`demo-trace.sh` makes a "user → agent → agent" trace for any agents, without touching their code. For
each agent, in order, it runs a short-lived pod **as that agent's service account**, so each step
carries the agent's real SPIFFE ID. The work is a stand-in: each agent's span shows a few steps (think,
tool lookup, call the next agent, write answer) on a staged timeline of a few seconds per agent, so the
console's timeline view reads like a real request. Those steps carry `demo.simulated=true`; set
`DEMO_PACE=2` to double the timing.

```bash
cp demo.env.example demo.env && vi demo.env       # DEMO_USER and DEMO_AGENTS (namespace/serviceaccount=Name)
./demo-trace.sh --dry-run                          # shows the hops; checks the service accounts exist
./demo-trace.sh                                    # prints the trace ID, console link and the chain
./demo-trace.sh --user bob agents/planner=Planner agents/researcher=Researcher   # or on the command line
```

In the console, open **Observe → Traces**, choose the TempoStack and tenant, and widen the time range
if the trace is not listed: the default window can miss a trace made a few minutes earlier, and a
trace from an earlier run only shows with a range that covers it (for example "Last 24 hours").

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

**Contrast step.** `--mcp-contrast namespace/serviceaccount=Name` (or `DEMO_MCP_CONTRAST`) adds one
more hop after the last agent, run as that service account, which makes the same tool call with the
same arguments. Make that account with no permissions, so the refusal is the point:

```bash
oc create sa demo-no-rbac -n agents    # no RoleBindings: the account has no permissions
```

The MCP server runs each tool with the caller's own token, so the account without RBAC is refused
(`forbidden`). The trace then shows two `tools/call` spans in the same waterfall: one `ok`
(`mcp.tool.is_error=false`) from the agent with rights, and one error from the contrast account
(`mcp.tool.is_error=true`, the refusal text truncated in the span status, `demo.simulated=false`).
The script prints the refusal as an expected result and exits 0. If the contrast account is NOT
refused, the script says so: check that the account has no RoleBindings in its namespace. The flag
requires `--mcp-tool`.

For agents that are already instrumented and expose HTTP, `./demo-trace.sh --user alice --entry-url
https://<agent>` sends one request with a new trace and the user in baggage, and the real agents carry
it on.

**OGX hop.** `--ogx-url <server>` (or `DEMO_OGX_URL`) makes the last agent end its run with one real
request to OGX, `POST <url>/v1/responses` with model `DEMO_OGX_MODEL` (default
`vllm-inference/publishers/llm/models/qwen3-8b`: OGX lists a model under its provider id plus the
MaaS name, and answers 404 to the bare MaaS name). The request carries the agent's traceparent and `user.id` in
baggage, so OGX's spans continue the same trace under a `POST /v1/responses` client span recorded by
the agent (`demo.simulated=false`, the real HTTP status):

```bash
DEMO_OGX_TOKEN=<keycloak-user-token> ./demo-trace.sh --user alice --ogx-url http://ogx-server.agents.svc.cluster.local:8321 \
  --ogx-mcp agents/planner=Planner agents/researcher=Researcher
```

The token must be one OGX accepts: with `AUTH_ISSUER` and `AUTH_AUDIENCE` set (10-ogx.yaml), OGX
accepts only Keycloak tokens whose `aud` claim includes the `ogx-api` audience — the agent's
service account token will not work. The realm template (00-keycloak-realm-clients.json) provides
that audience through an optional client scope named `ogx-api`: the scope adds `ogx-api` to `aud`
when, and only when, the client asks for scope `openid ogx-api`, so ordinary sign-in tokens stay
unchanged. Mint `DEMO_OGX_TOKEN` as a user token requested with scope `openid ogx-api`: a direct
request to the realm's token endpoint, in the shape `scripts/lib-oc-token.sh` (cluster repository)
makes, with the extra scope; that script's plain `openid` token does not carry the audience. Pass
the token through `DEMO_OGX_TOKEN`; it is never printed. Without it, an OGX with auth on refuses
the request
with 401 and the span shows the refusal, which is a useful negative case. `--ogx-mcp`
(`DEMO_OGX_MCP=1`) hands OGX the MCP gateway as a tool server, so OGX produces `list_mcp_tools` and
`invoke_mcp_tool` spans in the same trace; OGX's service account then needs the gateway RBAC the
agents have. `ogx-trace-check.sh <trace id>` checks the trace against every expectation in
TRACE-FORMAT.md's OGX section and prints PASS or FAIL per field.

What to say in the demo: each step shows *which agent* (its SPIFFE identity) acted for *which user*.
Those two labels are written by the agents (here, by the probe) and are not yet verified by the platform.
Platform-verified identity on every step is a request to Red Hat.

The probe pods install `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http` and `spiffe`
with pip. On a disconnected cluster, set `IMAGE` in `demo.env` to an image that has them.

## 8. MCP tools through the MCP gateway

Red Hat Connectivity Link 1.5 ships the MCP gateway: agents call MCP servers through the cluster
ingress instead of reaching each server directly, and every call is authenticated with the identity
work in this guide.

Register each server with an HTTPRoute plus an MCPServerRegistration, following the Connectivity
Link 1.5 guide "Register MCP servers and create policies". Two details that guide does not
underline:

- The gateway's public listener and the internal `*.mcp.local` listener that the server routes
  attach to must use the same port. The controller matches registrations to the
  MCPGatewayExtension by listener port, and a mismatch leaves every registration NotReady.
- A listener without a hostname needs `spec.publicHost` on the MCPGatewayExtension, or the
  gateway cannot advertise the server's public URL.

With OpenShift AI on the cluster, give the gateway TLS to Authorino with an EnvoyFilter like
`maas-default-gateway-authn-ssl`; without it, every authenticated request returns 500
(troubleshooting has the row). A Kuadrant AuthPolicy with `kubernetesTokenReview` on the gateway
then accepts both kinds of caller this guide creates: agent ServiceAccount tokens and Keycloak
user tokens under OpenShift direct authentication.

The MCP server for Red Hat OpenShift is a worked example (OpenShift 4.22 "AI applications";
Technology Preview, Helm chart `redhat-openshift-mcp-server`). Install it read-only, denying
Secrets, with no public Route. It runs each tool with the caller's own token, so OpenShift RBAC
decides per user and per agent: an admin listed pods, a user without rights got `forbidden`. The
demo's `--mcp-tool` option shows this in a trace (7).

The gateway lists each server's tools only to clients whose MCP protocol version that server
supports, and it reads a server's versions from its handshake. A server that answers the handshake
in only one version (for example the Red Hat Offline Knowledge Portal MCP server) disappears from the
tool list of clients on the other version. Set `spec.supportedProtocolVersions` on its
MCPServerRegistration to the versions it really serves.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod has no `/spiffe-workload-api/spire-agent.sock` | No spire-agent on that node: keep `tolerations: [{operator: Exists}]` (02) |
| ClusterSPIFFEID selects 0 pods | Missing `className: zero-trust-workload-identity-manager-spire`, or the pod lacks `agent-identity: "true"` |
| SPIRE resource rejected: "must be of type string" | `managedRoute`, `k8sPSATEnabled` etc. are strings: quote `"true"` |
| `oc` login works, console shows no Copy login command | Needs the `cli` client in 04; known issue OCPBUGS-54761 (not seen on self-managed 4.22.18) |
| Copied login command fails: `x509: certificate signed by unknown authority` from `oidc discovery` | Add `--oidc-certificate-authority <keycloak-ca>` (and `--callback-port 8080`); the console omits them (OCPBUGS-147680) |
| Keycloak says "invalid parameter: redirect_url" after `oc login` | The `--callback-port` is not a redirect URI on the CLI client: add `http://localhost:<port>` and `http://localhost:<port>/*` |
| A second DevWorkspace Operator shows Failed (`InterOperatorGroupOwnerConflict`) | Web Terminal and Dev Spaces were installed in different namespaces. Both depend on the DevWorkspace Operator, so all three must share one namespace (Dev Spaces install guide; KB 6994906). Reinstall Web Terminal in Dev Spaces' namespace (Subscription name must stay `web-terminal`) |
| Web Terminal stops working after 5 minutes | Its token is not refreshed under external OIDC; reopen it (no fix yet, WTO-660) |
| MaaS key creation returns 500 | Authorino serving cert (RHOAIENG-103136): annotate its Service after Kuadrant reconciles, restart Authorino |
| Dashboard cannot create MaaS keys for Keycloak users | With OpenShift direct authentication (step 3), Gen AI studio → API keys works: tested on RHOAI 3.5.2, 2026-11-25. RHAIRFE-3346 reports it unsupported for external OIDC users; if you hit that, create keys with the MaaS API. An empty 503 from the MaaS gateway shows up here as "unexpected end of JSON input" (see the 503 row) |
| Every MaaS request returns an empty 503 (`wasm_fail_stream` in the gateway log) | The gateway's Envoy never loaded the Kuadrant Wasm plugin (it fails closed), seen after a restart and on a newly created gateway: `oc rollout restart deployments.apps/maas-default-gateway-openshift-default -n openshift-ingress` |
| Requests through a Gateway other than MaaS (for example an MCP gateway) with a Kuadrant AuthPolicy all return 500; the Wasm log says "gRPC status code is not OK" | RHOAI turns on TLS for Authorino's gRPC port and patches only the MaaS gateway for it. Add an EnvoyFilter for your Gateway like `maas-default-gateway-authn-ssl` in `openshift-ingress` (RHOAIENG-103137) |
| MCP server registrations NotReady: `no matching mcpgatewayextensions for attached listener` | The public listener and the internal `*.mcp.local` listener do not share the same port; the controller matches registrations to the MCPGatewayExtension by listener port (8) |
| `tools/call` fails with: `Kagenti MCP Broker does not forward tool calls` | The extension's router EnvoyFilter is missing (the extension is not Ready) or stale after a listener port change: delete it so the controller recreates it (8) |
| A registered MCP server's tools are missing from `tools/list` for some clients | The gateway partitions tools by MCP protocol version; set `spec.supportedProtocolVersions` on the server's MCPServerRegistration (8) |
| Users lose access they had through a Group after the switch | Group membership now comes only from the token's `groups` claim: create the Keycloak group with the same name and add the users (3) |
| An app shows a login page that never completes after the switch | It uses an OpenShift OAuth client or oauth-proxy; give it its own Keycloak client (3) |
| OGX pod crash-loops with `storage.backends.*_postgres` errors | The default distribution needs PostgreSQL env (10) |
| Agent logs "Failed to export metrics/logs ... 404" | Collector takes traces only; 08 sets `OTEL_METRICS_EXPORTER`/`OTEL_LOGS_EXPORTER=none` |
| Trace query to Tempo times out | Query through the gateway or the console; NetworkPolicies block direct access |
| Agent B's span starts a new trace | Header names not lowercased before `propagate.extract` |

## Roll back the sign-in switch

```bash
oc replace -f auth-backup.yaml                     # with the installer kubeconfig; ~20 min rollout
oc patch gatewayconfigs.services.platform.opendatahub.io default-gateway --type=json -p '[{"op":"remove","path":"/spec/oidc"}]'
```
