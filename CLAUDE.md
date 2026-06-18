# Zammad Deployment — Claude Code Instructions

## Architecture

| Environment | Infra | Stack |
|---|---|---|
| **Prod** | Azure VM (Brazil South) | Docker Compose on Ubuntu 22.04 |
| **Dev / HML** | Proxmox (on-prem) | Docker Compose with local volumes |

### Service layout (prod VM)

```
Internet → NSG (22/80/443/4222) → VM
                                    ├── NPM Plus          :80/:443         reverse proxy + SSL  (proxy-net)
                                    ├── Zammad nginx      localhost:8080   via proxy-net only
                                    ├── Portainer CE      localhost:9000   via SSH tunnel / proxy-net
                                    ├── Tactical RMM      (trmm-nginx bridges proxy-net ↔ trmm-net)
                                    │     └── NATS agent comms  :4222  direct (TCP/TLS, not via NPM)
                                    └── GlobaLeaks tenant-n              isolated on gl-<tenant>-net
```

NPM Plus is the single internet-facing entry point. Services that must be isolated get their own Docker network; NPM Plus hot-connects to each one via `docker network connect` (no restart needed).

### Docker networks

| Network | Subnet | Services |
|---|---|---|
| `proxy-net` | `172.20.0.0/24` | NPM Plus, Portainer, zammad-nginx, trmm-nginx |
| `trmm-net` | `172.20.2.0/24` | trmm-nginx + all TRMM internal services |
| `gl-<tenant>-net` | `172.21.<n>.0/24` | One GlobaLeaks instance per tenant |
| Zammad default | Docker-assigned | zammad, postgresql, redis, elasticsearch |

`proxy-net` and `trmm-net` are both pre-created by `vm-setup.sh`. Tenant networks are created on demand by `scripts/globaleaks-add-tenant.sh`, auto-incrementing the third octet starting at 1 (`172.21.1.0/24`, `172.21.2.0/24`, …). All compose files reference them as `external: true`.

**Isolation rule:** tenant networks have no path to `proxy-net` or to each other. Tenants can only be reached through NPM Plus, which is hot-connected to each new tenant network on deploy.

To add IPAM config to an existing named network: `docker network rm <name> && docker network create --driver bridge --subnet <cidr> <name>`, then restart affected containers.

### Services directory

Each service has a compose file under `services/`:

```
services/
  npm/docker-compose.yml          NPM Plus — proxy-net
  portainer/docker-compose.yml    Portainer CE — proxy-net
  trmm/docker-compose.yml         Tactical RMM — trmm-net (nginx bridges to proxy-net)
  trmm/.env.dist                  TRMM environment template
  globaleaks/docker-compose.yml   GlobaLeaks — globaleaks-net (isolated)
```

`vm-setup.sh` writes these files inline to the VM (the repo is not cloned on the VM). The `services/` files are the canonical source of truth — keep them in sync with the heredocs in `vm-setup.sh` and `zammad.bicep`.

### Prod resources (Azure, `rg-zmd-brs`, Brazil South)

| Resource | Name | SKU |
|---|---|---|
| Resource Group | `rg-zmd-brs` | — |
| Virtual Machine | `vm-zmd-brs` | Standard_B2ms (2 vCPU / 8 GB) |
| OS Disk | — | Premium SSD, 64 GB |
| VNet | `vnet-zmd-brs` | 10.0.0.0/16 |
| NSG | `nsg-zmd-brs` | Ports 22, 80, 443, 4222 inbound |
| Public IP | `pip-zmd-brs` | Static, Standard SKU |
| Storage Account | `stzmdbrsvi7puq3ozfbso` | Standard LRS |
| File Share | `zammad-storage` | 100 GB (attachments) |
| File Share | `zammad-backup` | 50 GB (backups) |
| File Share | `npm-certs` | 10 GB (NPM Plus certs + config, shareable) |

### Data persistence
Azure File Shares are mounted on the VM via CIFS/SMB 3.0 (encrypted in transit).
Docker Compose volumes are bound to the mount points via `docker-compose.override.yml`.
All data (attachments, backups, SSL certs) survives VM deletion and recreation.

The `npm-certs` share stores NPM Plus `/data` (certs, config). Mount it on any VM to reuse
the same certificates across services without re-issuing.

### Subscription
`09a573e4-8b7e-4a95-8051-a21f01e0a758` — Microsoft Azure Sponsorship

---

## Prerequisites

