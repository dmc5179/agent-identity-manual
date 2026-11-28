# Agent identity on OpenShift 4.22 with an external Keycloak: manual YAML

Bare YAML for a cluster where the operators are **installed but not configured**: ZTWIM, Red Hat
OpenShift AI 3.5 (OGX, MaaS), Connectivity Link 1.5, Red Hat build of OpenTelemetry, Tempo, the
Cluster Observability Operator and OpenShift Service Mesh 3. No AutoShift, one optional Helm step (the MCP server for Red Hat OpenShift, in 14).

**Start with [QUICKSTART.md](QUICKSTART.md)**, a one-page path to build the environment and run the demo. [GUIDE.md](GUIDE.md) has the steps, commands, checks and troubleshooting. Helpers: `render.sh` (fills
`vars.env` into a file, then prints, dry-runs or applies it), `verify.sh` (one line per component), `trace-query.sh`
(prints one trace with the user and SPIFFE ID on each hop), `demo-trace.sh` (a fresh user → agent → agent trace
for any agents you name, optionally with a real MCP tool call), `show-identity.sh` (one agent pod's identity,
printed from inside the pod: the projected service account token's claims with the remaining lifetime, the
SPIFFE workload API socket, the SPIFFE ID, and the pod's service account), `ogx-token.sh` (the Keycloak user
token with the `ogx-api` audience OGX requires, for the demo's OGX hop), and `demo-run.sh` (the
whole demo in one command: pre-flight, the agent chain, the contrast run, the OGX hop, and a summary
with the trace IDs). [TRACE-FORMAT.md](TRACE-FORMAT.md) describes
the traces on the wire, for a team building alerts or dashboards on them. [TRACE-FIELDS.md](TRACE-FIELDS.md)
is the short field reference for a team receiving the traces into their own logging or observability
system.

Not perfect, a starting point. Each file says what it does, links the Red Hat doc, and lists the known
issues that affect it.

## How the pieces fit

- **Keycloak** (outside the cluster) says who the *person* is. OpenShift, the RHOAI dashboard, MaaS
  and OGX all trust its tokens.
- **ZTWIM/SPIRE** says which *agent* (workload) is calling: `spiffe://<trust-domain>/ns/<ns>/sa/<sa>`,
  as short-lived X.509 and JWT SVIDs from a socket in the pod.
- The SPIFFE ID uses the same namespace and service account that MaaS authorizes
  (`system:serviceaccounts:<ns>`), so agents have one identity for both.
- **Tracing** (OpenTelemetry → Tempo → console Observe → Traces) shows the call chain, if each agent
  tags its spans with the user and its SPIFFE ID. No product dashboard does this for you.
- Linking "user X → agent A → agent B" so it can be *enforced* needs Keycloak token exchange: custom
  work, with no Red Hat pattern yet.

## Order

The numbered files are in [`manifests/`](manifests/), in apply order; the scripts and docs stay at the top level. `./render.sh manifests/NN-name.yaml` (or just `NN-name.yaml`) renders one.

| Step | File | Depends on | Disruptive? |
|---|---|---|---|
| 0 | `manifests/00-keycloak-realm-clients.json` (in Keycloak) | – | no |
| 1 | `manifests/01-ztwim.yaml` | ZTWIM operator | no |
| 2 | `manifests/02-spire.yaml` | 01 Ready (trust domain, cluster name) | no |
| 3 | `manifests/03-agent-spiffe-ids.yaml` | 02 pods Running | no |
| 4 | `manifests/04-openshift-external-oidc.yaml` | 0; CA ConfigMap and console Secret first | **YES**: OAuth server off, ~20 min API rollout |
| 5 | `manifests/05-rhoai-gateway-oidc.yaml` | 4 rolled out; gateway Secret first | dashboard sessions reset |
| 6 | `manifests/06-maas-access.yaml` | 4 | no |
| 7 | `manifests/07-tempo.yaml` | Tempo operator | no |
| 8 | `manifests/08-opentelemetry.yaml` | 7 | no |
| 9 | `manifests/09-tracing-ui.yaml` | 7, COO | no |
| 10 | `manifests/10-ogx.yaml` | 0, 8 | no |
| 11 | `manifests/11-authpolicy-agent-or-user.yaml` (optional) | 2, RHCL, an HTTPRoute | no |
| 12 | `manifests/12-example-agent.yaml` | 3, 8 | no |
| 13 | `manifests/13-service-mesh.yaml` (optional) | see the file: read before applying | can break Gateway API |
| 14 | `manifests/14-mcp-gateway.yaml` | Connectivity Link 1.5 (MCP gateway operator), a Kuadrant CR; the MCP server for Red Hat OpenShift installed by Helm; apply before 17 | no |
| 15 | `manifests/15-nemo-mcp-guardrails.yaml` (optional) | 14; the TrustyAI component Managed in the DataScienceCluster | no |
| 16 | `manifests/16-console-dashboards.yaml` (optional) | 9 (COO), RHOAI MaaS | no |
| 17 | `manifests/17-playground-mcp.yaml` (optional) | 14 (MCP gateway); a tool-calling model and a playground in one project | no |

