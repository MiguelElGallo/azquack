# Local Client

After deployment, query the remote DuckLake through a local DuckDB process:

```sh
./scripts/connect-local.sh
```

The script:

1. Reads `QUACK_URI` and `KEY_VAULT_NAME` from the active AZD environment.
2. Fetches the Quack token from Key Vault.
3. Installs and loads the local Quack extension.
4. Creates a scoped Quack secret.
5. Attaches the remote endpoint, runs `whoami()`, writes one smoke-test row, and queries `azquack.demo.events`.

If token retrieval fails, make sure the active operator principal has `Key Vault Secrets User` on the deployed `quack-token` secret. The default AZD preprovision hook sets `OPERATOR_PRINCIPAL_ID` to the signed-in Azure user when `az ad signed-in-user show` is available.

Equivalent SQL:

```sql
FORCE INSTALL quack FROM core_nightly;
LOAD quack;

CREATE OR REPLACE SECRET azquack_remote (
    TYPE quack,
    SCOPE 'quack:<container-app-fqdn>:443',
    TOKEN '<token-from-key-vault>'
);

ATTACH 'quack:<container-app-fqdn>:443' AS remote (TYPE quack);

FROM remote.query('FROM whoami()');
FROM remote.query('INSERT INTO azquack.demo.events SELECT 2, ''local-client-smoke'', now() WHERE NOT EXISTS (SELECT 1 FROM azquack.demo.events WHERE event_id = 2)');
FROM remote.query('SELECT * FROM azquack.demo.events ORDER BY event_id');
```
