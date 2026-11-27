# What the OGX and agent traces look like on the wire

For a team that receives these traces from an OpenTelemetry collector and wants to build alerts or
dashboards. Based on Red Hat OpenShift AI 3.5.2 (OGX `1.2.5.1+rhaiv.0`) and the Red Hat build of
OpenTelemetry collector. The agent-side shapes come from traces captured on a lab cluster on
2026-11-25; the OGX span and attribute names below were confirmed against four live OGX traces
(OGX 3.5.2 on OpenShift AI 3.5.2) captured on 2026-11-27 and kept under `research/live/`
(git-ignored).

## Transport and encoding

- **Protocol:** OTLP (OpenTelemetry Protocol). OGX and the agents send OTLP/HTTP protobuf to the
  collector (`:4318`); the collector forwards OTLP/gRPC (`:4317`) to Tempo, or to your endpoint if
  an exporter for it is added.
- **Shape:** the standard OTLP trace message, `ExportTraceServiceRequest`:

```
resourceSpans[]                       one per sending process
  resource.attributes[]               who sent it (service, pod, namespace, node)
  scopeSpans[]
    scope.name / scope.version        which instrumentation library made the spans
    spans[]
      traceId (16 bytes)  spanId (8 bytes)  parentSpanId (8 bytes, empty on a root span)
      name                kind (SERVER, CLIENT, INTERNAL)
      startTimeUnixNano   endTimeUnixNano
      attributes[]        key + typed value (stringValue, intValue, boolValue, ...)
      status              code UNSET, OK or ERROR, plus message
      events[]            for example an exception, with exception.type and exception.message
```

In OTLP/JSON, IDs are hex strings. Some tools, Tempo's API included, show them base64-encoded.
Durations are `endTimeUnixNano - startTimeUnixNano`.

## Resource attributes (every span)

Set by the SDK in the sending pod, plus what the collector's `k8s_attributes` processor adds:

| Attribute | Example | From |
|---|---|---|
| `service.name` | `ogx`, `Planner` | `OTEL_SERVICE_NAME` |
| `service.instance.id` | UUID | SDK |
| `telemetry.sdk.name` / `.language` / `.version` | `opentelemetry` / `python` / `1.44.0` | SDK |
| `k8s.namespace.name`, `k8s.pod.name`, `k8s.pod.uid`, `k8s.node.name`, `k8s.pod.start_time` | | collector |
| `container.image.name`, `container.image.tag` | | collector |

## Spans OGX produces

OGX runs under `opentelemetry-instrument` whenever `OTEL_SERVICE_NAME` is set (the image's
entrypoint does this), so most spans come from the standard Python auto-instrumentation libraries
bundled in the image. Their attribute names follow the OpenTelemetry semantic conventions of those
library versions; which generation of HTTP names a span carries depends on the stability opt-in
(first note below).

| Span (name pattern) | Kind | Made by | Key attributes | Live |
|---|---|---|---|---|
| `POST /v1/responses`, `POST /v1/chat/completions`, ... | SERVER | FastAPI/ASGI instrumentation, one per API request, the root of an OGX trace | HTTP attributes in the older naming: `http.method`, `http.route`, `http.status_code`, `http.target`, `http.url`, `http.scheme`, `http.host`, `http.server_name`, `http.flavor`, `http.user_agent`, `net.host.port`, `net.peer.ip`, `net.peer.port`; with `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` the current names (`http.request.method`, `http.response.status_code`, `url.path`, `url.scheme`, `client.address`, `client.port`, `server.address`, `server.port`, `user_agent.original`, `network.protocol.version`) are added next to them | yes |
| `POST /v1/responses http receive` / `... http send` | INTERNAL | the same FastAPI/ASGI instrumentation: the request and response events around the handler | `asgi.event.type`; the send spans also carry the status code (both namings with `http/dup`) | yes |
| `chat <served model id>` (for example `chat publishers/llm/models/qwen3-8b`) | CLIENT | the `opentelemetry.util.genai` handler over the GenAI instrumentation, one per model round, so a tool-calling request has two | `gen_ai.operation.name` (`chat`), `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.response.id`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `server.address` | yes |
| `POST` / `GET` / `DELETE` (method name only) | CLIENT | httpx instrumentation, one per outgoing call: the model round is a `POST`; the MCP exchange is `GET` (tool list), `POST` (tool call) and `DELETE` (session close) | `http.method`, `http.status_code`, `http.url`; with `http/dup` also `http.request.method`, `http.response.status_code`, `url.full`, `server.address`, `network.peer.address` | yes |
| `list_mcp_tools` | INTERNAL | OGX code, scope `ogx.providers.inline.responses.builtin.responses.streaming` | `server_label`, `server_url`, `mcp_list_tools_id` | yes |
| `invoke_mcp_tool` | INTERNAL | OGX code, scope `ogx.providers.inline.responses.builtin.responses.tool_executor` | `server_label`, `server_url`, `tool_name` | yes |
| `invoke_tool` | INTERNAL | OGX code (built-in tools, web search) | `tool_name` | not seen |
| `knowledge_search` / `file_search` | INTERNAL | OGX code (RAG over a vector store) | none | not seen |
| database statements (`BEGIN;`, `SELECT`, `INSERT`, `COMMIT;`, `ROLLBACK;`, `connect`) | CLIENT | asyncpg / SQLAlchemy instrumentation (PostgreSQL metadata store) | `db.system`, `db.statement`, `db.user`, `net.peer.name`, `net.peer.port` (the SQLAlchemy spans add `db.operation`) | yes |

