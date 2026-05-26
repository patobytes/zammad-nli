# Zammad Deployment — Claude Code Instructions

## Architecture

| Environment | Infra | Stack |
|---|---|---|
| **Prod** | Azure VM (Brazil South) | Docker Compose on Ubuntu 22.04 |
| **Dev / HML** | Proxmox (on-prem) | Docker Compose with local volumes |

### Service layout (prod VM)

```
Internet → NSG (22/80/443) → VM
                               ├── NPM Plus          :80/:443         reverse proxy + SSL  (proxy-net)
                               ├── Zammad nginx      localhost:8080   via proxy-net only
                               ├── Portainer CE      localhost:9000   via SSH tunnel / proxy-net
                               └── GlobaLeaks tenant-n              isolated on gl-<tenant>-net
```

NPM Plus is the single internet-facing entry point. Services that must be isolated get their own Docker network; NPM Plus hot-connects to each one via `docker network connect` (no restart needed).

### Docker networks

| Network | Subnet | Services |
|---|---|---|
| `proxy-net` | `172.20.0.0/24` | NPM Plus, Portainer, zammad-nginx |
| `gl-<tenant>-net` | `172.21.<n>.0/24` | One GlobaLeaks instance per tenant |
| Zammad default | Docker-assigned | zammad, postgresql, redis, elasticsearch |

`proxy-net` is pre-created by `vm-setup.sh`. Tenant networks are created on demand by `scripts/globaleaks-add-tenant.sh`, auto-incrementing the third octet starting at 1 (`172.21.1.0/24`, `172.21.2.0/24`, …). All compose files reference them as `external: true`.

**Isolation rule:** tenant networks have no path to `proxy-net` or to each other. Tenants can only be reached through NPM Plus, which is hot-connected to each new tenant network on deploy.

To add IPAM config to an existing named network: `docker network rm <name> && docker network create --driver bridge --subnet <cidr> <name>`, then restart affected containers.

### Services directory

Each service has a compose file under `services/`:

```
services/
  npm/docker-compose.yml          NPM Plus — proxy-net
  portainer/docker-compose.yml    Portainer CE — proxy-net
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
| NSG | `nsg-zmd-brs` | Ports 22, 80, 443 inbound |
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
   - Creates `proxy-net` Docker bridge network
   - Mounts all three Azure File Shares via CIFS
   - Deploys NPM Plus (ports 80/443), Portainer CE (localhost:9000)
   - Clones Zammad, writes `.env` and `docker-compose.override.yml`, starts stack

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
