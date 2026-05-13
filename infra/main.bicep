@description('Short environment name used in resource names.')
param environmentName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Storage account SKU.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_RAGRS'
])
param storageSkuName string = 'Standard_LRS'

@description('PostgreSQL administrator login. This account is used only by the Quack container to manage DuckLake metadata.')
param postgresAdminLogin string = 'azquackadmin'

@secure()
@minLength(12)
@description('PostgreSQL administrator password.')
param postgresAdminPassword string

@description('PostgreSQL compute SKU name. Standard_B1ms is the cheapest practical Flexible Server baseline for this prototype.')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL compute tier.')
@allowed([
  'Burstable'
  'GeneralPurpose'
  'MemoryOptimized'
])
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL engine version.')
@allowed([
  '14'
  '15'
  '16'
  '17'
])
param postgresVersion string = '16'

@description('PostgreSQL data storage size in GB.')
param postgresStorageSizeGb int = 32

@description('DuckLake metadata database name.')
param postgresDatabaseName string = 'ducklake_metadata'

@description('Object ID of the human or service principal allowed to read the Quack token for local smoke tests. Empty skips the assignment.')
param operatorPrincipalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Principal type for operatorPrincipalId.')
param operatorPrincipalType string = 'User'

@description('Least-privilege PostgreSQL role used by the Quack runtime for DuckLake metadata.')
param ducklakeCatalogUser string = 'ducklake_app'

@secure()
@minLength(12)
@description('Password for the dedicated DuckLake catalog role.')
param ducklakeCatalogPassword string

@description('Container image for the Azure Container App.')
param containerAppImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('CPU cores for the container app.')
param containerCpu string = '0.5'

@description('Container memory setting.')
param containerMemory string = '1Gi'

@description('DuckLake data path in Azure Blob Storage.')
param ducklakeDataPath string = 'az://lakehouse/data/'

@secure()
@minLength(32)
@description('Shared token required by local DuckDB clients connecting through Quack.')
param quackToken string

var uniqueSuffix = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var storageAccountName = 'st${uniqueSuffix}'
var postgresServerName = toLower('psql-${environmentName}-${substring(uniqueSuffix, 0, 6)}')
var containerAppsEnvironmentName = 'cae-${environmentName}'
var containerAppName = 'ca-${environmentName}'
var containerAppIdentityName = 'id-ca-${environmentName}'
var acrName = 'acr${uniqueSuffix}'
var keyVaultName = 'kv-${substring(uniqueSuffix, 0, 10)}'

resource containerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: containerAppIdentityName
  location: location
}

module storage './modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    storageSkuName: storageSkuName
  }
}

module postgres './modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    location: location
    postgresServerName: postgresServerName
    postgresAdminLogin: postgresAdminLogin
    postgresAdminPassword: postgresAdminPassword
    postgresSkuName: postgresSkuName
    postgresSkuTier: postgresSkuTier
    postgresVersion: postgresVersion
    postgresStorageSizeGb: postgresStorageSizeGb
    postgresDatabaseName: postgresDatabaseName
  }
}

module keyvault './modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    containerAppPrincipalId: containerAppIdentity.properties.principalId
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
    postgresAdminPassword: postgresAdminPassword
    ducklakeCatalogPassword: ducklakeCatalogPassword
    quackToken: quackToken
  }
}

module acr './modules/acr.bicep' = {
  name: 'acr'
  params: {
    location: location
    acrName: acrName
    pullPrincipalId: containerAppIdentity.properties.principalId
  }
}

module containerApp './modules/container-app.bicep' = {
  name: 'containerApp'
  dependsOn: [
    storageBlobDataContributorAssignment
    operatorStorageBlobDataReaderAssignment
  ]
  params: {
    location: location
    containerAppsEnvironmentName: containerAppsEnvironmentName
    containerAppName: containerAppName
    containerAppIdentityId: containerAppIdentity.id
    containerAppIdentityClientId: containerAppIdentity.properties.clientId
    containerAppImage: containerAppImage
    containerCpu: containerCpu
    containerMemory: containerMemory
    storageAccountName: storage.outputs.storageAccountName
    postgresFqdn: postgres.outputs.postgresFqdn
    postgresAdminLogin: postgresAdminLogin
    ducklakeCatalogUser: ducklakeCatalogUser
    postgresDatabaseName: postgres.outputs.postgresDatabaseName
    ducklakeDataPath: ducklakeDataPath
    acrLoginServer: acr.outputs.acrLoginServer
    ducklakeCatalogPasswordSecretUri: keyvault.outputs.ducklakeCatalogPasswordSecretUri
    postgresAdminPasswordSecretUri: keyvault.outputs.postgresPasswordSecretUri
    quackTokenSecretUri: keyvault.outputs.quackTokenSecretUri
  }
}

resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountName, containerAppIdentityName, 'StorageBlobDataContributor')
  scope: storageAccountExisting
  dependsOn: [
    storage
  ]
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: containerAppIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorStorageBlobDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(storageAccountName, operatorPrincipalId, 'StorageBlobDataReader')
  scope: storageAccountExisting
  dependsOn: [
    storage
  ]
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    )
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

output STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
output POSTGRES_SERVER_NAME string = postgres.outputs.postgresServerName
output POSTGRES_FQDN string = postgres.outputs.postgresFqdn
output POSTGRES_DATABASE_NAME string = postgres.outputs.postgresDatabaseName
output CONTAINER_APP_NAME string = containerApp.outputs.containerAppName
output CONTAINER_APP_FQDN string = containerApp.outputs.containerAppFqdn
output QUACK_URI string = 'quack:${containerApp.outputs.containerAppFqdn}:443'
output QUACK_HTTP_URL string = 'https://${containerApp.outputs.containerAppFqdn}'
output KEY_VAULT_NAME string = keyvault.outputs.keyVaultName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.acrLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.acrName
