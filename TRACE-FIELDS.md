# What each trace field is, and who sets it

For a team that receives these traces into its own logging or observability system. Span semantics,
alert recipes and console queries are in [TRACE-FORMAT.md](TRACE-FORMAT.md); setup steps are in
[GUIDE.md](GUIDE.md).

- **Data:** OpenTelemetry traces in OTLP. One trace per user request, across the agents, OGX, the
  model calls and the MCP tools.
- **Arrival:** OTLP to the Red Hat build of OpenTelemetry collector, which writes to the multitenant
  Tempo store, tenant `agents` (`X-Scope-OrgID: agents`).
- **Join key:** the trace ID (16-byte hex) joins every hop; the parent span ID orders spans inside
  it (empty on the root span).

## Resource attributes (every span of a process)

| Field | Example | Meaning | Set by |
|---|---|---|---|
| `service.name` | `ogx`, `Planner` | the sending component | `OTEL_SERVICE_NAME` on each pod |
| `service.instance.id` | `01234567-89ab-cdef-0123-456789abcdef` | one per sending process | SDK |
| `telemetry.sdk.name` / `.language` / `.version` | `opentelemetry` / `python` / `1.45.2` | SDK that produced the spans | SDK |
| `telemetry.auto.version` | `0.65b0` | version of the auto-instrumentation (OGX only) | SDK |
| `k8s.namespace.name` | `agents` | namespace of the sending pod | collector (`k8sattributes`) |
| `k8s.pod.name`, `k8s.pod.uid`, `k8s.node.name`, `k8s.pod.start_time` | | where the pod runs | collector |
| `k8s.deployment.name` | `ogx` | deployment (OGX only) | collector |
| `container.image.name` / `.tag` | `registry.access.redhat.com/ubi9/python-312` | image in the pod | collector |

## Span types

| Span name | Emitted by | Kind | When it appears |
|---|---|---|---|
| `<Agent>.handle` | agent | SERVER | once per request the agent handles; the root of that agent's part of the trace |
| `think`, `tool lookup`, `write answer` | agent | INTERNAL | the agent's work steps (this repo's demo names) |
| `call <next agent>` | agent | CLIENT | when the agent hands work to the next agent |
| `POST /v1/responses` (client) | agent, calling OGX | CLIENT | the agent's call to OGX; OGX's SERVER span nests under it |
| `tools/call <tool>` | agent, calling the MCP gateway | CLIENT | optional: the agent's own MCP gateway call (demo `--mcp-tool`) |
| `POST /v1/responses` (server) | OGX | SERVER | one per OGX API request; the root of the OGX part of the trace |
| `POST /v1/responses http receive` / `http send` | OGX | INTERNAL | the request and response events around the handler (ASGI) |
| `chat <served model id>` | OGX, calling the model | CLIENT | one per model round; two rounds when the model calls a tool |
| `POST` / `GET` / `DELETE` (method name only) | OGX, calling out | CLIENT | outgoing calls: the model round (`POST`), the MCP exchange (`GET`, `POST`, `DELETE`), the Keycloak certificate fetch (`GET`) |
| `list_mcp_tools` | OGX, MCP handling | INTERNAL | every request to an MCP-enabled model: OGX lists the server's tools |
| `invoke_mcp_tool` | OGX, MCP handling | INTERNAL | when the model calls an MCP tool |
| Keycloak spans | Keycloak | SERVER, CLIENT | only when Keycloak tracing is on (`--tracing-enabled=true`); Keycloak sends its own traces for its HTTP, database, LDAP and outgoing calls |

With default telemetry OGX also emits 50-100 PostgreSQL spans per request (`BEGIN;`, `SELECT`,
`INSERT`, `COMMIT;`, `ROLLBACK;`, `connect`). The shipped `manifests/10-ogx.yaml` disables them.

## Span attributes

Trust says who asserts the value: **agent** (written by the agent itself), **OGX** (recorded by OGX
or its instrumentation), **Keycloak** (recorded by Keycloak). OGX's HTTP spans carry the older
semantic-convention names; `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` (set in the shipped
`manifests/10-ogx.yaml`) adds the current names next to them, so one span can carry both. Rows show both,
older first.