Live marks what the four live traces of 2026-11-27 contain; the remaining rows are read from the
image source. Notes:

- **HTTP attribute naming.** With the default telemetry settings, the instrumentation in OGX
  3.5.2 emits the older semantic-convention names on its HTTP spans (`http.method`,
  `http.status_code`, `http.target`). `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` adds the current
  names next to them, so one span can carry both. Match either in dashboards and alerts;
  `ogx-trace-check.sh` accepts both and reports which it saw. Both settings ship in this repo's
  `10-ogx.yaml`.
- The OGX spans use plain keys (`tool_name`, `server_label`), not the GenAI semantic convention
  for tool spans. The OGX source marks this as a to-do, so expect these names to change in a later
  release. Build matching on them so it can change in one place.
- Prompt and completion **text is not captured** by default. The GenAI instrumentation records it
  only with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`.
- OGX adds **no user identity** to spans, confirmed on the live traces: `user.id` and `enduser.id`
  appear on none of them. With Keycloak authentication on, the user is checked but not written
  into the trace. The agents in this repo add `user.id` and `spiffe.id` themselves.
- `gen_ai.*` attribute names come from the `openai-v2` instrumentation (`2.4b0` in this image),
  which follows a still-experimental semantic convention. The names above were confirmed against
  the live traces on 2026-11-27; `gen_ai.response.finish_reasons`, which the convention lists,
  did not appear. Re-check them when the image's instrumentation version changes.
- With the default telemetry settings, the asyncpg and SQLAlchemy instrumentations add 50-100
  database spans per request (`BEGIN;`, `SELECT`, `INSERT`, `COMMIT;`, `ROLLBACK;`, `connect`),
  which bury the agent and model spans in a dashboard. Setting
  `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=asyncpg,sqlalchemy` removes them. Both settings ship in
  `10-ogx.yaml`.

## Spans the agents produce (this repo's pattern)

| Span | Kind | Attributes |
|---|---|---|
| `<Agent>.handle` | SERVER | `user.id`, `spiffe.id` (`spiffe://<trust-domain>/ns/<ns>/sa/<sa>`) |
| steps inside it | INTERNAL / CLIENT | the same two, so any span can be filtered by user or agent |

With the demo's optional MCP step, the last agent also records one real MCP call:

| Span | Kind | Attributes |
|---|---|---|
| `tools/call <tool>` | CLIENT | `user.id`, `spiffe.id`, `mcp.method.name` (`tools/call`), `gen_ai.tool.name`, `server.address` (the MCP gateway host), `http.response.status_code`, `mcp.tool.is_error`, `mcp.result.bytes`, `demo.simulated=false`, `demo.measured_duration_ms`; status ERROR when the tool reports an error |

W3C `traceparent` links an agent's call to the next agent or to OGX, so one trace ID covers the
whole user → agent → agent → OGX → model chain. W3C `baggage` carries `user.id` between agents.

## Metrics, if you take them too

OGX also sends OTLP metrics when the same variables are set (our collector currently takes traces
only, so OGX's metrics are set to `none` in `10-ogx.yaml`). OGX's own metric names, from
`ogx/telemetry/constants.py`:

`ogx.requests_total`, `ogx.request_duration_seconds`, `ogx.concurrent_requests`,
`ogx.inference.duration_seconds`, `ogx.inference.time_to_first_token_seconds`,
`ogx.inference.tokens_per_second`, `ogx.inference.model_type_used_total`,
`ogx.tool_runtime.invocations_total`, `ogx.tool_runtime.duration_seconds`,
`ogx.vector_io.*` (inserts, queries, deletes, durations), `ogx.responses.*` (parameter usage,
tool types used, agentic calls).

Metrics are usually the better base for alerts, and traces for drilling into one request.

## Starting points for alerts and dashboards

| Signal | Match on |
|---|---|
| Failed API requests | root SERVER spans of `service.name=ogx` with a 5xx (`http.response.status_code`, or `http.status_code` under the older HTTP naming) or `status.code = ERROR` |
| Slow requests | duration of the root SERVER span, by `http.route` |
| Model latency and token use | `chat <model>` spans: duration, `gen_ai.usage.input_tokens` / `output_tokens`, by `gen_ai.request.model` |
| MCP tool failures | `invoke_mcp_tool` spans with `status.code = ERROR`, by `server_label` and `tool_name` |
| Per user or per agent | `user.id`, `spiffe.id` on agent spans (not on OGX's own spans) |

## How this was established

- The OTLP structure and resource attributes: a real agent trace read back from Tempo on the lab.
- The OGX spans, attributes, metric names and auto-instrumentation: read from the OGX 3.5.2 server
  image (`registry.redhat.io/rhoai/odh-ogx-core-rhel9`): its entrypoint, its installed
  OpenTelemetry packages and its source.
- The OGX span names and attributes marked Live: confirmed against four live traces (OGX 3.5.2 on
  OpenShift AI 3.5.2) captured on 2026-11-27 and kept under `research/live/` (git-ignored): the
  default telemetry, an MCP request without a tool call, an MCP request with one tool call, and
  the final configuration with `http/dup` and the database instrumentation disabled.
- Still read from the image only, not seen live: the `invoke_tool`, `knowledge_search` and
  `file_search` spans and the metric names (the collector on that cluster took traces only).
- The Red Hat OpenShift AI 3.5 documentation does not list OGX span or attribute names. It covers
  the Gen AI Studio trace view (MLflow, Technology Preview) and the platform observability stack.
