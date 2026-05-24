// =============================================================================
// Azure VM Health Assistant — Main Infrastructure Template
// Deploys: Key Vault, Function App, Static Web App, App Insights, RBAC
// =============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Unique suffix to make resource names globally unique (3-6 chars)')
@minLength(3)
@maxLength(6)
param uniqueSuffix string

@description('Azure AD Tenant ID for the service principal')
param tenantId string = tenant().tenantId

@description('Service principal Client ID (App Registration)')
param spClientId string

@description('Service principal Client Secret — stored securely in Key Vault')
@secure()
param spClientSecret string

@description('Azure Subscription ID to monitor')
param monitoredSubscriptionId string = subscription().subscriptionId

@description('Anthropic API key for Claude AI integration')
@secure()
param anthropicApiKey string

@description('Object ID of the deploying user/SP — for Key Vault access policy')
param deployerObjectId string

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var appName = 'vmhealth'
var prefix = '${appName}-${environment}-${uniqueSuffix}'
var tags = {
  application: 'AzureVMHealthAssistant'
  environment: environment
  managedBy: 'Bicep'
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace (backing store for App Insights)
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${prefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ---------------------------------------------------------------------------
// Application Insights
// ---------------------------------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-${prefix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    RetentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Key Vault — stores secrets securely
// ---------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: 'kv-${prefix}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Key Vault Secrets
resource secretSpClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sp-client-secret'
  properties: {
    value: spClientSecret
    attributes: { enabled: true }
  }
}

resource secretAnthropicKey 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'anthropic-api-key'
  properties: {
    value: anthropicApiKey
    attributes: { enabled: true }
  }
}

resource secretSpClientId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sp-client-id'
  properties: {
    value: spClientId
    attributes: { enabled: true }
  }
}

// RBAC: Deployer gets Key Vault Administrator during setup
resource kvAdminRoleDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerObjectId, 'kv-admin')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483') // Key Vault Administrator
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// Storage Account — required by Azure Functions
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${appName}${environment}${uniqueSuffix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    accessTier: 'Hot'
  }
}

// ---------------------------------------------------------------------------
// App Service Plan — Consumption (serverless) for Functions
// ---------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'asp-${prefix}'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux
  }
}

// ---------------------------------------------------------------------------
// Azure Function App — Backend API
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: 'func-${prefix}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned' // Managed Identity for Key Vault access
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      functionAppScaleLimit: 10
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: [
          'https://swa-${prefix}.azurestaticapps.net'
          'http://localhost:3000' // local dev
        ]
        supportCredentials: false
      }
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: 'func-${prefix}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AZURE_TENANT_ID'
          value: tenantId
        }
        {
          name: 'AZURE_SUBSCRIPTION_ID'
          value: monitoredSubscriptionId
        }
        // Secrets pulled from Key Vault via managed identity
        {
          name: 'AZURE_CLIENT_ID'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=sp-client-id)'
        }
        {
          name: 'AZURE_CLIENT_SECRET'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=sp-client-secret)'
        }
        {
          name: 'ANTHROPIC_API_KEY'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=anthropic-api-key)'
        }
        {
          name: 'ENVIRONMENT'
          value: environment
        }
        {
          name: 'NODE_ENV'
          value: environment == 'prod' ? 'production' : 'development'
        }
      ]
    }
  }
  dependsOn: [
    secretSpClientSecret
    secretAnthropicKey
    secretSpClientId
  ]
}

// RBAC: Function App Managed Identity → Key Vault Secrets User
resource kvSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, 'kv-secrets-user')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Static Web App — React Frontend
// ---------------------------------------------------------------------------

resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: 'swa-${prefix}'
  location: location  // Static Web Apps support limited regions — adjust if needed
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      appLocation: '/'           // React app root
      apiLocation: 'api'         // Azure Functions folder (optional linked)
      outputLocation: 'build'    // React build output
    }
  }
}

// ---------------------------------------------------------------------------
// Action Group — for alert notifications
// ---------------------------------------------------------------------------

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'VMHealth'
    enabled: true
    emailReceivers: [] // Add email addresses post-deploy via parameters if needed
    webhookReceivers: [
      {
        name: 'FunctionWebhook'
        serviceUri: 'https://func-${prefix}.azurewebsites.net/api/alert-webhook'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Azure Monitor Alert Rules (examples — scope to monitored subscription)
// ---------------------------------------------------------------------------

resource alertHighCpu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-high-cpu-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when any VM CPU exceeds 85% for 5 minutes'
    severity: 2
    enabled: true
    scopes: [
      '/subscriptions/${monitoredSubscriptionId}'
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

resource alertHighDisk 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-high-disk-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when VM OS disk queue length is critically high'
    severity: 2
    enabled: true
    scopes: [
      '/subscriptions/${monitoredSubscriptionId}'
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighDiskQueue'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'OS Disk Queue Depth'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: 50
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

resource alertVmUnavailable 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-vm-unavailable-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when a VM becomes unavailable'
    severity: 1 // Critical
    enabled: true
    scopes: [
      '/subscriptions/${monitoredSubscriptionId}'
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'VmAvailability'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'VmAvailabilityMetric'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
        webHookProperties: {}
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// RBAC — Service Principal gets Monitoring Reader on monitored subscription
// (Applied at subscription scope — see rbac.bicep)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionAppName string = functionApp.name
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output staticWebAppName string = staticWebApp.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalytics.id
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
