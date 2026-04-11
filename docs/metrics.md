# Workers Metrics Protocol

Inspected dashboard page:

- `/workers/services/view/{service}/production/metrics`

Inspected worker:

- `lorica-cia-diligence-owner`

Inspected account:

- `cb5a1c7255061f11f48ea45e8a416040`

## Overview

The metrics page is driven by:

- REST for service, environment, deployment, route, and build metadata
- GraphQL for metric widgets and time series

Most charts and cards come from `POST /api/v4/graphql`.

## Shared Inputs

Common variables across GraphQL requests:

- `accountTag`
- `datetimeStart`
- `datetimeEnd`
- `scriptName`
- optional `scriptVersions`

Observed example:

```json
{
  "accountTag": "cb5a1c7255061f11f48ea45e8a416040",
  "datetimeStart": "2026-04-10T18:20:13.745Z",
  "datetimeEnd": "2026-04-11T18:20:13.745Z",
  "scriptName": "lorica-cia-diligence-owner"
}
```

Time series grouping is typically:

- `datetimeFifteenMinutes`

Version filtering is controlled by:

- `scriptVersions`

If “All deployed versions” is selected, the page does not need a narrowed version list.

## REST Endpoints

Used while loading the metrics page:

- `GET /api/v4/accounts/{account}/workers/services/{service}`
- `GET /api/v4/accounts/{account}/workers/services/{service}?expand=scripts`
- `GET /api/v4/accounts/{account}/workers/services/{service}/environments/production`
- `GET /api/v4/accounts/{account}/workers/services/{service}/environments/production?expand=routes`
- `GET /api/v4/accounts/{account}/workers/services/{service}/environments/production/subdomain`
- `GET /api/v4/accounts/{account}/workers/services/{service}/environments/production/routes?show_zonename=true`
- `GET /api/v4/accounts/{account}/workers/domains/records?page=1&per_page=500&service={service}&environment=production`
- `GET /api/v4/accounts/{account}/workers/scripts/{service}/deployments`
- `GET /api/v4/accounts/{account}/workers/deployments/by-script/{scriptTag}`
- `GET /api/v4/accounts/{account}/workers/deployments/by-script/{scriptTag}/detail/{versionId}`
- `GET /api/v4/accounts/{account}/builds/builds/latest?external_script_ids={scriptTag}`
- `GET /api/v4/accounts/{account}/builds/workers/{scriptTag}/triggers`

These provide:

- service and environment metadata
- script tag
- deployed versions
- active deployment details
- routes/domains/subdomain state
- build metadata when available

## GraphQL Endpoint

All metric widgets were fetched from:

- `POST /api/v4/graphql`

## Query Inventory

### Account Settings

Request:

- `GetAccountSettings`

Purpose:

- analytics capability/settings bootstrap

### Summary Cards

Request:

- `getWorkerAnalytics`

Reads:

- `sum.requests`
- `sum.subrequests`
- `sum.errors`
- `sum.duration`
- `quantiles.cpuTimeP50`
- `quantiles.wallTimeP50`
- `quantiles.requestDurationP50`

Also requests:

- `previous: workersInvocationsAdaptive(...)`

Purpose:

- top cards and delta percentages vs previous window

### Active Deployment / Version Summary

Request:

- `GetWorkersVersionMetrics`

Reads:

- `workersSubrequestsAdaptiveGroups.sum.subrequests`
- `workersInvocationsAdaptive.sum.requests`
- `workersInvocationsAdaptive.sum.errors`
- `workersInvocationsAdaptive.quantiles.cpuTimeP50`
- `dimensions.scriptVersion`
- `dimensions.datetimeFifteenMinutes`

Purpose:

- active deployment section
- per-version request/error/cpu summary

### Requests By Version

Request:

- `GetWorkerRequests`

Filter:

- standard invocation filter for `scriptName`, time window, optional `scriptVersions`

Reads:

- `sum.requests`
- `dimensions.datetimeFifteenMinutes`
- `dimensions.scriptVersion`

Purpose:

- “Requests” chart grouped by version

### Errors By Version

Request:

- `GetWorkerRequests`

Reads:

- `sum.errors`
- `dimensions.datetimeFifteenMinutes`
- `dimensions.scriptVersion`

Purpose:

- “Errors by version” chart

### Errors By Invocation Status

Request:

- `GetWorkerRequests`

Filter:

```json
{
  "status_notin": [
    "success",
    "clientDisconnected",
    "responseStreamDisconnected"
  ]
}
```

Reads:

- `sum.errors`
- `dimensions.datetimeFifteenMinutes`
- `dimensions.status`

Purpose:

- “Errors by invocation status”

### Client Disconnected By Version / Type

Request:

- `GetWorkerRequests`

Filter:

```json
{
  "status_in": [
    "clientDisconnected",
    "responseStreamDisconnected"
  ]
}
```

Reads:

- `sum.clientDisconnects`
- grouped by:
  - `dimensions.datetimeFifteenMinutes` + `dimensions.scriptVersion`
  - or `dimensions.datetimeFifteenMinutes` + `dimensions.status`

Purpose:

- “Client disconnected by version”
- “Client disconnected by type”

### Request Distribution Map

Request:

- `GetWorkerRequestDistribution`

Reads:

- `sum.requests`
- `dimensions.coloCode`

Purpose:

- world map request distribution

### Subrequests Table

Request:

- `GetWorkerSubRequests`

Reads:

- `sum.subrequests`
- `quantiles.timeToResponseUsP50`
- `quantiles.timeToResponseDrainedUsP50`
- `dimensions.hostname`
- `dimensions.httpResponseStatus`
- `dimensions.cacheStatus`

Purpose:

- origin/subrequest breakdown table

### CPU Time Chart

Request:

- `GetWorkerCPUTime`

Reads:

- `quantiles.cpuTimeP50`
- `quantiles.cpuTimeP90`
- `quantiles.cpuTimeP99`
- `quantiles.cpuTimeP999`
- `dimensions.datetimeFifteenMinutes`

Purpose:

- CPU time percentile chart

### Wall Time Chart

Request:

- `GetWorkerWallTime`

Reads:

- `quantiles.wallTimeP50`
- `quantiles.wallTimeP90`
- `quantiles.wallTimeP99`
- `quantiles.wallTimeP999`
- `dimensions.datetimeFifteenMinutes`

Purpose:

- wall time percentile chart

### Request Duration Chart

Request:

- `GetWorkerRequestDuration`

Reads:

- `quantiles.requestDurationP50`
- `quantiles.requestDurationP90`
- `quantiles.requestDurationP99`
- `quantiles.requestDurationP999`
- `dimensions.datetimeFifteenMinutes`

Purpose:

- request duration percentile chart

### Placement Performance

Request:

- `GetWorkerPlacementPerformance`

Reads:

- `quantiles.requestDurationP90`
- `dimensions.placementUsed`
- `dimensions.clientColoCode`

Purpose:

- placement performance panel

## Recreating The Page

To reproduce the metrics page for one worker:

1. Fetch service/env/deployment metadata via REST.
2. Resolve active versions and `scriptTag`.
3. For the selected timeframe, issue the GraphQL queries above.
4. Group most time series by `datetimeFifteenMinutes`.
5. Apply version filters through `scriptVersions` when a specific deployment/version is selected.

## Notes

- The page mixes Workers deployment APIs and analytics GraphQL APIs.
- Build APIs are still queried, but Wrangler/manual deployments also rely on deployments endpoints.
- The metrics page is query-per-widget rather than one large aggregated response.
