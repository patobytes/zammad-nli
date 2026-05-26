// ─────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────

param location string
param vmAdminUsername string
param sshPublicKey string
param vmSize string = 'Standard_B2ms'
param zammadFqdn string = ''

@secure()
param postgresPassword string

// ─────────────────────────────────────────────
// Azure Storage Account + File Shares
// Provides data persistence independent of the
// VM lifecycle. Zammad attachments and backups
// survive VM deletion/recreation.
// Equivalent to AWS EFS for this workload.
// ─────────────────────────────────────────────

var storageAccountName = take('stzmdbrs${uniqueString(resourceGroup().id)}', 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource storageShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'zammad-storage'
  properties: { shareQuota: 100 }
}

resource backupShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'zammad-backup'
  properties: { shareQuota: 50 }
}

resource npmCertsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'npm-certs'
  properties: { shareQuota: 10 }
}

// ─────────────────────────────────────────────
// Network Security Group
// ─────────────────────────────────────────────

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'nsg-zmd-brs'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-HTTP'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-HTTPS'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// ─────────────────────────────────────────────
// VNet + Subnet
// ─────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'vnet-zmd-brs'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'snet-zmd-brs'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ─────────────────────────────────────────────
// Static Public IP
// ─────────────────────────────────────────────

resource pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-zmd-brs'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'zmd-brs-${uniqueString(resourceGroup().id)}'
    }
  }
}

// ─────────────────────────────────────────────
// Network Interface
// ─────────────────────────────────────────────

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'nic-zmd-brs'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
          subnet: { id: '${vnet.id}/subnets/snet-zmd-brs' }
        }
      }
    ]
  }
}