| Field | Example | Meaning | Emitted by | Trust |
|---|---|---|---|---|
| `user.id` | `alice` | user the request acts for; carried between agents in W3C baggage | agents | agent |
| `spiffe.id` | `spiffe://example.com/ns/agents/sa/planner` | workload identity of the agent; the same namespace and service account that MaaS authorizes | agents | agent |
| `demo.simulated` | `true` | `true` for a simulated demo step, `false` for a measured real call | agents | agent |
| `demo.step` | `1` | position of the agent in the demo chain | agents | agent |
| `demo.measured_duration_ms` | `15509.3` | measured wall time of a real call | agents | agent |
| `demo.response.bytes` | `5029` | response body size of a real call | agents | agent |
| `http.request.method`, `http.response.status_code` | `POST`, `200` | the agent's call to OGX | agents | agent |
| `gen_ai.request.model` | `vllm-inference/publishers/llm/models/qwen3-8b` | model the agent requested | agents | agent |
| `server.address` | `ogx-service.agents.svc.cluster.local:8321` | host the agent called (OGX on this span; the MCP gateway host on `tools/call`) | agents | agent |
| `mcp.method.name` | `tools/call` | MCP method of the call | agents (`tools/call`) | agent |
| `gen_ai.tool.name` | `openshift_pods_list_in_namespace` | tool called through the MCP gateway | agents (`tools/call`) | agent |
| `mcp.tool.is_error` | `false` | whether the tool reported an error | agents (`tools/call`) | agent |
| `mcp.result.bytes` | `1234` | size of the tool result | agents (`tools/call`) | agent |
| `http.method`; `http.request.method` | `POST` | request method (older; current) | OGX (SERVER span) | OGX |
| `http.status_code`; `http.response.status_code` | `200` | response status (older; current) | OGX (SERVER span) | OGX |
| `http.route`; `url.path` | `/v1/responses` | matched route (older; current) | OGX (SERVER span) | OGX |
| `http.target` | `/v1/responses` | request target (older naming) | OGX (SERVER span) | OGX |
| `http.url`; `url.full` | `http://ogx-service.agents.svc.cluster.local:8321/v1/responses` | request URL (older; current) | OGX (SERVER span) | OGX |
| `http.scheme`; `url.scheme` | `http` | scheme (older; current) | OGX (SERVER span) | OGX |
| `http.host`; `server.address` | `10.129.0.5:8321` | host the request was addressed to (older; current) | OGX (SERVER span) | OGX |
| `http.server_name` | `ogx-service.agents.svc.cluster.local:8321` | server name of the API (older naming) | OGX (SERVER span) | OGX |
| `http.flavor`; `network.protocol.version` | `1.1` | HTTP version (older; current) | OGX (SERVER span) | OGX |
| `http.user_agent`; `user_agent.original` | `Python-urllib/3.12` | caller's user agent (older; current) | OGX (SERVER span) | OGX |
| `net.host.port`; `server.port` | `8321` | listening port (older; current) | OGX (SERVER span) | OGX |
| `net.peer.ip`; `client.address` | `10.129.0.7` | caller address, the agent pod IP (older; current) | OGX (SERVER span) | OGX |
| `net.peer.port`; `client.port` | `60640` | caller port (older; current) | OGX (SERVER span) | OGX |
| `asgi.event.type` | `http.request`, `http.response.start` | request or response event, on the `http receive` / `http send` spans | OGX (ASGI) | OGX |
| `http.method`; `http.request.method` | `POST` | method of the outgoing call (older; current) | OGX (outgoing calls) | OGX |
| `http.status_code`; `http.response.status_code` | `200` | response status of the outgoing call (older; current) | OGX (outgoing calls) | OGX |
| `http.url`; `url.full` | `https://mcp-gateway.apps.example.com/mcp` | target of the outgoing call (older; current) | OGX (outgoing calls) | OGX |
| `server.address`, `network.peer.address` | `mcp-gateway.apps.example.com` | peer host (current naming; added by `http/dup` on these spans too) | OGX (outgoing calls) | OGX |
| `gen_ai.operation.name` | `chat` | operation name | OGX (`chat` span) | OGX |
| `gen_ai.provider.name` | `openai` | provider of the model API | OGX (`chat` span) | OGX |
| `gen_ai.request.model` | `publishers/llm/models/qwen3-8b` | model requested (served id) | OGX (`chat` span) | OGX |
| `gen_ai.request.max_tokens` | `4096` | output limit sent to the model | OGX (`chat` span) | OGX |
| `gen_ai.response.id` | `chatcmpl-01234567-89ab-cdef-0123-456789abcdef` | response ID the model returned | OGX (`chat` span) | OGX |
| `gen_ai.response.model` | `qwen3-8b` | model that produced the response | OGX (`chat` span) | OGX |
| `gen_ai.usage.input_tokens` | `445` | prompt tokens of the round | OGX (`chat` span) | OGX |
| `gen_ai.usage.output_tokens` | `199` | completion tokens of the round | OGX (`chat` span) | OGX |
| `openai.request.service_tier` | `default` | service tier reported by the model API | OGX (`chat` span) | OGX |
| `server.address` | `maas.apps.example.com` | model endpoint host | OGX (`chat` span) | OGX |
| `server_label` | `mcp-gateway` | OGX's label for the MCP server, from the request | OGX (MCP spans) | OGX |
| `server_url` | `https://mcp-gateway.apps.example.com/mcp` | MCP server URL | OGX (MCP spans) | OGX |
| `mcp_list_tools_id` | `mcp_list_01234567-89ab-cdef-0123-456789abcdef` | ID of the tool list returned | OGX (`list_mcp_tools`) | OGX |
| `tool_name` | `openshift_pods_list_in_namespace` | tool the model called | OGX (`invoke_mcp_tool`) | OGX |
| `kc.clientId` | `ogx-api` | client that started the request | Keycloak | Keycloak |
| `kc.realmName` | `rhoai` | realm of the request | Keycloak | Keycloak |
| `kc.sessionId` | `01234567-89ab-cdef-0123-456789abcdef` | user session ID | Keycloak | Keycloak |
| `kc.token.id`, `kc.token.issuer`, `kc.token.sid` | | token ID, issuer and session from the presented token | Keycloak | Keycloak |
| `kc.authenticationSessionId`, `kc.authenticationTabId` | | authentication session identifiers | Keycloak | Keycloak |

