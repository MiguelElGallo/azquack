# Sticky Session Experiment

This experiment answers one question:

```text
When Azure Container Apps uses cookie-based sticky sessions, does DuckDB Quack stay on one query replica?
```

## Default

The default deployment stays conservative:

| App | Replicas | Sticky sessions |
| --- | ---: | --- |
| query | `1` | `none` |
| catalog | `1` | not public |

The catalog app must remain single-replica because it is the only process that opens `/catalog/catalog.duckdb`.

## Experiment

Use the existing AZD environment or a fresh one, then set:

```sh
azd env set QUERY_MIN_REPLICAS 2
azd env set QUERY_MAX_REPLICAS 2
azd env set QUERY_STICKY_SESSIONS sticky
azd env set QUERY_EXPOSE_PLATFORM_METADATA true
azd up
```

Run:

```sh
./scripts/validate-sticky-sessions.py
```

The script validates:

- query app is in single revision mode
- query ingress has `stickySessions.affinity = sticky`
- query app has at least two replicas
- catalog app remains `minReplicas = 1` and `maxReplicas = 1`
- `/readyz` requests with a cookie jar stay on one replica
- multiple Quack clients observe both query replicas across the sample
- each individual attached Quack session stays on one replica
- split transaction checks work through Quack
- large result fetching works through Quack

## Rollback

Return to the default shape:

```sh
azd env set QUERY_MIN_REPLICAS 1
azd env set QUERY_MAX_REPLICAS 1
azd env set QUERY_STICKY_SESSIONS none
azd env set QUERY_EXPOSE_PLATFORM_METADATA false
azd up
./scripts/validate-deployment.sh
```

For a disposable experiment environment, use:

```sh
azd down --purge --force --no-prompt
```

## Status

Live test on `2026-05-21` against the existing `westus` AZD environment:

| Check | Result |
| --- | --- |
| query scale | `minReplicas = 2`, `maxReplicas = 2` |
| query sticky sessions | `stickySessions.affinity = sticky` |
| catalog scale | `minReplicas = 1`, `maxReplicas = 1` |
| query replicas | two running replicas observed |
| cookie-aware `/readyz` | stayed on one replica |
| stateless `/readyz` | reached both replicas |
| DuckDB Quack repeated calls | failed with `Invalid connection id` after `ATTACH` |
| rollback | reset to `QUERY_MIN_REPLICAS=1`, `QUERY_MAX_REPLICAS=1`, `QUERY_STICKY_SESSIONS=none` |
| rollback deploy | `azd up` completed after reset |
| revision cleanup | old zero-traffic experiment revisions deactivated |
| baseline validation | `./scripts/validate-deployment.sh` passed after rollback cleanup |
| closeout health | exactly one active healthy query revision and one active healthy catalog revision |
| public `/readyz` | restored to `{"ready": true}` with platform metadata disabled |

Conclusion:

```text
ACA sticky sessions work for ordinary cookie-aware HTTP clients.
The current DuckDB Quack client does not appear to replay ACA's affinity cookie.
```

That means this architecture cannot safely use multiple public query replicas behind ACA ingress today.
The Quack connection is established on one query replica, but a follow-up `remote.query()` can be routed to another replica that does not know that connection id.

The safe default remains:

```text
QUERY_MIN_REPLICAS=1
QUERY_MAX_REPLICAS=1
QUERY_STICKY_SESSIONS=none
QUERY_EXPOSE_PLATFORM_METADATA=false
```

The failing sticky-session run stopped before the validator reached the persistent DuckLake write cleanup path.
Future successful runs drop their `azquack.sticky.sticky_write_*` table before exiting.

During rollback, the catalog revision briefly failed to open `/catalog/catalog.duckdb` with `Permission denied` after overlapping catalog revisions existed.
The old zero-traffic revisions must be deactivated before returning to the baseline.
Do not use a normal catalog revision restart as a validation step: ACA can overlap catalog replicas during restart, and both processes can try to open the same DuckDB catalog file on Azure Files.
The deployment validator now checks that both Container Apps have exactly one active healthy revision before running Quack/DuckLake assertions.