// ─────────────────────────────────────────────
// Virtual Machine
// Standard_B2ms: 2 vCPU / 8 GB RAM
// Ubuntu 22.04 LTS Gen2, 64 GB Premium SSD
// Runs full Zammad stack via docker compose.
// ─────────────────────────────────────────────

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'vm-zmd-brs'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
    }
    osProfile: {
      computerName: 'vm-zmd-brs'
      adminUsername: vmAdminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

// ─────────────────────────────────────────────
// Custom Script Extension
// Installs Docker, mounts Azure File Shares,
// clones Zammad, and starts docker compose.
// Secrets live only in protectedSettings
// (encrypted at rest and in transit by ARM).
// ─────────────────────────────────────────────

var storageKey = storageAccount.listKeys().keys[0].value
var effectiveFqdn = empty(zammadFqdn) ? pip.properties.dnsSettings.fqdn : zammadFqdn

// scriptHeader uses Bicep interpolation to inject secrets.
// scriptBody is a raw string — ${VAR} inside it is bash syntax, not Bicep.
var scriptHeader = '#!/bin/bash\nset -euo pipefail\n\nSTORAGE_ACCOUNT="${storageAccountName}"\nSTORAGE_KEY="${storageKey}"\nSTORAGE_HOST="${storageAccountName}.file.${environment().suffixes.storage}"\nPOSTGRES_PASS="${postgresPassword}"\nZAMMAD_FQDN="${effectiveFqdn}"\nVM_ADMIN="${vmAdminUsername}"\n'

var scriptBody = '''
APP_DIR="/opt/zammad"
LOG="/var/log/zammad-setup.log"
exec >> "${LOG}" 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting setup"

# ── Docker ───────────────────────────────────────────────────────────────────
DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl gnupg cifs-utils git

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "${VM_ADMIN}"
systemctl enable --now docker

# proxy-net  172.20.0.0/24 — shared: NPM Plus, Portainer, Zammad nginx
# globaleaks-net 172.21.0.0/24 — isolated: GlobaLeaks only (NPM Plus attaches when deployed)
docker network create --driver bridge --subnet 172.20.0.0/24 proxy-net 2>/dev/null || true
docker network create --driver bridge --subnet 172.21.0.0/24 globaleaks-net 2>/dev/null || true

# ── Azure File Shares (SMB 3.0, TLS in transit) ───────────────────────────────
mkdir -p /mnt/zammad-storage /mnt/zammad-backup /mnt/npm-certs /etc/smbcredentials
printf 'username=%s\npassword=%s\n' "${STORAGE_ACCOUNT}" "${STORAGE_KEY}" \
  > /etc/smbcredentials/zammad.cred
chmod 600 /etc/smbcredentials/zammad.cred

grep -q "zammad-storage" /etc/fstab || cat >> /etc/fstab << FSTABEOF
//${STORAGE_HOST}/zammad-storage /mnt/zammad-storage cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
//${STORAGE_HOST}/zammad-backup  /mnt/zammad-backup  cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
//${STORAGE_HOST}/npm-certs      /mnt/npm-certs      cifs credentials=/etc/smbcredentials/zammad.cred,vers=3.0,dir_mode=0777,file_mode=0777,serverino,nosuid,nodev,_netdev 0 0
FSTABEOF
mount -a

# ── NPM Plus (reverse proxy + SSL) ───────────────────────────────────────────
# Admin UI on localhost:81 only — access via: ssh -L 81:localhost:81 zammadadmin@<ip>
# Default login: admin@example.com / changeme  (change immediately after first login)
# SQLite DB stays on a local Docker volume (CIFS/SMB doesn't support SQLite locking).
# /data/letsencrypt is mounted from Azure Files — certs survive VM recreations and
# can be read by any other service that mounts /mnt/npm-certs.
mkdir -p /opt/npm
cat > /opt/npm/docker-compose.yml << 'NPMEOF'
services:
  npm:
    image: ghcr.io/zoeyvid/npmplus:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:81:81"
    volumes:
      - npm-data:/data
      - /mnt/npm-certs:/data/letsencrypt
    environment:
      - TZ=America/Sao_Paulo
    networks:
      - proxy-net

volumes:
  npm-data:

networks:
  proxy-net:
    external: true
NPMEOF
docker compose -f /opt/npm/docker-compose.yml pull
docker compose -f /opt/npm/docker-compose.yml up -d

# ── Portainer CE (Docker management UI) ──────────────────────────────────────
# Access via SSH tunnel: ssh -L 9000:localhost:9000 zammadadmin@<ip>
# Or add a proxy host in NPM Plus pointing to portainer:9000
mkdir -p /opt/portainer
cat > /opt/portainer/docker-compose.yml << 'PORTAINEREOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    networks:
      - proxy-net

volumes:
  portainer-data:

networks:
  proxy-net:
    external: true
PORTAINEREOF
docker compose -f /opt/portainer/docker-compose.yml pull
docker compose -f /opt/portainer/docker-compose.yml up -d

# ── Zammad ────────────────────────────────────────────────────────────────────
# nginx binds localhost:8080 only; NPM Plus reaches it at http://zammad-nginx-1:80
[ ! -d "${APP_DIR}/.git" ] && git clone https://github.com/zammad/zammad-docker-compose "${APP_DIR}"
cd "${APP_DIR}"

cat > .env << ENVEOF
POSTGRES_PASS=${POSTGRES_PASS}
NGINX_EXPOSE_PORT=127.0.0.1:8080
TZ=America/Sao_Paulo
ZAMMAD_HTTP_TYPE=http
ZAMMAD_FQDN=${ZAMMAD_FQDN}
ENVEOF

# Copy Zammad's nginx config and fix X-Forwarded-Proto so Rails sees https behind NPM Plus.
# Zammad nginx sets X-Forwarded-Proto=$scheme, which is 'http' (inner connection).
# We pass through the original header from NPM Plus instead.
[ ! -f nginx-zammad.conf ] && docker run --rm --entrypoint cat \
  $(docker compose config --format json | python3 -c "import sys,json; print(json.load(sys.stdin)['services']['zammad-nginx']['image'])") \
  /etc/nginx/sites-available/default > nginx-zammad.conf 2>/dev/null || true
# Fallback: copy from running container
[ ! -s nginx-zammad.conf ] && docker compose cp zammad-nginx:/etc/nginx/sites-available/default nginx-zammad.conf 2>/dev/null || true
sed -i 's/proxy_set_header X-Forwarded-Proto \$scheme;/proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;/g' nginx-zammad.conf

cat > docker-compose.override.yml << 'OVERRIDEEOF'
services:
  zammad-nginx:
    networks:
      default: {}
      proxy-net:
        aliases:
          - zammad-nginx-1
    volumes:
      - /opt/zammad/nginx-zammad.conf:/etc/nginx/sites-available/default:ro

volumes:
  zammad-storage:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/zammad-storage
  zammad-backup:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/zammad-backup

networks:
  proxy-net:
    external: true
OVERRIDEEOF

docker compose pull
docker compose up -d
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Setup complete"
'''

resource vmSetup 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  name: 'setup'
  parent: vm
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      script: base64('${scriptHeader}${scriptBody}')
    }
  }
  dependsOn: [storageShare, backupShare, npmCertsShare]
}

// ─────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────

output vmPublicIp string = pip.properties.ipAddress
output vmFqdn string = pip.properties.dnsSettings.fqdn
output storageAccountName string = storageAccountName
output sshCommand string = 'ssh ${vmAdminUsername}@${pip.properties.ipAddress}'
output zammadUrl string = 'http://${effectiveFqdn}'