### 1. SSH key pair
```powershell
ssh-keygen -t ed25519 -C "zammad-azure" -f "$env:USERPROFILE\.ssh\zammad_azure"
```

### 2. Azure CLI logged in
```powershell
az login --use-device-code
az account set --subscription 09a573e4-8b7e-4a95-8051-a21f01e0a758
```

---

## Deploy to Azure (prod)

```powershell
az deployment sub create `
  --location brazilsouth `
  --name "zmd-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --template-file main.bicep `
  --parameters `
    sshPublicKey="$(Get-Content $env:USERPROFILE\.ssh\zammad_azure.pub)" `
    postgresPassword="YourSecurePassword123!"
```

Optional parameters:
- `zammadFqdn="zammad.example.com"` — custom domain (defaults to Azure auto-generated FQDN)
- `vmSize="Standard_B2ms"` — VM size (default)
- `vmAdminUsername="zammadadmin"` — SSH user (default)

### What happens during deployment (~15 min)
1. Resource group `rg-zmd-brs` created
2. Storage Account + File Shares (`zammad-storage`, `zammad-backup`, `npm-certs`) provisioned
3. VNet, NSG, Public IP, NIC created
4. VM provisioned (Ubuntu 22.04 LTS, 64 GB Premium SSD)
5. Custom Script Extension runs `vm-setup.sh`:
   - Installs Docker + Docker Compose
   - Creates `proxy-net` (172.20.0.0/24) and `trmm-net` (172.20.2.0/24) Docker bridge networks
   - Mounts all three Azure File Shares via CIFS
   - Deploys NPM Plus (ports 80/443), Portainer CE (localhost:9000)
   - Clones Zammad, writes `.env` and `docker-compose.override.yml`, starts stack
   - Writes `/opt/scripts/trmm-setup.sh` (run manually to deploy TRMM)

### First access
```powershell
# Get outputs
az deployment sub show `
  --name <deployment-name> `
  --query 'properties.outputs' -o json

# Check setup log on VM
ssh -i $env:USERPROFILE\.ssh\zammad_azure zammadadmin@<vm-public-ip> `
  'cat /var/log/zammad-setup.log'

# Check all running containers
ssh -i $env:USERPROFILE\.ssh\zammad_azure zammadadmin@<vm-public-ip> `
  'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
```

---

## Admin UIs (SSH tunnel access)

Both admin UIs bind to `localhost` only on the VM. Use an SSH tunnel to access them.

### NPM Plus admin (port 81)
```powershell
ssh -i $env:USERPROFILE\.ssh\zammad_azure -L 81:localhost:81 -N zammadadmin@20.226.75.51
```
Then open `http://localhost:81` in your browser.
Default credentials: `admin@example.com` / `changeme` — **change immediately**.

Configure proxy host for Zammad:
- Domain: `zmd-brs-vi7puq3ozfbso.brazilsouth.cloudapp.azure.com` (or your custom domain)
- Scheme: `http`, Hostname: `zammad-nginx-1`, Port: `80`
- Enable SSL, request a Let's Encrypt certificate

### Portainer CE (port 9000)
```powershell
ssh -i $env:USERPROFILE\.ssh\zammad_azure -L 9000:localhost:9000 -N zammadadmin@20.226.75.51
```
Then open `http://localhost:9000` in your browser.

Alternatively, add a proxy host in NPM Plus pointing to `portainer:9000` on `proxy-net`.

---

## Adding new services

### Option A — shared on proxy-net (service can see Zammad)

Add a compose file under `services/<name>/docker-compose.yml` and deploy to `/opt/<name>/`:

```yaml
services:
  myservice:
    image: myimage:latest
    container_name: myservice
    restart: unless-stopped
    volumes:
      - mydata:/data
    networks:
      - proxy-net

volumes:
  mydata:

networks:
  proxy-net:
    external: true
```

Then in NPM Plus: add a proxy host pointing to `myservice:<port>`.

### Option B — isolated network (service cannot see Zammad or other tenants)

Use this for sensitive services. GlobaLeaks is the primary example — each tenant gets a completely isolated network.

**For GlobaLeaks specifically**, use the dedicated script:

```bash
sudo bash /opt/scripts/globaleaks-add-tenant.sh <tenant-slug>
```

This auto-allocates the next `172.21.<n>.0/24`, creates the network, deploys the container, and hot-connects NPM Plus. Then add a proxy host in NPM Plus pointing to `globaleaks-<tenant>:8083`.

