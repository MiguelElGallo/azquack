---
name: azquack-deploy-samples
description: Deploy and validate the AzQuack repo on Azure, then run the local DuckDB samples that attach to the Azure-hosted DuckDB over Quack and write/read DuckLake data. Use when working in the azquack repo for azd provisioning, live deployment checks, Quack/DuckLake sample runs, troubleshooting failed revisions, or cleanup.
---

# AzQuack Deploy Samples

Use this skill from the repo root.

## Guardrails

- Deploy only to a new AZD environment/resource group unless the user explicitly asks to reuse one.
- Treat `.azure/*/.env`, Quack tokens, subscription IDs, storage account keys, and live endpoints as sensitive. Do not commit them.
- Keep beta caveats visible: this repo uses DuckDB `v1.5.3`, Quack, and DuckLake-with-Quack catalog support.
- Expect prototype security boundaries: public query app with shared token, internal catalog app with a separate token, public Key Vault/Storage/ACR endpoints, and an Azure Files mount for the catalog DuckDB file.

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

It must show `Deployment validation passed.` This checks no PostgreSQL resource exists, both apps run ACR images, catalog ingress is internal-only, authenticated Quack attach, wrong-token rejection, DuckLake writes, rollback/commit behavior, concurrent writers, Blob file proof, Azure Files catalog proof, query restart persistence, catalog health without restarting the catalog file owner, and token log hygiene.

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
- Check query app revisions:
  ```sh
  az containerapp revision list --name "$(azd env get-value QUERY_CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" -o table
  ```
- Check catalog app revisions:
  ```sh
  az containerapp revision list --name "$(azd env get-value CATALOG_CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" -o table
  ```
- Check query logs:
  ```sh
  az containerapp logs show --name "$(azd env get-value QUERY_CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" --type console --tail 120 --follow false
  ```
- Check catalog logs:
  ```sh
  az containerapp logs show --name "$(azd env get-value CATALOG_CONTAINER_APP_NAME)" --resource-group "$(azd env get-value AZURE_RESOURCE_GROUP)" --type console --tail 120 --follow false
  ```
- Check health:
  ```sh
  curl --fail "$(azd env get-value QUACK_HTTP_URL)/healthz"
  curl --fail "$(azd env get-value QUACK_HTTP_URL)/readyz"
  ```

## Cleanup

When the experiment is done:

```sh
azd down --purge --force --no-prompt
```

If Key Vault purge is not authorized, report the soft-deleted vault name and do not reuse the same environment name.
