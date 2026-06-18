# Deploy Context: Zammad + TRMM MSP Stack — Azure Brazil South

> **Category:** infrastructure / azure / msp-stack
> **Export date:** 2026-06-18
> **Repo:** `zammad-nli` (fork of zammad/zammad-docker-compose)

---

## What this is

A production MSP stack running on a single Azure VM (Brazil South). Core components:

- **Zammad** — helpdesk / ticketing
- **Tactical RMM** — remote monitoring & management (wraps MeshCentral for remote desktop)
- **NPM Plus** — nginx reverse proxy + SSL (single internet-facing entry point)
- **GlobaLeaks** — anonymous whistleblowing platform (multi-tenant, fully isolated)
- **Portainer CE** — Docker container management UI

All on one `Standard_B2ms` VM (2 vCPU / 8 GB), costs kept low with Azure Sponsorship subscription.

---

## Azure Resources

| Resource | Name | Detail |
|---|---|---|
| Subscription | `Microsoft Azure Sponsorship` | ID: `09a573e4-8b7e-4a95-8051-a21f01e0a758` |
| Resource Group | `rg-zmd-brs` | Brazil South |
| VM | `vm-zmd-brs` | Standard_B2ms · Ubuntu 22.04 · Premium SSD 64 GB |
| Public IP | `pip-zmd-brs` | `20.226.75.51` (static) |
| VNet | `vnet-zmd-brs` | `10.0.0.0/16` |
| NSG | `nsg-zmd-brs` | Inbound: 22 (SSH), 80 (HTTP), 443 (HTTPS), **4222 (NATS/TLS)** |
| Storage Account | `stzmdbrsvi7puq3ozfbso` | Standard LRS |
| File Share | `zammad-storage` | 100 GB — Zammad attachments (CIFS/SMB 3.0) |
| File Share | `zammad-backup` | 50 GB — Zammad backups |
| File Share | `npm-certs` | 10 GB — NPM Plus TLS certs + config (survives VM recreation) |
| Key Vault | `kv-zmd-brs` | `https://kv-zmd-brs.vault.azure.net/` · RBAC mode |

---

## Key Vault Secrets (`kv-zmd-brs`)

Values are never written to files or repos — always retrieve via `az keyvault secret show`.

| Secret name | Contents |
|---|---|
| `trmm-secret-key` | Django `SECRET_KEY` (auto-generated) |
| `trmm-postgres-pass` | TRMM PostgreSQL password (auto-generated) |
| `trmm-mesh-pass` | MeshCentral admin password (auto-generated) |
| `cpanel-host` | `http://daserie.com.br:2082` |
| `cpanel-username` | cPanel account for `nextlevelinfo.com.br` DNS |
| `cpanel-api-token` | cPanel UAPI token for DNS management |

Retrieve a secret:
```bash
az account set --subscription 09a573e4-8b7e-4a95-8051-a21f01e0a758
az keyvault secret show --vault-name kv-zmd-brs --name <name> --query value -o tsv
```

---

## Docker Network Layout

```
proxy-net  172.20.0.0/24   NPM Plus, Portainer, zammad-nginx, trmm-nginx
trmm-net   172.20.2.0/24   trmm-nginx (bridge) + trmm-backend/websockets/celery/meshcentral/nats/postgres/redis
gl-*-net   172.21.n.0/24   One per GlobaLeaks tenant (isolated — no path to proxy-net or each other)
default    Docker-assigned  zammad, postgresql, redis, elasticsearch
```

`trmm-nginx` is the only container on both `proxy-net` and `trmm-net`. All other TRMM services are isolated on `trmm-net`. No TRMM service can reach Zammad.

---

## DNS — `nextlevelinfo.com.br`

Managed via cPanel UAPI at `daserie.com.br:2082`. Updated automatically by `scripts/cpanel-dns-update.sh` (reads cPanel creds from Key Vault).

| Subdomain | Service | Notes |
|---|---|---|
| `zammad.nextlevelinfo.com.br` | Zammad helpdesk | via NPM Plus → zammad-nginx-1:80 |
| `rmm.nextlevelinfo.com.br` | TRMM web UI | via NPM Plus → trmm-nginx:80 |
| `api-rmm.nextlevelinfo.com.br` | TRMM REST API + agent check-in | via NPM Plus → trmm-nginx:80; NATS direct on :4222 |
| `mesh.nextlevelinfo.com.br` | MeshCentral remote desktop | via NPM Plus → trmm-nginx:80 |