**For other isolated services**, follow this pattern:

1. Create the network with a new /24 (pick the next free third-octet):
   ```bash
   docker network create --driver bridge --subnet 172.2X.<n>.0/24 <name>-net
   ```
2. Create `services/<name>/docker-compose.yml` (use `services/globaleaks/docker-compose.yml` as the template)
3. Hot-connect NPM Plus — **no restart needed**:
   ```bash
   docker network connect <name>-net npm
   ```
4. In NPM Plus: add a proxy host pointing to `<container>:<port>`

**Teardown** (any isolated service):
```bash
docker compose -f /opt/<service>/docker-compose.yml down
docker network disconnect <name>-net npm
docker network rm <name>-net
```

---

## Tactical RMM

Remote Monitoring & Management for all client devices. Agents connect **outbound** on port 443 (HTTPS) and 4222 (NATS/TLS) — devices behind NAT at client sites work without any inbound firewall changes on the client side. Only the server needs a public IP.

### Deploy TRMM (first time)

```bash
# SSH into the VM
ssh -i ~/.ssh/zammad_azure zammadadmin@<vm-public-ip>

# Set required env vars
export APP_HOST=rmm.yourdomain.com
export API_HOST=api.yourdomain.com
export MESH_HOST=mesh.yourdomain.com
export MESH_USER=meshcentral
export MESH_PASS=YourMeshPassword!
export POSTGRES_PASS=YourTRMMDbPassword!
export SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

sudo bash /opt/scripts/trmm-setup.sh
```

The script:
1. Writes `/opt/trmm/.env` and `/opt/trmm/docker-compose.yml`
2. Runs the `tactical-init` container (generates NATS TLS certs, Django config, nginx config)
3. Starts the full TRMM stack
4. Hot-connects NPM Plus to `trmm-net`
5. Prints the NPM Plus proxy host config to the console

### NPM Plus proxy hosts

After running `trmm-setup.sh`, add these three proxy hosts in the NPM Plus admin (`http://localhost:81`):

| Domain | Scheme | Forward Hostname | Port | SSL | WebSockets | Notes |
|---|---|---|---|---|---|---|
| `rmm.yourdomain.com` | http | `trmm-nginx` | 80 | Let's Encrypt | Off | TRMM web UI |
| `api.yourdomain.com` | http | `trmm-nginx` | 80 | Let's Encrypt | **On** | REST API + agent check-in |
| `mesh.yourdomain.com` | http | `trmm-nginx` | 80 | Let's Encrypt | **On** | MeshCentral remote desktop |

**Advanced tab — Custom Nginx config** (paste into each proxy host):

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

### NATS (port 4222) — Azure NSG

NATS is TCP/TLS and cannot be proxied through NPM Plus. Agents connect directly to `api.yourdomain.com:4222`.

Add an inbound rule to the NSG (`nsg-zmd-brs`):
```powershell
az network nsg rule create `
  --resource-group rg-zmd-brs `
  --nsg-name nsg-zmd-brs `
  --name Allow-NATS-Inbound `
  --priority 310 `
  --protocol Tcp `
  --destination-port-ranges 4222 `
  --access Allow `
  --direction Inbound
```

### Intune integration (cloud-managed clients)

For clients with Intune / Entra ID managed devices:

**Deploy TRMM agent via Intune Win32 app:**
1. Download the agent installer from TRMM: `rmm.yourdomain.com` → Agents → Install Agent → download `.exe`
2. Package as Win32 app in Intune (`.intunewin` format using `IntuneWinAppUtil.exe`)
3. Install command: `agent-installer.exe /S`
4. Detection rule: registry key `HKLM:\SOFTWARE\TacticalRMM`
5. Assign to all devices or a specific device group

**Azure AD / Entra SSO for TRMM console:**
TRMM supports Azure AD OIDC. Configure under TRMM Settings → Single Sign-On → Azure AD.
Your staff log into the TRMM dashboard with their Microsoft account.

### Zammad integration

Auto-create tickets when TRMM fires an alert (offline device, disk full, etc.):

1. In TRMM: Settings → Webhooks → Add webhook
   - URL: `https://zammad.yourdomain.com/api/v1/tickets`
   - Method: POST
   - Headers: `Authorization: Token token=<zammad-api-token>`
2. Map TRMM alert fields to Zammad ticket fields (title, group, priority)
3. In TRMM: Automation → Alert → assign the webhook

