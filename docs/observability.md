# Workers Observability Protocol

## Scope

Cloudflare dashboard page inspected:

- `/workers/services/view/{service}/production/observability/events`

Worker inspected:

- `lorica-cia-diligence`

Account inspected:

- `cb5a1c7255061f11f48ea45e8a416040`

## State Split

Three layers drive the page:

- URL query params: shareable query state
- observability API: actual data and field metadata
- browser storage: UI-only state

## URL State

Observed params:

- `timeframe`
- `filterCombination`
- `conditions`
- `conditionCombination`
- `calculations`
- `orderBy`
- `alertTiming`

View is encoded in the route segment:

- `/observability/events`
- `/observability/invocations`
- `/observability/traces`
- `/observability/visualizations`

Timeframe encoding:

- preset ranges: `15m`, `1h`, `24h`, `3d`, `7d`
- custom absolute range: `<ISO-from>/<ISO-to>`

Example:

```txt
timeframe=2026-04-10T13:24:08.617Z/2026-04-10T14:24:08.617Z
```

## Main Data Endpoint

Page data comes from:

- `POST /api/v4/accounts/{accountID}/workers/observability/telemetry/query`

Observed base payload:

```json
{
  "queryId": "workers-observability",
  "parameters": {
    "datasets": ["cloudflare-workers", "otel"],
    "filters": [
      {
        "key": "$metadata.service",
        "type": "string",
        "value": "lorica-cia-diligence",
        "operation": "eq"
      }
    ],
    "filterCombination": "and"
  },
  "timeframe": {
    "from": 1775827448617,
    "to": 1775831048617
  }
}
```

Important:

- API gets epoch millis, never preset strings or ISO range strings
- URL `timeframe` must be converted before request

## View Mapping

### Events

Route:

- `/observability/events`

Observed request shape:

```json
{
  "view": "events",
  "limit": 100,
  "chart": true,
  "offsetDirection": "next"
}
```

### Invocations

Route:

- `/observability/invocations`

Observed request shape:

```json
{
  "view": "invocations",
  "limit": 50,
  "offsetDirection": "next"
}
```

### Traces

Route:

- `/observability/traces`

Observed request shape:

```json
{
  "view": "traces",
  "limit": 50,
  "chart": true,
  "offsetDirection": "next"
}
```

### Visualizations

Route:

- `/observability/visualizations`

Observed request shape:

```json
{
  "view": "calculations",
  "parameters": {
    "datasets": ["cloudflare-workers", "otel"],
    "filters": [
      {
        "key": "$metadata.service",
        "type": "string",
        "value": "lorica-cia-diligence",
        "operation": "eq"
      }
    ],
    "filterCombination": "and",
    "calculations": [
      {
        "operator": "count"
      }
    ],
    "groupBys": [],
    "orderBy": {
      "value": "count",
      "limit": 10,
      "order": "desc"
    },
    "limit": 10
  }
}
```

Important:

- route says `visualizations`
- API `view` is `calculations`

## Field Metadata

Field discovery comes from:

- `POST /api/v4/accounts/{accountID}/workers/observability/telemetry/keys`

Observed payloads:

```json
{
  "from": 1775827448617,
  "to": 1775831048617,
  "datasets": ["cloudflare-workers"],
  "filters": [
    {
      "key": "$metadata.service",
      "type": "string",
      "value": "lorica-cia-diligence",
      "operation": "eq"
    }
  ]
}
```

```json
{
  "from": 1775827448617,
  "to": 1775831048617,
  "datasets": [],
  "filters": [
    {
      "key": "$metadata.service",
      "type": "string",
      "value": "lorica-cia-diligence",
      "operation": "eq"
    }
  ],
  "limit": 10000
}
```

Observed behavior:

- opening the `Fields` modal made no network call
- fields list was already available from prior `telemetry/keys` responses

## Field Selection Persistence

Field selection is stored in `sessionStorage`.

Observed key:

- `workers-observability.workers-observability.columns`

Observed value shape:

```json
[
  {"key":"$metadata.level","type":"string","width":80},
  {"key":"$metadata.type","type":"string","width":120},
  {"key":"$metadata.message","type":"string","width":495}
]
```

Important:

- toggling fields changed browser storage
- toggling fields did not change URL
- toggling fields did not trigger a fetch

## Other UI Persistence

Observed local storage keys:

- `workers-observability.last-view`
- `workers-observability.querybuilder.open`

Observed values:

- last view persisted as JSON string, e.g. `"events"`
- query builder open state persisted as boolean string

## Live Mode

Live mode uses a separate protocol.

Bootstrap:

- `POST /api/v4/accounts/{accountID}/workers/observability/telemetry/live-tail`

Observed request:

```json
{
  "scriptId": "lorica-cia-diligence",
  "filters": [],
  "filterCombination": "and"
}
```

Observed websocket:

```txt
wss://live-tail.observability.cloudflare.com/connect?accountId=...&userId=...&key=...&serviceId=lorica-cia-diligence
```

Heartbeat:

- `POST /api/v4/accounts/{accountID}/workers/observability/telemetry/live-tail/heartbeat`

Observed heartbeat payload:

```json
{
  "scriptId": "lorica-cia-diligence"
}
```

Observed stream behavior:

- websocket frames are JSON text messages
- frames contain full event payloads
- event data includes `$workers`, timestamps, request metadata, log message text, outcome, and version IDs

## Saved Queries And Usage

Observed supporting endpoints:

- `GET /api/v4/accounts/{accountID}/workers/observability/queries?perPage=10&page=1`
- `GET /api/v4/accounts/{accountID}/workers/observability/usage-statuses`

## Practical Model

If we implement this in app code, the clean split is:

- route/view state:
  - route segment for view
  - URL params for timeframe, calculations, filters, order
- API state:
  - `telemetry/query` for results
  - `telemetry/keys` for field catalog
  - `live-tail` + websocket + heartbeat for live mode
- local UI state:
  - selected columns in `sessionStorage`
  - last view and query builder state in `localStorage`

## Notes

- Dashboard also fires unrelated analytics and telemetry events; those are not required for product behavior
- Dashboard also continues polling worker build status in the background; that is unrelated to observability query data
