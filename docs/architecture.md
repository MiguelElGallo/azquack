# Architecture

AzQuack now uses a PostgreSQL-free DuckLake catalog experiment.

```mermaid
flowchart LR
    local["Local DuckDB + Quack"]
    ingress["External ACA HTTPS ingress"]
    queryProxy["Caddy in query app"]
    query["DuckDB query process\nDuckLake attached"]
    catalogIngress["Internal ACA ingress"]
    catalogProxy["Caddy in catalog app"]
    catalog["DuckDB catalog process\n/catalog/catalog.duckdb"]
    blob["Blob / ADLS data files\naz://lakehouse/data/"]
    files["Azure Files\ncatalog.duckdb"]
    kv["Key Vault\nQuack tokens"]

    local -- "public Quack token" --> ingress
    ingress --> queryProxy --> query
    query -- "internal Quack token" --> catalogIngress
    catalogIngress --> catalogProxy --> catalog
    query --> blob
    catalog --> files
    query -. "secret refs" .-> kv
    catalog -. "secret refs" .-> kv
```

## Runtime Contract

- The query Container App exposes the only public Quack endpoint.
- The catalog Container App uses internal Container Apps ingress only.
- The catalog app is the only process that opens `/catalog/catalog.duckdb`.
- The query app attaches DuckLake with `ducklake:quack:<internal-catalog-fqdn>:443`.
- DuckLake data files are written by the query app to `az://lakehouse/data/`.
- By default, both Container Apps run with `minReplicas: 1` and `maxReplicas: 1`.
- The query app can be deployed with more than one replica for the sticky-session experiment.
  Keep the catalog app at one replica because it owns the DuckDB catalog file.

## Query Replica Experiment

Set these AZD environment values before deployment to test two public query replicas:

```sh
azd env set QUERY_MIN_REPLICAS 2
azd env set QUERY_MAX_REPLICAS 2
azd env set QUERY_STICKY_SESSIONS sticky
azd env set QUERY_EXPOSE_PLATFORM_METADATA true
```

Then deploy and run:

```sh
azd up
./scripts/validate-sticky-sessions.py
```

The validator checks the live Azure configuration, waits for two query replicas, confirms the catalog remains single-replica, verifies cookie-aware `/readyz` requests stay on one replica, and runs repeated Quack calls that read replica hostnames from inside the remote query process.
It also checks remote temporary state, split transactions, large results, and DuckLake writes through Quack so the test covers more than a single metadata call.

The latest live result is negative.
ACA sticky sessions worked for normal cookie-aware `/readyz` requests, but DuckDB Quack calls after `ATTACH` failed with `Invalid connection id`.
Do not run the public query app with multiple replicas until Quack can preserve the required affinity or use a different replica-safe routing model.

## Storage Contract

DuckLake uses two Azure storage surfaces:

| Storage | Used for | Access |
| --- | --- | --- |
| Blob / ADLS container | Parquet/data files | query app managed identity |
| Azure Files share | DuckDB metadata catalog file | Container Apps Azure Files mount |

The data Storage Account disables shared-key access.
The catalog Storage Account keeps shared-key access enabled because Azure Container Apps Azure Files mounts require an account key.

## Security Posture

- `quack-token` is for local DuckDB clients and the public query app.
- `catalog-quack-token` is for query app to internal catalog app only.
- Normal local client scripts do not read `catalog-quack-token`; the validator reads the local AZD value when available only to scan logs for leaks.
- Key Vault grants each Container App identity only the secret refs it needs.
- ACR admin credentials are disabled; both apps pull with managed identity.
- The public query app remains internet-reachable and token-protected.
- A public-token holder has transitive write access to DuckLake through the query app, even though the internal catalog token is not exposed locally.

> [!WARNING]
> Quack token authentication does not restrict SQL by itself.
> A token holder can run SQL against objects visible to the server session.

## Beta Caveats

This design relies on DuckDB `v1.5.3`, where Quack is a core extension and DuckLake can use a Quack endpoint as the metadata catalog.
The behavior is new and should be treated as experimental until restart, rollback, concurrency, and backup behavior are proven for your workload.
