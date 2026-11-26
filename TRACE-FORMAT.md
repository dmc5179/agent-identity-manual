# What the OGX and agent traces look like on the wire

For a team that receives these traces from an OpenTelemetry collector and wants to build alerts or
dashboards. Based on Red Hat OpenShift AI 3.5.2 (OGX `1.2.5.1+rhaiv.0`), the Red Hat build of
OpenTelemetry collector, and traces captured on a lab cluster on 2026-11-25.

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
bundled in the image. Their attribute names follow the OpenTelemetry semantic conventions for those
library versions.

| Span (name pattern) | Kind | Made by | Key attributes |
|---|---|---|---|
| `POST /v1/responses`, `POST /v1/chat/completions`, ... | SERVER | FastAPI/ASGI instrumentation, one per API request, the root of an OGX trace | `http.request.method`, `http.route`, `url.path`, `http.response.status_code`, `server.address` |
| `chat <model>` | CLIENT | `openai-v2` GenAI instrumentation, one per model call | `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.response.finish_reasons` |
| `POST` (to the model or MCP server) | CLIENT | httpx instrumentation | `http.request.method`, `url.full`, `server.address`, `http.response.status_code` |
| `list_mcp_tools` | INTERNAL | OGX code | `server_label`, `server_url`, `mcp_list_tools_id` |
| `invoke_mcp_tool` | INTERNAL | OGX code | `server_label`, `server_url`, `tool_name` |
| `invoke_tool` | INTERNAL | OGX code (built-in tools, web search) | `tool_name` |
| `knowledge_search` / `file_search` | INTERNAL | OGX code (RAG over a vector store) | none |
| database statements | CLIENT | asyncpg / SQLAlchemy instrumentation (PostgreSQL metadata store) | `db.system`, `db.operation`, `server.address` |

Notes:

- The OGX spans use plain keys (`tool_name`, `server_label`), not the GenAI semantic convention
  for tool spans. The OGX source marks this as a to-do, so expect these names to change in a later
  release. Build matching on them so it can change in one place.
- Prompt and completion **text is not captured** by default. The GenAI instrumentation records it
  only with `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true`.
- OGX adds **no user identity** to spans. With Keycloak authentication on, the user is checked but
  not written into the trace. The agents in this repo add `user.id` and `spiffe.id` themselves.
- `gen_ai.*` attribute names come from the `openai-v2` instrumentation (`2.4b0` in this image),
  which follows a still-experimental semantic convention. Check them against a live OGX trace
  before you fix dashboards on them.

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
| Failed API requests | root SERVER spans of `service.name=ogx` with `http.response.status_code >= 500` or `status.code = ERROR` |
| Slow requests | duration of the root SERVER span, by `http.route` |
| Model latency and token use | `chat <model>` spans: duration, `gen_ai.usage.input_tokens` / `output_tokens`, by `gen_ai.request.model` |
| MCP tool failures | `invoke_mcp_tool` spans with `status.code = ERROR`, by `server_label` and `tool_name` |
| Per user or per agent | `user.id`, `spiffe.id` on agent spans (not on OGX's own spans) |

## How this was established

- The OTLP structure and resource attributes: a real agent trace read back from Tempo on the lab.
- The OGX spans, attributes, metric names and auto-instrumentation: read from the OGX 3.5.2 server
  image (`registry.redhat.io/rhoai/odh-ogx-core-rhel9`): its entrypoint, its installed
  OpenTelemetry packages and its source.
- Not yet seen on the lab: a live OGX trace (OGX needs PostgreSQL and a served model). The
  auto-instrumented attribute names above follow the libraries' semantic conventions and should
  be confirmed against one live trace.
- The Red Hat OpenShift AI 3.5 documentation does not list OGX span or attribute names. It covers
  the Gen AI Studio trace view (MLflow, Technology Preview) and the platform observability stack.
