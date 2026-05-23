targetScope = 'subscription'

// ─────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'brazilsouth'

@description('Name of the Zammad Web App (must be globally unique).')
param zammadAppName string = 'zammad-brs-app'

@description('Name of the PostgreSQL Flexible Server (must be globally unique).')
param postgresServerName string = 'zammad-pg-brs'

@description('Name of the Azure Cache for Redis (must be globally unique).')
param redisName string = 'zammad-redis-brs'

@description('Name of the Linux App Service Plan that will host Zammad.')
param linuxPlanName string = 'zammad-asp-brs'

@description('PostgreSQL administrator username.')
param postgresAdminUser string = 'zammadadmin'

@secure()
@description('PostgreSQL administrator password.')
param postgresAdminPassword string

// ─────────────────────────────────────────────
// NOTE: cipp-srv-brs-asp is an ElasticPremium
// Windows plan and cannot host Linux containers.
// A dedicated Linux B2 plan is created instead,
// inside zammad-app-brs-rg.
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
// Resource Group
// ─────────────────────────────────────────────

resource zammadRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'zammad-app-brs-rg'
  location: location
}

// ─────────────────────────────────────────────
// Deploy all Zammad resources into that RG
// ─────────────────────────────────────────────

module zammad 'zammad.bicep' = {
  name: 'zammad-resources'
  scope: zammadRg
  params: {
    location: location
    zammadAppName: zammadAppName
    postgresServerName: postgresServerName
    redisName: redisName
    linuxPlanName: linuxPlanName
    postgresAdminUser: postgresAdminUser
    postgresAdminPassword: postgresAdminPassword
  }
}

// ─────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────

output zammadUrl string = zammad.outputs.zammadUrl
output postgresHost string = zammad.outputs.postgresHost
output redisHost string = zammad.outputs.redisHost
