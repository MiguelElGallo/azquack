# Local Client

After deployment, query the remote DuckLake through a local DuckDB process:

```sh
./scripts/connect-local.sh
```

The script:

1. checks the local DuckDB CLI is `v1.5.3`,
2. reads `QUACK_URI` and `KEY_VAULT_NAME` from the active AZD environment,
3. fetches the public `quack-token` from Key Vault,
4. installs and loads the local Quack extension,
5. creates a scoped Quack secret,
6. attaches the public query app,
7. runs `whoami()`,
8. writes one smoke-test row,
9. queries `azquack.demo.events`.

If token retrieval fails, make sure the active operator principal has `Key Vault Secrets User` on the deployed `quack-token` secret.
The default AZD preprovision hook sets `OPERATOR_PRINCIPAL_ID` to the signed-in Azure user when `az ad signed-in-user show` is available.

Equivalent SQL:

```sql
INSTALL quack;
LOAD quack;

CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE 'quack:<query-app-fqdn>:443',
    TOKEN '<token-from-key-vault>'
);

ATTACH 'quack:<query-app-fqdn>:443' AS remote (TYPE quack);

FROM remote.query('FROM whoami()');
FROM remote.query(
    'INSERT INTO azquack.demo.events
     SELECT 2, ''local-client-smoke'', now()
     WHERE NOT EXISTS (
       SELECT 1 FROM azquack.demo.events WHERE event_id = 2
     )'
);
FROM remote.query('SELECT * FROM azquack.demo.events ORDER BY event_id');
```

The local DuckDB client does not connect to Azure Blob Storage, Azure Files, or the internal catalog app.