The `kc.*` tags appear only when Keycloak tracing is turned on; Keycloak tracing was off during our
captures, so those names come from the Red Hat build of Keycloak 26.6 Observability Guide
("Information in traces") and not from the captures. All other values above were confirmed against
live OGX 3.5.2 traces captured on 2026-11-27 (kept under `research/live/`, git-ignored).

## Notes for the receiving team

1. **OGX spans carry no identity.** `user.id` and `enduser.id` appear on none of OGX's own spans.
   Attribute OGX work to a user by joining through the trace ID to the agent spans, or add your own
   identity attributes at the gateway.
2. **Agent identity is asserted, not verified.** The agents write `user.id` and `spiffe.id`
   themselves; nothing checks them before the traces are stored. Treat both as claims from the
   sending pod. Enforcing them is a separate topic (see GUIDE.md).
3. **Personal and sensitive data.** `user.id` is a user name, so it is personal data. Prompt and
   completion text is not recorded: OGX captures it only with
   `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`, and no prompt or completion attributes
   appeared on any captured span; check the setting on your deployment. With default telemetry,
   `db.statement` records full SQL, including the stored response content. Keycloak tags carry
   session and token identifiers. Apply your retention and access rules to these fields.
4. **High-cardinality fields.** The trace ID and span IDs, `gen_ai.response.id`, `mcp_list_tools_id`,
   `kc.sessionId`, `k8s.pod.uid`, `client.address` and `client.port` are unique per request or per
   session. Do not use them as metric dimensions; filter or query on them instead.
5. **The OGX names are pre-standard.** OGX's tool spans use plain keys (`tool_name`, `server_label`)
   where the GenAI semantic convention would use different ones; the OGX source marks this as a
   to-do. The `gen_ai.*` names follow an experimental convention, and `gen_ai.response.finish_reasons`
   did not appear. Expect changes in later OGX releases; keep your matching in one place.