### Manage TRMM

```bash
# Logs
ssh zammadadmin@<ip> 'docker compose -f /opt/trmm/docker-compose.yml logs -f --tail=100'

# Restart stack
ssh zammadadmin@<ip> 'docker compose -f /opt/trmm/docker-compose.yml restart'

# Update to a new TRMM version
# Edit /opt/trmm/.env → set TRMM_VERSION=x.y.z, then:
ssh zammadadmin@<ip> 'docker compose -f /opt/trmm/docker-compose.yml pull && docker compose -f /opt/trmm/docker-compose.yml up -d'
```

### Remove TRMM

```bash
docker compose -f /opt/trmm/docker-compose.yml down -v   # -v removes volumes (all data)
docker network disconnect trmm-net npm
docker network rm trmm-net
rm -rf /opt/trmm
```

---

## Syncing upstream Zammad updates

This repo forks [zammad/zammad-docker-compose](https://github.com/zammad/zammad-docker-compose).
The `upstream` remote is already configured. Upstream only ever changes `docker-compose.yml`
(image bumps, new services) and `.env.dist` (new env vars) — all Azure customizations live in
separate files and merge cleanly.

```bash
git fetch upstream
git merge upstream/master
```

**Conflicts to expect** (only in `docker-compose.yml`): image version numbers.
Always take upstream's version — those are patch/security updates.

```bash
# Accept upstream's image versions for both conflict hunks, then:
git add docker-compose.yml
git commit   # merge commit message is pre-filled
git push origin master
```

**Why conflicts stay minimal:** production overrides live in `docker-compose.override.prod.yml`,
not in `docker-compose.yml`. Never edit `docker-compose.yml` directly — put any local changes
in the override file instead.

---

## Dev / HML on Proxmox

No Azure resources needed. Run the upstream stack directly:

```bash
git clone https://github.com/zammad/zammad-docker-compose /opt/zammad
cd /opt/zammad
cp .env.dist .env
# Edit .env: set POSTGRES_PASS, ZAMMAD_FQDN, TZ
docker compose up -d
```

Volumes use local Docker storage — no Azure Files mount needed.

---

## HTTPS

NPM Plus handles SSL. After first login at `http://localhost:81` (via SSH tunnel):
1. Add a proxy host for your domain → Zammad at `zammad-nginx-1:80`
2. Enable SSL tab → Request Let's Encrypt certificate
3. Certs are saved to `/mnt/npm-certs` (Azure Files, persistent across VM recreations)
4. Update Zammad `.env`: `ZAMMAD_HTTP_TYPE=https`

---

## Troubleshooting

### Check setup log
```bash
ssh -i ~/.ssh/zammad_azure zammadadmin@20.226.75.51 'cat /var/log/zammad-setup.log'
```

### Check all services
```bash
ssh -i ~/.ssh/zammad_azure zammadadmin@20.226.75.51 'docker ps --format "table {{.Names}}\t{{.Status}}"'
```

### Re-run setup manually (idempotent)
```bash
ssh -i ~/.ssh/zammad_azure zammadadmin@20.226.75.51
export STORAGE_ACCOUNT=stzmdbrsvi7puq3ozfbso
export STORAGE_KEY=<key from Azure portal>
export POSTGRES_PASS=<pass>
export ZAMMAD_FQDN=zmd-brs-vi7puq3ozfbso.brazilsouth.cloudapp.azure.com
export VM_ADMIN=zammadadmin
sudo bash /opt/vm-setup.sh
```

### Docker Compose logs per service
```bash
ssh zammadadmin@20.226.75.51 'cd /opt/zammad && docker compose logs -f --tail=100'
ssh zammadadmin@20.226.75.51 'docker logs npm --tail=50'
ssh zammadadmin@20.226.75.51 'docker logs portainer --tail=50'
```

### Azure File Share not mounting
- Confirm port 445 outbound is not blocked (Azure NSG allows all outbound by default)
- Test manually: `mount -t cifs //stzmdbrsvi7puq3ozfbso.file.core.windows.net/npm-certs /mnt/test -o credentials=/etc/smbcredentials/zammad.cred,vers=3.0`

### Reset VM (data preserved)
Delete and redeploy the VM. All Azure File Shares retain data across VM recreations.

---

## Cleanup
```powershell
az group delete --name rg-zmd-brs --yes --no-wait
```
This deletes the VM **and** the storage account. **All data will be lost.**
