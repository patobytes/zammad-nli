# Zammad — Azure VM Deployment

Bicep + Docker Compose deployment of [Zammad](https://zammad.org) on an Azure VM (Brazil South).
This repo is a fork of [zammad/zammad-docker-compose](https://github.com/zammad/zammad-docker-compose)
with Azure infrastructure, production overrides, and a multi-service setup layered on top.

> **Full ops guide:** see [CLAUDE.md](./CLAUDE.md)

---

## Architecture

```mermaid
graph LR
    Browser -->|"HTTPS 443"| NPM

    subgraph proxy-net["proxy-net · 172.20.0.0/24"]
        NPM["NPM Plus\n:80 :443\nlocalhost:81"]
        Portainer["Portainer CE\nlocalhost:9000"]
        ZNginx["zammad-nginx\nzammad-nginx-1:80"]
    end

    subgraph gl-net["globaleaks-net · 172.21.0.0/24  (planned)"]
        GL["GlobaLeaks"]
    end

    subgraph zstack["Zammad default bridge"]
        ZApp["zammad (Rails)"]
        PG["postgresql"]
        Redis["redis"]
        ES["elasticsearch"]
    end

    subgraph afs["Azure File Shares · stzmdbrsvi7puq3ozfbso"]
        FS1["zammad-storage  100 GB"]
        FS2["zammad-backup   50 GB"]
        FS3["npm-certs       10 GB"]
    end

    NPM -->|http| ZNginx
    NPM -.->|"attach npm to gl-net first"| GL
    ZNginx --> ZApp
    ZApp --> PG & Redis & ES
    ZApp -. "CIFS/SMB 3.0" .-> FS1 & FS2
    NPM -. "CIFS/SMB 3.0" .-> FS3
```

NPM Plus is the single internet-facing entry point (ports 80/443). All other services are reachable only through NPM Plus or via SSH tunnel.

---

## Docker Networks

| Network | Subnet | Services |
|---|---|---|
| `proxy-net` | `172.20.0.0/24` | NPM Plus, Portainer, zammad-nginx |
| `globaleaks-net` | `172.21.0.0/24` | GlobaLeaks (isolated from proxy-net) |
| Zammad default | Docker-assigned | zammad, postgresql, redis, elasticsearch |

Both networks are pre-created by `vm-setup.sh` with explicit subnets. Services reference them as `external: true`.

**Isolation rule:** services on `globaleaks-net` cannot communicate with services on `proxy-net`. NPM Plus must be explicitly attached to a service's network to route traffic to it.

---

## Services

| Directory | Service | Network |
|---|---|---|
| [`services/npm/`](services/npm/) | NPM Plus — reverse proxy + SSL | proxy-net |
| [`services/portainer/`](services/portainer/) | Portainer CE — Docker UI | proxy-net |
| [`services/globaleaks/`](services/globaleaks/) | GlobaLeaks (planned) | globaleaks-net |
| repo root | Zammad (upstream docker-compose) | proxy-net (nginx only) |

---

## Azure Resources

| Resource | Name | SKU |
|---|---|---|
| Resource Group | `rg-zmd-brs` | — |
| Virtual Machine | `vm-zmd-brs` | Standard_B2ms (2 vCPU / 8 GB) |
| OS Disk | — | Premium SSD, 64 GB |
| Storage Account | `stzmdbrsvi7puq3ozfbso` | Standard LRS |
| File Share | `zammad-storage` | 100 GB |
| File Share | `zammad-backup` | 50 GB |
| File Share | `npm-certs` | 10 GB |
| Public IP | `pip-zmd-brs` | Static, Standard SKU |
| VNet | `vnet-zmd-brs` | 10.0.0.0/16 |
| NSG | `nsg-zmd-brs` | Inbound: 22, 80, 443 |

---

## Quick Start

```powershell
# 1. Generate SSH key (first time only)
ssh-keygen -t ed25519 -C "zammad-azure" -f "$env:USERPROFILE\.ssh\zammad_azure"

# 2. Deploy
az deployment sub create `
  --location brazilsouth `
  --name "zmd-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --template-file main.bicep `
  --parameters `
    sshPublicKey="$(Get-Content $env:USERPROFILE\.ssh\zammad_azure.pub)" `
    postgresPassword="YourSecurePassword123!"

# 3. Check setup log (~15 min after deploy)
ssh -i $env:USERPROFILE\.ssh\zammad_azure zammadadmin@<vm-ip> 'cat /var/log/zammad-setup.log'
```

See [CLAUDE.md](./CLAUDE.md) for full instructions, first-login steps, HTTPS setup, troubleshooting, and adding new services.
