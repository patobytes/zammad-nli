# Zammad Azure Deployment — Claude Code Instructions

## Goal
Deploy Zammad (helpdesk) to Azure using the Bicep templates in this repo.
All resources go into **`zammad-app-brs-rg`** in **Brazil South**,
under subscription **`09a573e4-8b7e-4a95-8051-a21f01e0a758`**
(Microsoft Azure Sponsorship).

## Prerequisites (verify before starting)
- `az` CLI installed and logged in (`az login`)
- `az account set --subscription 09a573e4-8b7e-4a95-8051-a21f01e0a758`
- Bicep CLI available (`az bicep install` if not)

## What gets deployed
| Resource | Name | SKU |
|---|---|---|
| Resource Group | `zammad-app-brs-rg` | — |
| App Service Plan | `zammad-asp-brs` | B2 Linux |
| Web App | `zammad-brs-app` | Docker container |
| PostgreSQL Flexible Server | `zammad-pg-brs` | Burstable B1ms / PG15 / 32 GB |
| Azure Cache for Redis | `zammad-redis-brs` | Basic C0 |

## Deployment steps

### 1. Validate the template
```bash
az deployment sub validate \
  --location brazilsouth \
  --template-file main.bicep \
  --parameters postgresAdminPassword="<REPLACE_WITH_SECURE_PASSWORD>"
```

### 2. Deploy
```bash
az deployment sub create \
  --location brazilsouth \
  --name "zammad-$(date +%Y%m%d%H%M%S)" \
  --template-file main.bicep \
  --parameters postgresAdminPassword="<REPLACE_WITH_SECURE_PASSWORD>"
```
PostgreSQL takes ~8-12 minutes to provision. Redis takes ~5 minutes.
The Web App starts pulling the container image after both are ready.

### 3. Verify
```bash
# Check deployment status
az deployment sub show \
  --name <deployment-name> \
  --query 'properties.{state:provisioningState,outputs:outputs}' \
  -o json

# Tail app logs
az webapp log tail \
  --name zammad-brs-app \
  --resource-group zammad-app-brs-rg \
  --subscription 09a573e4-8b7e-4a95-8051-a21f01e0a758
```

### 4. First-run
- Browse to `https://zammad-brs-app.azurewebsites.net`
- The container will be cold on first boot — allow 3-5 min
- Zammad's wizard will prompt to create the initial admin account

## Troubleshooting guide

### Container fails to start
```bash
az webapp log download \
  --name zammad-brs-app \
  --resource-group zammad-app-brs-rg \
  --log-file /tmp/zammad-logs.zip
```
Common causes: wrong DATABASE_URL, Redis TLS mismatch, port mismatch.

### PostgreSQL connection refused
- Confirm firewall rule `AllowAzureServices` exists on `zammad-pg-brs`
- The `sslmode=require` in DATABASE_URL must match PG15 SSL enforcement

### Redis connection refused
- `REDIS_URL` uses `rediss://` (TLS, port 6380) — not `redis://` (6379)

### Wrong image / outdated Zammad
Update the container image to a specific version tag:
```bash
az webapp config container set \
  --name zammad-brs-app \
  --resource-group zammad-app-brs-rg \
  --docker-custom-image-name ghcr.io/zammad/zammad:X.Y.Z
```

## Known limitations
This deployment runs only Zammad's **Rails web server**.
For full functionality two extra processes are needed:

| Process | What it does |
|---|---|
| `zammad-scheduler` | Email polling, SLA escalations, background jobs |
| `zammad-websocket` | Live ticket updates in the browser |

To add them, deploy two additional Web Apps in the same plan pointing to the
same image, with `WEBSITES_STARTUP_COMMAND` overriding the entrypoint to
start the respective process. Or migrate to Azure Container Apps.

## Cleanup
```bash
az group delete --name zammad-app-brs-rg --yes --no-wait
```
