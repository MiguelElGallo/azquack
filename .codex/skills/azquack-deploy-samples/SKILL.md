---
name: azquack-deploy-samples
description: Deploy and validate the AzQuack repo on Azure, then run the local DuckDB samples that attach to the Azure-hosted DuckDB over Quack and write/read DuckLake data. Use when working in the azquack repo for azd provisioning, live deployment checks, Quack/DuckLake sample runs, troubleshooting failed revisions, or cleanup.
---

# AzQuack Deploy Samples

Use this skill from the repo root.

## Guardrails

- Deploy only to a new AZD environment/resource group unless the user explicitly asks to reuse one.
- Treat `.azure/*/.env`, Quack tokens, PostgreSQL passwords, subscription IDs, and live endpoints as sensitive. Do not commit them.
- Keep Quack beta caveats visible: DuckDB CLI and server should be `v1.5.2`, and Quack installs from `core_nightly`.
- Expect prototype security boundaries: public Quack endpoint with shared token, public PostgreSQL/Key Vault/Storage/ACR endpoints, and a startup-only PostgreSQL admin bootstrap.

## Deploy

1. Confirm tools:
   ```sh
   azd version
   az --version
   duckdb -csv -c 'SELECT version();'
   docker version
   ```
2. Log in and choose a subscription:
   ```sh
   az login
   az account set --subscription <subscription-id>
   azd auth login
   ```
3. Create a fresh environment and deploy:
   ```sh
   azd env new <unique-env-name> --location westus --subscription <subscription-id>
   azd up
   ```
4. If local Key Vault token access fails, set:
   ```sh
   azd env set OPERATOR_PRINCIPAL_ID "$(az ad signed-in-user show --query id -o tsv)"
   azd env set OPERATOR_PRINCIPAL_TYPE User
   azd provision --no-prompt
   ```

## Validate And Run Samples

Run the full live validation first:

```sh
./scripts/validate-deployment.sh
```

It must show `Deployment validation passed.` This checks health, readiness, authenticated Quack attach, wrong-token rejection, DuckLake writes, Blob file proof, and restart persistence.

Then run the small local sample:

```sh
./scripts/connect-local.sh
```

It should attach to `QUACK_URI`, call `whoami()`, insert `local-client-smoke`, and read `azquack.demo.events`.

## Troubleshoot

- Show current outputs:
  ```sh
  azd env get-values
  ```
- Check revision state:
  ```sh
  az containerapp revision list --name "$(azd env get-value CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" -o table
  ```
- Check logs:
  ```sh
  az containerapp logs show --name "$(azd env get-value CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" --type console --tail 120 --follow false
  ```
- Check health:
  ```sh
  curl --fail "$(azd env get-value QUACK_HTTP_URL)/healthz"
  curl --fail "$(azd env get-value QUACK_HTTP_URL)/readyz"
  ```

## Cleanup

When the experiment is done:

```sh
azd down --purge
```

If Key Vault purge is not authorized, report the soft-deleted vault name and do not reuse the same environment name.
