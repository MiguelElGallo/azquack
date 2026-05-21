param location string
param containerAppsEnvironmentName string
param queryContainerAppName string
param catalogContainerAppName string
param queryContainerAppIdentityId string
param queryContainerAppIdentityClientId string
param catalogContainerAppIdentityId string
param catalogContainerAppIdentityClientId string
param containerAppImage string
param queryContainerCpu string
param queryContainerMemory string
param queryMinReplicas string
param queryMaxReplicas string
param queryStickySessions string
param queryExposePlatformMetadata string
param catalogContainerCpu string
param catalogContainerMemory string
param storageAccountName string
param catalogStorageAccountName string
param catalogFileShareName string
param ducklakeDataPath string
param acrLoginServer string
param quackTokenSecretUri string
param catalogQuackTokenSecretUri string

var catalogStorageMountName = 'catalog'
var catalogDbPath = '/catalog/catalog.duckdb'

resource catalogStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: catalogStorageAccountName
}

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

resource catalogStorageMount 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: containerAppsEnvironment
  name: catalogStorageMountName
  properties: {
    azureFile: {
      accountName: catalogStorageAccountName
      accountKey: catalogStorageAccount.listKeys().keys[0].value
      shareName: catalogFileShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource catalogContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: catalogContainerAppName
  location: location
  tags: {
    'azd-service-name': 'catalog'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${catalogContainerAppIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'catalog-quack-token'
          keyVaultUrl: catalogQuackTokenSecretUri
          identity: catalogContainerAppIdentityId
        }
      ]
      registries: [
        {
          server: acrLoginServer
          identity: catalogContainerAppIdentityId
        }
      ]
      ingress: {
        external: false
        targetPort: 8081
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'catalog'
          image: containerAppImage
          resources: {
            cpu: json(catalogContainerCpu)
            memory: catalogContainerMemory
          }
          env: [
            {
              name: 'AZURE_LOCATION'
              value: location
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: catalogContainerAppIdentityClientId
            }
            {
              name: 'AZQUACK_ROLE'
              value: 'catalog'
            }
            {
              name: 'AZQUACK_NODE_NAME'
              value: 'azquack-catalog'
            }
            {
              name: 'AZQUACK_CATALOG_DB_PATH'
              value: catalogDbPath
            }
            {
              name: 'AZQUACK_QUACK_TOKEN'
              secretRef: 'catalog-quack-token'
            }
          ]
          volumeMounts: [
            {
              volumeName: catalogStorageMountName
              mountPath: '/catalog'
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
              failureThreshold: 12
            }
          ]
        }
      ]
      volumes: [
        {
          name: catalogStorageMountName
          storageType: 'AzureFile'
          storageName: catalogStorageMount.name
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource queryContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: queryContainerAppName
  location: location
  tags: {
    'azd-service-name': 'query'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${queryContainerAppIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      secrets: [
        {
          name: 'quack-token'
          keyVaultUrl: quackTokenSecretUri
          identity: queryContainerAppIdentityId
        }
        {
          name: 'catalog-quack-token'
          keyVaultUrl: catalogQuackTokenSecretUri
          identity: queryContainerAppIdentityId
        }
      ]
      registries: [
        {
          server: acrLoginServer
          identity: queryContainerAppIdentityId
        }
      ]
      ingress: {
        external: true
        targetPort: 8081
        transport: 'auto'
        allowInsecure: false
        stickySessions: {
          affinity: queryStickySessions
        }
      }
    }
    template: {
      containers: [
        {
          name: 'query'
          image: containerAppImage
          resources: {
            cpu: json(queryContainerCpu)
            memory: queryContainerMemory
          }
          env: [
            {
              name: 'AZURE_CLIENT_ID'
              value: queryContainerAppIdentityClientId
            }
            {
              name: 'AZURE_LOCATION'
              value: location
            }
            {
              name: 'AZQUACK_ROLE'
              value: 'query'
            }
            {
              name: 'AZQUACK_NODE_NAME'
              value: 'azquack-query'
            }
            {
              name: 'AZQUACK_EXPOSE_PLATFORM_METADATA'
              value: queryExposePlatformMetadata
            }
            {
              name: 'AZQUACK_STORAGE_ACCOUNT'
              value: storageAccountName
            }
            {
              name: 'AZQUACK_DUCKLAKE_DATA_PATH'
              value: ducklakeDataPath
            }
            {
              name: 'AZQUACK_CATALOG_QUACK_URI'
              value: 'quack:${catalogContainerApp.properties.configuration.ingress.fqdn}:443'
            }
            {
              name: 'AZQUACK_CATALOG_QUACK_TOKEN'
              secretRef: 'catalog-quack-token'
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
              failureThreshold: 18
            }
          ]
        }
      ]
      scale: {
        minReplicas: int(queryMinReplicas)
        maxReplicas: int(queryMaxReplicas)
      }
    }
  }
}

output queryContainerAppName string = queryContainerApp.name
output catalogContainerAppName string = catalogContainerApp.name
output queryContainerAppFqdn string = queryContainerApp.properties.configuration.ingress.fqdn
output catalogContainerAppFqdn string = catalogContainerApp.properties.configuration.ingress.fqdn
