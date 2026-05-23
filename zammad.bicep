// ─────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────

param location string
param zammadAppName string
param postgresServerName string
param redisName string
param linuxPlanName string
param postgresAdminUser string

@secure()
param postgresAdminPassword string

// ─────────────────────────────────────────────
// Linux App Service Plan (B2)
// The existing cipp-srv-brs-asp is Windows/EP
// and cannot host Linux containers.
// B2 gives 2 vCPU + 3.5 GB RAM — Zammad minimum.
// ─────────────────────────────────────────────

resource appPlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: linuxPlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'B2'
    tier: 'Basic'
  }
  properties: {
    reserved: true   // required for Linux
  }
}

// ─────────────────────────────────────────────
// Azure Database for PostgreSQL Flexible Server
// Burstable B1ms — sufficient for Zammad.
// Upgrade to Standard_D2ds_v4 for heavy load.
// ─────────────────────────────────────────────

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: postgresServerName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '15'
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

resource zammadDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = {
  parent: postgresServer
  name: 'zammad_production'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Allow all Azure-sourced IPs to reach PostgreSQL
// (0.0.0.0 → 0.0.0.0 is the Azure Services sentinel value)
resource postgresFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2022-12-01' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ─────────────────────────────────────────────
// Azure Cache for Redis (Basic C0)
// Zammad uses Redis for Action Cable and jobs.
// Upgrade to Standard C1 for HA.
// ─────────────────────────────────────────────

resource redis 'Microsoft.Cache/redis@2023-08-01' = {
  name: redisName
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
  }
}

// ─────────────────────────────────────────────
// Zammad Web App (Linux container)
// Image: ghcr.io/zammad/zammad:latest
// Port: 3000 (Rails server)
//
// NOTE: This runs the Rails web server only.
// Background scheduler + WebSocket server are
// separate Zammad processes. For full
// functionality deploy them as additional
// Web Jobs or container instances, or
// switch to Azure Container Apps.
// ─────────────────────────────────────────────

var secretKeyBase = '${uniqueString(resourceGroup().id, zammadAppName)}${uniqueString(postgresServerName, redisName)}${uniqueString(location, subscription().subscriptionId)}'

var databaseUrl = 'postgres://${postgresAdminUser}:${postgresAdminPassword}@${postgresServer.properties.fullyQualifiedDomainName}:5432/zammad_production?sslmode=require'

var redisUrl = 'rediss://:${redis.listKeys().primaryKey}@${redis.properties.hostName}:6380/0'

resource zammadApp 'Microsoft.Web/sites@2022-09-01' = {
  name: zammadAppName
  location: location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|ghcr.io/zammad/zammad:latest'
      alwaysOn: true
      webSocketsEnabled: true
      http20Enabled: true
      minTlsVersion: '1.2'
      appSettings: [
        // Container registry
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://ghcr.io'
        }
        {
          name: 'DOCKER_ENABLE_CI'
          value: 'false'
        }
        // Tell App Service which port the container listens on
        {
          name: 'WEBSITES_PORT'
          value: '3000'
        }
        // Rails / Zammad core
        {
          name: 'RAILS_ENV'
          value: 'production'
        }
        {
          name: 'RAILS_LOG_TO_STDOUT'
          value: 'true'
        }
        {
          name: 'RAILS_SERVE_STATIC_FILES'
          value: 'true'
        }
        {
          name: 'SECRET_KEY_BASE'
          value: secretKeyBase
        }
        // Database
        {
          name: 'DATABASE_URL'
          value: databaseUrl
        }
        // Redis
        {
          name: 'REDIS_URL'
          value: redisUrl
        }
        // Disable Elasticsearch (Zammad 6.x uses PG full-text as fallback)
        {
          name: 'ELASTICSEARCH_ENABLED'
          value: 'false'
        }
        // Container logging
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
      ]
    }
  }
  dependsOn: [
    postgresServer
    redis
  ]
}

// ─────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────

output zammadUrl string = 'https://${zammadApp.properties.defaultHostName}'
output postgresHost string = postgresServer.properties.fullyQualifiedDomainName
output redisHost string = redis.properties.hostName
