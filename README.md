# CloudflareKit

Swift package with:

- `CloudflareKit`: reusable library for Cloudflare Worker deployment, version, and build-history access.
- `cloudflare`: single CLI command for Worker deployments, versions, token verification, and activation.

## What it covers

- Active deployment
- Deployment history
- Saved Worker versions
- Promote an older version back to active traffic

The package covers the Worker deployment/version APIs that are usable for this account:

- Deployments come from `GET /accounts/{account_id}/workers/scripts/{script_name}/deployments`
- Versions come from `GET /accounts/{account_id}/workers/scripts/{script_name}/versions`

## Environment

```fish
set -x CLOUDFLARE_ACCOUNT_ID your-account-id
set -x CLOUDFLARE_API_TOKEN your-api-token
set -x CLOUDFLARE_WORKER_NAME your-worker-name
```

Cloudflare permissions needed by the documented endpoints:

- `Workers Scripts Read`
- `Workers Scripts Write`

## CLI usage

```fish
swift run cloudflare
swift run cloudflare --auth-check
swift run cloudflare --activate 18f97339-c287-4872-9bdd-e2135c07ec12 --message "Rollback after bad deploy"
```

JSON output:

```fish
swift run cloudflare --format json
```

## Library usage

```swift
import CloudflareKit

let client = CloudflareAPIClient(
    configuration: CloudflareAPIConfiguration(
        accountID: ProcessInfo.processInfo.environment["CLOUDFLARE_ACCOUNT_ID"]!,
        apiToken: ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]!
    )
)

let snapshot = try await client.getSnapshot(workerName: "my-worker")
let deployment = try await client.activateVersion(
    workerName: "my-worker",
    versionID: "18f97339-c287-4872-9bdd-e2135c07ec12",
    message: "Rollback after bad deploy"
)
```

## Notes

- This package currently omits the Workers Builds API path for this account because the required access is not exposed through the usable token flow.
