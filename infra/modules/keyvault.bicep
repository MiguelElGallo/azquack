param location string
param keyVaultName string
param queryContainerAppPrincipalId string
param catalogContainerAppPrincipalId string
param operatorPrincipalId string = ''
param operatorPrincipalType string = 'User'

@secure()
param quackToken string

@secure()
param catalogQuackToken string

var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

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

resource catalogQuackTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'catalog-quack-token'
  properties: {
    value: catalogQuackToken
    contentType: 'text/plain'
    attributes: {
      enabled: true
    }
  }
}

resource queryPublicTokenSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(quackTokenSecret.id, queryContainerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: quackTokenSecret
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: queryContainerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource queryCatalogTokenSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(catalogQuackTokenSecret.id, queryContainerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: catalogQuackTokenSecret
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: queryContainerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource catalogTokenSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(catalogQuackTokenSecret.id, catalogContainerAppPrincipalId, 'KeyVaultSecretsUser')
  scope: catalogQuackTokenSecret
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: catalogContainerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource operatorQuackTokenSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorPrincipalId)) {
  name: guid(quackTokenSecret.id, operatorPrincipalId, 'KeyVaultSecretsUser')
  scope: quackTokenSecret
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: operatorPrincipalId
    principalType: operatorPrincipalType
  }
}

output keyVaultName string = keyVault.name

#disable-next-line outputs-should-not-contain-secrets
output quackTokenSecretUri string = quackTokenSecret.properties.secretUri

#disable-next-line outputs-should-not-contain-secrets
output catalogQuackTokenSecretUri string = catalogQuackTokenSecret.properties.secretUri
