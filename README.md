# zammad-azure-deploy

Bicep templates to deploy [Zammad](https://zammad.org) on Azure App Service
with PostgreSQL Flexible Server and Azure Cache for Redis.

- **Region:** Brazil South
- **Subscription:** Microsoft Azure Sponsorship
- **Resource group:** `zammad-app-brs-rg`

## Stack

| Resource | SKU | Monthly est. |
|---|---|---|
| App Service Plan (Linux B2) | B2 | ~$30 |
| PostgreSQL Flexible Server | Burstable B1ms / PG15 | ~$26 |
| Azure Cache for Redis | Basic C0 | ~$16 |
| Web App | Docker container | included |
| **Total** | | **~$72-85/mo** |

## Deploy

```bash
az deployment sub create \
  --location brazilsouth \
  --template-file main.bicep \
  --parameters postgresAdminPassword="<YOUR_PASSWORD>"
```

See [CLAUDE.md](./CLAUDE.md) for full deployment instructions, troubleshooting,
and guidance on adding the Zammad scheduler and websocket processes.
