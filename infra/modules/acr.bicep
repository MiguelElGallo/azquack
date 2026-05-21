param location string
param acrName string
param pullPrincipalIds array

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string = 'Basic'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acrPullAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in pullPrincipalIds: {
    name: guid(acr.id, principalId, 'AcrPull')
    scope: acr
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        '7f951dda-4ed3-4680-a7ca-43fe172d538d'
      )
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
