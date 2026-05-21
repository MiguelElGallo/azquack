@description('Short environment name used in resource names.')
param environmentName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Storage account SKU for DuckLake data files.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_RAGRS'
])
param storageSkuName string = 'Standard_LRS'

@description('Storage account SKU for the Azure Files share that stores the DuckDB catalog file.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
])
param catalogStorageSkuName string = 'Standard_LRS'

@description('Object ID of the human or service principal allowed to read the public Quack token for local smoke tests. Empty skips the assignment.')
param operatorPrincipalId string = ''

@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
@description('Principal type for operatorPrincipalId.')
param operatorPrincipalType string = 'User'

@description('Container image for both Azure Container Apps. AZD replaces this after building the local Dockerfile.')
param containerAppImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('CPU cores for the public query Container App.')
param queryContainerCpu string = '0.5'

@description('Memory for the public query Container App.')
param queryContainerMemory string = '1Gi'

@description('CPU cores for the internal catalog Container App.')
param catalogContainerCpu string = '0.5'

@description('Memory for the internal catalog Container App.')
param catalogContainerMemory string = '1Gi'

@description('DuckLake data path in Azure Blob Storage.')
param ducklakeDataPath string = 'az://lakehouse/data/'

@secure()
@minLength(32)
@description('Shared token required by local DuckDB clients connecting to the public query app through Quack.')
param quackToken string

@secure()
@minLength(32)
@description('Internal token used by the query app to connect to the private catalog app over Quack.')
param catalogQuackToken string

var uniqueSuffix = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var storageAccountName = 'st${uniqueSuffix}'
var catalogStorageAccountName = 'stcat${uniqueSuffix}'
var catalogFileShareName = 'catalog'
var containerAppsEnvironmentName = 'cae-${environmentName}'
var queryContainerAppName = 'ca-${environmentName}-query'
var catalogContainerAppName = 'ca-${environmentName}-catalog'
var queryContainerAppIdentityName = 'id-ca-${environmentName}-query'
var catalogContainerAppIdentityName = 'id-ca-${environmentName}-catalog'
var acrName = 'acr${uniqueSuffix}'
var keyVaultName = 'kv-${substring(uniqueSuffix, 0, 10)}'

resource queryContainerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: queryContainerAppIdentityName
  location: location
}

resource catalogContainerAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: catalogContainerAppIdentityName
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

module catalogStorage './modules/catalog-storage.bicep' = {
  name: 'catalogStorage'
  params: {
    location: location
    storageAccountName: catalogStorageAccountName
    storageSkuName: catalogStorageSkuName
    fileShareName: catalogFileShareName
  }
}

module keyvault './modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    queryContainerAppPrincipalId: queryContainerAppIdentity.properties.principalId
    catalogContainerAppPrincipalId: catalogContainerAppIdentity.properties.principalId
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
    quackToken: quackToken
    catalogQuackToken: catalogQuackToken
  }
}

module acr './modules/acr.bicep' = {
  name: 'acr'
  params: {
    location: location
    acrName: acrName
    pullPrincipalIds: [
      queryContainerAppIdentity.properties.principalId
      catalogContainerAppIdentity.properties.principalId
    ]
  }
}

module containerApps './modules/container-app.bicep' = {
  name: 'containerApps'
  dependsOn: [
    queryStorageBlobDataContributorAssignment
    operatorStorageBlobDataReaderAssignment
  ]
  params: {
    location: location
    containerAppsEnvironmentName: containerAppsEnvironmentName
    queryContainerAppName: queryContainerAppName
    catalogContainerAppName: catalogContainerAppName
    queryContainerAppIdentityId: queryContainerAppIdentity.id
    queryContainerAppIdentityClientId: queryContainerAppIdentity.properties.clientId
    catalogContainerAppIdentityId: catalogContainerAppIdentity.id
    catalogContainerAppIdentityClientId: catalogContainerAppIdentity.properties.clientId
    containerAppImage: containerAppImage
    queryContainerCpu: queryContainerCpu
    queryContainerMemory: queryContainerMemory
    catalogContainerCpu: catalogContainerCpu
    catalogContainerMemory: catalogContainerMemory
    storageAccountName: storage.outputs.storageAccountName
    catalogStorageAccountName: catalogStorage.outputs.storageAccountName
    catalogFileShareName: catalogStorage.outputs.fileShareName
    ducklakeDataPath: ducklakeDataPath
    acrLoginServer: acr.outputs.acrLoginServer
    quackTokenSecretUri: keyvault.outputs.quackTokenSecretUri
    catalogQuackTokenSecretUri: keyvault.outputs.catalogQuackTokenSecretUri
  }
}

resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource queryStorageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountName, queryContainerAppIdentityName, 'StorageBlobDataContributor')
  scope: storageAccountExisting
  dependsOn: [
    storage
  ]
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: queryContainerAppIdentity.properties.principalId
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
output CATALOG_STORAGE_ACCOUNT_NAME string = catalogStorage.outputs.storageAccountName
output CATALOG_FILE_SHARE_NAME string = catalogStorage.outputs.fileShareName
output QUERY_CONTAINER_APP_NAME string = containerApps.outputs.queryContainerAppName
output CATALOG_CONTAINER_APP_NAME string = containerApps.outputs.catalogContainerAppName
output CONTAINER_APP_NAME string = containerApps.outputs.queryContainerAppName
output QUERY_CONTAINER_APP_FQDN string = containerApps.outputs.queryContainerAppFqdn
output CATALOG_CONTAINER_APP_FQDN string = containerApps.outputs.catalogContainerAppFqdn
output QUACK_URI string = 'quack:${containerApps.outputs.queryContainerAppFqdn}:443'
output QUACK_HTTP_URL string = 'https://${containerApps.outputs.queryContainerAppFqdn}'
output KEY_VAULT_NAME string = keyvault.outputs.keyVaultName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.acrLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.acrName
