targetScope = 'subscription'

// ─────────────────────────────────────────────
// Parameters
// ─────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'brazilsouth'

@description('Linux username for the Zammad VM.')
param vmAdminUsername string = 'zammadadmin'

@description('SSH public key content (paste the contents of your .pub file).')
param sshPublicKey string

@description('VM size. B2ms (2 vCPU / 8 GB) is the recommended minimum for Zammad.')
param vmSize string = 'Standard_B2ms'

@description('Custom FQDN for Zammad (e.g. zammad.example.com). Leave empty to use the auto-generated Azure DNS label.')
param zammadFqdn string = ''

@secure()
@description('Password for the Zammad PostgreSQL database.')
param postgresPassword string

// ─────────────────────────────────────────────
// Resource Group
// ─────────────────────────────────────────────

resource zammadRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-zmd-brs'
  location: location
}

// ─────────────────────────────────────────────
// Zammad resources (VM, networking, storage)
// ─────────────────────────────────────────────

module zammad 'zammad.bicep' = {
  name: 'zammad-resources'
  scope: zammadRg
  params: {
    location: location
    vmAdminUsername: vmAdminUsername
    sshPublicKey: sshPublicKey
    postgresPassword: postgresPassword
    zammadFqdn: zammadFqdn
    vmSize: vmSize
  }
}

// ─────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────

output vmPublicIp string = zammad.outputs.vmPublicIp
output vmFqdn string = zammad.outputs.vmFqdn
output storageAccountName string = zammad.outputs.storageAccountName
output sshCommand string = zammad.outputs.sshCommand
output zammadUrl string = zammad.outputs.zammadUrl
