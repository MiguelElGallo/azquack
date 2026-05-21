# DuckDB Quack and Azure Container Apps Sticky Sessions

Suggested issue title:

```text
Quack connection id can fail behind Azure Container Apps sticky-session ingress
```

This describes a routing problem seen when a DuckDB Quack server runs behind Azure Container Apps ingress with more than one query replica.

## Summary

- Azure Container Apps sticky sessions worked for ordinary cookie-aware HTTP clients.
- DuckDB Quack did not appear to preserve that affinity in this setup.
- After a local DuckDB client ran `ATTACH ... (TYPE quack)`, repeated `remote.query(...)` calls failed with:

```text
Invalid Input Error: Invalid connection id
```

The likely cause is that a follow-up Quack request reached a different Container Apps replica than the one that created the Quack connection.

## Versions

- DuckDB: `v1.5.3`
- Quack: core extension
- Server: DuckDB process exposed through Quack
- Client: local DuckDB CLI attaching with `TYPE quack`
- Ingress: Azure Container Apps HTTPS ingress
- Sticky sessions: Azure Container Apps cookie-based affinity
- Query replicas: `2`

## Deployment Shape

```text
local DuckDB client
    |
    | ATTACH 'quack:https://<query-app>' AS remote (TYPE quack)
    v
Azure Container Apps public ingress
    |
    | stickySessions.affinity = sticky
    v
query replica A or query replica B
    |
    | DuckLake metadata catalog over internal Quack
    v
single internal catalog replica
```

The catalog replica stays single-replica.

Only the public query app was scaled to two replicas.

## Reproduce

Deploy the query app with two replicas and sticky sessions:

```sh
azd env set QUERY_MIN_REPLICAS 2
azd env set QUERY_MAX_REPLICAS 2
azd env set QUERY_STICKY_SESSIONS sticky
azd env set QUERY_EXPOSE_PLATFORM_METADATA true
azd up
```

Then attach from a local DuckDB `v1.5.3` client:

```sql
INSTALL quack;
LOAD quack;

CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE 'quack:https://<query-app-host>',
    TOKEN '<public-query-token>'
);

ATTACH 'quack:https://<query-app-host>' AS remote (TYPE quack);

FROM remote.query('FROM whoami()');
FROM remote.query('FROM whoami()');
```

The first call can succeed.

A later call can fail with:

```text
Invalid Input Error: Invalid connection id
```

The fuller test harness in this repo is:

```sh
./scripts/validate-sticky-sessions.py
```

## Actual Behavior

The same Container Apps ingress did honor sticky sessions for a normal HTTP client using a cookie jar.

The server exposed `/readyz` with the current replica name only for the experiment.

- cookie-aware `/readyz` requests stayed on one replica
- stateless `/readyz` requests reached both replicas
- DuckDB Quack calls after `ATTACH` failed with `Invalid connection id`

That suggests Azure Container Apps affinity itself was working, but the DuckDB Quack request path was not bound to the same backend replica.

## Expected Behavior

For a Quack connection created through a sticky ingress, follow-up requests should either:

- keep using the same backend replica, or
- not depend on backend-local connection state, or
- fail with a clearer message that the deployment requires single-replica routing.

## Current Workaround

Keep the public Quack query app single-replica:

```text
QUERY_MIN_REPLICAS=1
QUERY_MAX_REPLICAS=1
QUERY_STICKY_SESSIONS=none
```

This avoids routing a Quack connection id to a different server process.

## Notes

This report does not include a packet capture.

The conclusion about cookie affinity is inferred from these facts:

- ACA sticky sessions worked for cookie-aware HTTP requests
- stateless requests reached both replicas
- Quack failed with a connection id that appears local to one replica

The root cause could be cookie handling, connection-state routing, or another Quack transport detail.

The operational result is clear: with the current Quack client behavior, multiple public query replicas behind Azure Container Apps ingress are not safe for this architecture.
