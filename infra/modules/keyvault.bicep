param location string
param keyVaultName string
param containerAppPrincipalId string
param operatorPrincipalId string = ''
param operatorPrincipalType string = 'User'

@secure()
param postgresAdminPassword string

@secure()
param ducklakeCatalogPassword string

@secure()
param quackToken string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource catalogPasswordSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ducklakeCatalogPasswordSecret.id, containerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: ducklakeCatalogPasswordSecret
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource postgresAdminPasswordSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(postgresPasswordSecret.id, containerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: postgresPasswordSecret
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource quackTokenSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(quackTokenSecret.id, containerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: quackTokenSecret
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(keyVault.id, operatorPrincipalId, 'KeyVaultSecretsUser')
  scope: quackTokenSecret
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

resource postgresPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'postgres-admin-password'
  properties: {
    value: postgresAdminPassword
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

resource ducklakeCatalogPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ducklake-catalog-password'
  properties: {
    value: ducklakeCatalogPassword
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

resource quackTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'quack-token'
  properties: {
    value: quackToken
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

output keyVaultName string = keyVault.name

#disable-next-line outputs-should-not-contain-secrets
output postgresPasswordSecretUri string = postgresPasswordSecret.properties.secretUri

#disable-next-line outputs-should-not-contain-secrets
output ducklakeCatalogPasswordSecretUri string = ducklakeCatalogPasswordSecret.properties.secretUri

#disable-next-line outputs-should-not-contain-secrets
output quackTokenSecretUri string = quackTokenSecret.properties.secretUri