`api.nextlevelinfo.com.br` deliberately left free for future use.

---

## Port Map

| Port | Protocol | Entry point | Service |
|---|---|---|---|
| 80 | TCP | NSG → NPM Plus | HTTP (redirects to 443) |
| 443 | TCP | NSG → NPM Plus | HTTPS — all web services |
| 4222 | **TCP/TLS** | **NSG → trmm-nats directly** | **NATS — TRMM agent messaging** |
| 22 | TCP | NSG | SSH (key-only, ed25519) |
| 81 | TCP | localhost only | NPM Plus admin UI (SSH tunnel) |
| 9000 | TCP | localhost only | Portainer CE (SSH tunnel) |

Port 4222 bypasses NPM Plus — NATS is TCP not HTTP and cannot be proxied by nginx.

---

## NPM Plus Proxy Hosts

| Domain | Forward | Port | Notes |
|---|---|---|---|
| `zammad.nextlevelinfo.com.br` | `zammad-nginx-1` | 80 | Let's Encrypt |
| `rmm.nextlevelinfo.com.br` | `trmm-nginx` | 80 | Let's Encrypt + WebSocket headers |
| `api-rmm.nextlevelinfo.com.br` | `trmm-nginx` | 80 | Let's Encrypt + WebSocket headers |
| `mesh.nextlevelinfo.com.br` | `trmm-nginx` | 80 | Let's Encrypt + WebSocket headers |

NPM Plus does not have a WebSocket toggle. Required custom nginx block in Advanced tab for all TRMM hosts:
```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

---

## SSH Access

```powershell
# Direct
ssh -i $env:USERPROFILE\.ssh\zammad_azure zammadadmin@20.226.75.51

# NPM Plus admin tunnel (port 81)
ssh -i $env:USERPROFILE\.ssh\zammad_azure -L 81:localhost:81 -N zammadadmin@20.226.75.51

# Portainer tunnel (port 9000)
ssh -i $env:USERPROFILE\.ssh\zammad_azure -L 9000:localhost:9000 -N zammadadmin@20.226.75.51
```

---

## TRMM Agent Deployment (Intune / Entra ID clients)

Two clients use cloud-managed devices (Intune/Entra ID). Deploy TRMM agent as Win32 app:

1. Download installer from TRMM: Agents → Install Agent → `.exe`
2. Package with `IntuneWinAppUtil.exe` → `.intunewin`
3. Install command: `agent-installer.exe /S`
4. Detection rule: registry key `HKLM:\SOFTWARE\TacticalRMM`
5. Assign to device group in Intune

For NAT-traversal (all other clients): agents connect outbound on 443 and 4222 — no client-side firewall changes needed.

---

## Key Scripts

| Script | Location on VM | What it does |
|---|---|---|
| `vm-setup.sh` | `/opt/vm-setup.sh` | Full bootstrap (idempotent) |
| `trmm-setup.sh` | `/opt/scripts/trmm-setup.sh` | Deploy TRMM (run manually after DNS) |
| `cpanel-dns-update.sh` | `/opt/scripts/cpanel-dns-update.sh` | Update DNS A records for TRMM subdomains |
| `globaleaks-add-tenant.sh` | `/opt/scripts/globaleaks-add-tenant.sh` | Add isolated GlobaLeaks tenant |

---

## Pending / Next Steps

- [ ] Run `trmm-setup.sh` on VM after DNS propagates
- [ ] Configure NPM Plus Advanced tab (WebSocket headers) on all 3 TRMM proxy hosts
- [ ] First TRMM login at `rmm.nextlevelinfo.com.br` — change admin password
- [ ] Configure Entra ID OIDC for staff SSO (TRMM Settings → Single Sign-On → Azure AD)
- [ ] Add Zammad webhook in TRMM (Settings → Webhooks) for auto-ticket on alerts
- [ ] Package TRMM agent as Intune Win32 app for cloud-managed clients

---

## Repo

`zammad-nli` — fork of [zammad/zammad-docker-compose](https://github.com/zammad/zammad-docker-compose)

Branch: `master` | SSH key: `~/.ssh/zammad_azure`