ZTWIM first, then SPIRE, as SPIRE reads the trust domain and cluster name from the ZTWIM resource.
If you plan to use SPIRE as the Service Mesh CA (13), set `CREATE_ONLY_MODE=true` on the ZTWIM
Subscription **before step 2**, as OSSM 3.5 Installing 7.3.1 orders it (whether it can be added later is untested).
Tracing (7, 8, 9) should exist before agents and OGX start, or their first spans are lost.
Steps 1–3 and 7–9 do not depend on the sign-in switch, so they can be done before the change window
for step 4.

## Apply

```bash
cp vars.env.example vars.env && vi vars.env
set -a; . ./vars.env; set +a
VARS="$(sed -n 's/^\([A-Z_]*\)=.*/${\1}/p' vars.env | tr '\n' ' ')"
render() { envsubst "$VARS" < "$1"; }
render manifests/01-ztwim.yaml | oc apply --dry-run=server -f -   # check first
render manifests/01-ztwim.yaml | oc apply -f -
```

Files with `<placeholders>` (model names, route names) need editing by hand. Secrets are never in the
files: each file gives the `oc create secret` command.

## What was checked

| File | Checked how |
|---|---|
| 01, 02, 03, 12 | Applied on our lab (OCP 4.22.18, ZTWIM 1.1.3), 2026-11-24. An agent pod received X.509 and a 5-minute JWT-SVID; the JWT issuer matched SPIRE's discovery endpoint. Test resources deleted afterwards |
| 04, 05 | **Applied on our lab 2026-11-24** (OCP 4.22.18, RHOAI 3.5.2) to switch it to an in-cluster Keycloak, permanently: API server rollout, `oc` and console login with Keycloak tokens, RHOAI dashboard through Keycloak (cookie refresh 4m), MaaS keys minted with Keycloak tokens. Found and fixed: the placeholder CA ConfigMap in 04. Seen: the console's Copy login command omits `--oidc-certificate-authority`/`--callback-port`; the Web Terminal token expires after 5 minutes (WTO-660) |
| Dev Spaces (GUIDE) | Applied on the lab 2026-11-25: `devspaces` client and audience, `networking.auth`; Keycloak login works. Workspaces get a kubeconfig with the user's token, not refreshed (works ~5 min) |
| 06, 10, 11 | Server-side dry-run on the lab (RHOAI 3.5.2, RHCL 1.5.0) |
| 07, 08, 09 | Applied on our lab 2026-11-24 (Tempo operator 0.22.0-5, OTel 0.158, COO 1.5.5): a trace showed user -> agent A -> agent B with both SPIFFE IDs and the user carried in baggage |
| 13 | From the Red Hat docs only; Service Mesh is not on our lab |
| `demo-trace.sh` MCP step | Run on the lab 2026-11-25 with and without `--mcp-tool`: the last agent's `tools/call` through the Connectivity Link 1.5 MCP gateway to the MCP server for Red Hat OpenShift, authenticated as the agent's service account; the server applied the agent's own RBAC |
| `demo-run.sh` | Verified offline: `bash -n`, `shellcheck` with 0 warnings, `--help`, and the step flow (full run, `--dry-run`, `--skip-ogx`, `--step 3`, a failing step) against stub helpers. Not yet run against the lab |
| `show-identity.sh` | Verified offline: `bash -n`, `shellcheck` with 0 warnings, and the inline Python against a fake JWT (claims, remaining lifetime, no token or signature printed) and a stub `oc` (default target from `demo.env`, `--help`, a failed login). The SPIFFE ID fallback path is exercised; a live py-spiffe fetch is not (needs a cluster) |
| TRACE-FORMAT.md | OTLP structure from a real trace read back from Tempo; OGX span names read from the OGX 3.5.2 server image and confirmed against live OGX traces (2026-11-27); metric names read from the image |
| 15 | Applied and tested on our lab (2026-11-28, OpenShift 4.22, RHOAI 3.5.2, RHCL 1.5): a normal tool call passes, one with an email address in its arguments is refused with 403 "blocked by guardrails". NeMo Service `nemo-guardrails` port 80, `enable-auth: false`; PERSON detection left out after it blocked an ordinary pod list. |
| 16 | Patch targets and fields from the RHOAI 3.5 docs and `oc explain` on 3.5.2; the four queries are metrics that carried data on the lab's user-workload monitoring (2026-11-27). Not applied: copy the datasource from `dashboard-3-maas-usage-admin` first (the file says how) |
| 17 | The ConfigMap entry format, the MCP tab flow, gateway acceptance of `ogx-token.sh` tokens, and the per-user RBAC result were checked on our lab (RHOAI 3.5.2, 2026-11-27), from the RHOAI 3.5 playground docs. The OGXServer TLS patch is not verified: the dashboard creates and may rewrite that object (check: in the file) |

## Sources

- OCP 4.22 *Security and compliance*, ch. 12 (ZTWIM)
- OCP 4.22 *Authentication and authorization*, ch. 8 (direct external OIDC)
- RHOAI 3.5 *Administer OpenShift AI*, ch. 10; *Govern LLM access with Models-as-a-Service*; *Build
  AI/Agentic Applications with OGX*
- Red Hat build of OpenTelemetry, Tempo, Cluster Observability Operator, OSSM 3 docs (see 07–09, 13, 16)
- Red Hat Jira, swept 2026-11-24 for known issues (cited in each file)
