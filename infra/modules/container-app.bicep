param location string
param containerAppsEnvironmentName string
param containerAppName string
param containerAppIdentityId string
param containerAppIdentityClientId string
param containerAppImage string
param containerCpu string
param containerMemory string
param storageAccountName string
param postgresFqdn string
param postgresAdminLogin string
param ducklakeCatalogUser string
param postgresDatabaseName string
param ducklakeDataPath string
param acrLoginServer string
param ducklakeCatalogPasswordSecretUri string
param postgresAdminPasswordSecretUri string
param quackTokenSecretUri string

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${containerAppsEnvironmentName}'
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  properties: {
    peerAuthentication: {
      mtls: {
        enabled: true
      }
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: {
    'azd-service-name': 'quack'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerAppIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'postgres-admin-password'
          keyVaultUrl: postgresAdminPasswordSecretUri
          identity: containerAppIdentityId
        }
        {
          name: 'ducklake-catalog-password'
          keyVaultUrl: ducklakeCatalogPasswordSecretUri
          identity: containerAppIdentityId
        }
        {
          name: 'quack-token'
          keyVaultUrl: quackTokenSecretUri
          identity: containerAppIdentityId
        }
      ]
      registries: [
        {
          server: acrLoginServer
          identity: containerAppIdentityId
        }
      ]
      ingress: {
        external: true
        targetPort: 8081
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'quack'
          image: containerAppImage
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
          env: [
            {
              name: 'AZURE_CLIENT_ID'
              value: containerAppIdentityClientId
            }
            {
              name: 'AZURE_LOCATION'
              value: location
            }
            {
              name: 'AZQUACK_STORAGE_ACCOUNT'
              value: storageAccountName
            }
            {
              name: 'AZQUACK_PG_HOST'
              value: postgresFqdn
            }
            {
              name: 'AZQUACK_PG_DATABASE'
              value: postgresDatabaseName
            }
            {
              name: 'AZQUACK_PG_USER'
              value: ducklakeCatalogUser
            }
            {
              name: 'AZQUACK_DUCKLAKE_DATA_PATH'
              value: ducklakeDataPath
            }
            {
              name: 'AZQUACK_PG_ADMIN_USER'
              value: postgresAdminLogin
            }
            {
              name: 'AZQUACK_PG_ADMIN_PASSWORD'
              secretRef: 'postgres-admin-password'
            }
            {
              name: 'AZQUACK_PG_PASSWORD'
              secretRef: 'ducklake-catalog-password'
            }
            {
              name: 'AZQUACK_QUACK_TOKEN'
              secretRef: 'quack-token'
            }
          ]
          probes: [
            {
              type: 'liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              periodSeconds: 10
              initialDelaySeconds: 30
              failureThreshold: 3
            }
            {
              type: 'readiness'
              httpGet: {
                path: '/readyz'
                port: 8080
              }
              periodSeconds: 5
              initialDelaySeconds: 10
              failureThreshold: 6
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
