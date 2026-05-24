// =============================================================================
// Azure VM Health Assistant — Main Infrastructure Template
// Deploys: Key Vault, Function App, Static Web App, App Insights, RBAC
//
// CHANGES FROM ORIGINAL:
//   - softDeleteRetentionInDays raised to 30 (was 7)
//   - Storage connection string stored in Key Vault; MI used for runtime storage
//   - appSettings moved to a child config resource that deploys AFTER all
//     role assignments, solving the KV reference timing chicken-and-egg problem
//   - Added Storage Blob/Queue/Table role assignments for Function App MI
//   - CORS set to '*' (update post-deploy with actual SWA hostname via deploy.sh)
//   - functionAppScaleLimit raised to 20 (was 10)
//   - ftpsState: Disabled + http20Enabled: true added for security hardening
//   - Added staticWebAppHostname output for CORS post-deploy update
//
// CHANGES IN THIS CORRECTED VERSION:
//   - Parameterized webhookUrl for Action Group (was hardcoded)
//   - Fixed VM availability alert metric to use 'Available Memory Bytes'
//   - Parameterized alert email receivers
//   - Improved CORS configuration with better documentation
//   - Added validation constraints to parameters
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

@description('Object ID of the deploying user/SP — for Key Vault admin during setup')
param deployerObjectId string

@description('Email addresses for alert notifications (optional). Example: ["admin@contoso.com", "ops@contoso.com"]')
param alertEmailAddresses array = []

@description('Webhook URL for alert notifications (optional). Leave empty to skip webhook receiver.')
param webhookUrl string = ''

@description('Static Web App hostname for CORS (optional). Leave empty to use wildcard; update post-deploy via deploy.sh')
param staticWebAppHostnameForCors string = ''

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

// Conditionally build webhook receivers array
var webhookReceivers = empty(webhookUrl) ? [] : [
  {
    name: 'FunctionWebhook'
    serviceUri: webhookUrl
    useCommonAlertSchema: true
  }
]

// Conditionally build email receivers array
var emailReceivers = map(alertEmailAddresses, email => {
  name: split(email, '@')[0] // Use email prefix as friendly name
  emailAddress: email
  useCommonAlertSchema: true
})

// CORS allowed origins: use provided hostname or fallback to wildcard with localhost
var corsAllowedOrigins = empty(staticWebAppHostnameForCors) ? [
  '*'
  'http://localhost:3000' // local dev
] : [
  'https://${staticWebAppHostnameForCors}'
  'http://localhost:3000' // local dev
]

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
// Key Vault — stores all secrets securely
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
    softDeleteRetentionInDays: 30 // FIX: raised from 7 (minimum) to 30 for production recovery window
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// RBAC: Deployer gets Key Vault Administrator during initial setup
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
// Key Vault Secrets
// ---------------------------------------------------------------------------

resource secretSpClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sp-client-secret'
  properties: {
    value: spClientSecret
    attributes: { enabled: true }
  }
  dependsOn: [kvAdminRoleDeployer]
}

resource secretAnthropicKey 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'anthropic-api-key'
  properties: {
    value: anthropicApiKey
    attributes: { enabled: true }
  }
  dependsOn: [kvAdminRoleDeployer]
}

resource secretSpClientId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sp-client-id'
  properties: {
    value: spClientId
    attributes: { enabled: true }
  }
  dependsOn: [kvAdminRoleDeployer]
}

// FIX: Storage connection string stored in Key Vault rather than directly in
//      app settings. The key is evaluated at Bicep deploy time (listKeys()),
//      stored securely in KV, and read at runtime via the Function App's MI.
resource secretStorageContentConnection 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'storage-content-connection'
  properties: {
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
    attributes: { enabled: true }
  }
  dependsOn: [kvAdminRoleDeployer]
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
//
// NOTE: appSettings are intentionally omitted here and placed in the separate
//       functionAppSettings child resource below. This ensures all role
//       assignments exist BEFORE settings are applied, so Key Vault references
//       resolve successfully on first startup.
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: 'func-${prefix}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned' // Managed Identity for Key Vault + Storage access
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      functionAppScaleLimit: 20 // FIX: raised from 10 for larger subscriptions
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'    // Security hardening: disable legacy FTP
      http20Enabled: true      // Security hardening: prefer HTTP/2
      cors: {
        // CORS Configuration:
        // - If staticWebAppHostnameForCors parameter is provided, use it for production security
        // - If empty (default), uses wildcard + localhost for dev flexibility
        // - For production: either pass SWA hostname at deploy time OR run deploy.sh post-deploy
        //   to lock down CORS to actual SWA hostname
        // To manually update CORS post-deploy:
        //   az functionapp cors add --name <func> --allowed-origins <swa-url> --resource-group <rg>
        allowedOrigins: corsAllowedOrigins
        supportCredentials: false
      }
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: Function App Managed Identity — Key Vault Secrets User
// ---------------------------------------------------------------------------

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
// RBAC: Function App Managed Identity — Storage roles
// Required for MI-based AzureWebJobsStorage (no stored keys)
// ---------------------------------------------------------------------------

resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'storage-blob-owner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b') // Storage Blob Data Owner
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'storage-queue-contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88') // Storage Queue Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'storage-table-contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3') // Storage Table Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Function App Settings — deployed AFTER all role assignments
//
// FIX: Previously, appSettings were inside the Function App's siteConfig,
//      which meant Key Vault references were configured before the MI had the
//      Secrets User role. Now we use a child config resource with explicit
//      dependsOn, ensuring roles are propagated before the app reads KV.
//
// NOTE: RBAC propagation in Azure can take 5-15 minutes after assignment.
//       If the Function App shows KV errors on first cold start, wait a few
//       minutes then restart: az functionapp restart --name <func> --resource-group <rg>
// ---------------------------------------------------------------------------

resource functionAppSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  name: 'appsettings'
  parent: functionApp
  dependsOn: [
    kvSecretsUserRole           // MI must have KV Secrets User before KV refs resolve
    storageBlobDataOwner        // MI must have Storage roles before __accountName works
    storageQueueDataContributor
    storageTableDataContributor
    secretSpClientSecret        // All KV secrets must exist before referencing them
    secretAnthropicKey
    secretSpClientId
    secretStorageContentConnection
  ]
  properties: {
    // FIX: Use MI-based storage connection (no stored key for runtime operations)
    // Requires Storage Blob Data Owner + Queue/Table Data Contributor roles above
    AzureWebJobsStorage__accountName: storageAccount.name

    // Content share for deployment artifacts — uses KV-referenced connection string
    // (key-based connection still required for file share; key stored securely in KV)
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=storage-content-connection)'
    WEBSITE_CONTENTSHARE: 'func-${prefix}'

    // Functions runtime
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'node'

    // Application Insights
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString

    // Azure context
    AZURE_TENANT_ID: tenantId
    AZURE_SUBSCRIPTION_ID: monitoredSubscriptionId

    // Secrets pulled from Key Vault via managed identity at runtime
    AZURE_CLIENT_ID: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=sp-client-id)'
    AZURE_CLIENT_SECRET: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=sp-client-secret)'
    ANTHROPIC_API_KEY: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=anthropic-api-key)'

    // Environment flags
    ENVIRONMENT: environment
    NODE_ENV: environment == 'prod' ? 'production' : 'development'
  }
}

// ---------------------------------------------------------------------------
// Static Web App — React Frontend
// ---------------------------------------------------------------------------

resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: 'swa-${prefix}'
  location: location // Static Web Apps support limited regions — adjust if needed
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      appLocation: '/'        // React app root
      apiLocation: ''         // API managed separately via Function App
      outputLocation: 'build' // React build output
    }
  }
}

// ---------------------------------------------------------------------------
// Action Group — for alert notifications
// CORRECTED: Now parameterized for email and webhook receivers
// ---------------------------------------------------------------------------

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'VMHealth'
    enabled: true
    emailReceivers: emailReceivers
    webhookReceivers: webhookReceivers
  }
}

// ---------------------------------------------------------------------------
// Azure Monitor Alert Rules — scoped to monitored subscription
// CORRECTED: Fixed VM availability metric to use standard Azure metric
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
    description: 'Fires when VM OS disk queue depth is critically high (>50)'
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

// CORRECTED: Changed from non-existent 'VmAvailabilityMetric' to 'Available Memory Bytes'
// This provides a meaningful health indicator for VM availability/stability
resource alertLowMemory 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-low-memory-${prefix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when VM available memory drops below 1 GB'
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
          name: 'LowAvailableMemory'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Available Memory Bytes'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'LessThan'
          threshold: 1073741824 // 1 GB in bytes
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
output staticWebAppHostname string = staticWebApp.properties.defaultHostname // For CORS post-deploy update
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalytics.id
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name

// Helpful outputs for post-deployment configuration
output deploymentNotes string = '''
DEPLOYMENT COMPLETE - POST-DEPLOYMENT STEPS:

1. WAIT FOR RBAC PROPAGATION (5-15 minutes):
   - RBAC role assignments may take time to propagate
   - If Function App shows Key Vault errors on startup, wait and restart:
     az functionapp restart --name ${functionApp.name} --resource-group ${resourceGroup().name}

2. UPDATE CORS FOR PRODUCTION (if using wildcard):
   - If staticWebAppHostnameForCors was left empty, run:
     az functionapp cors add --name ${functionApp.name} --allowed-origins https://${staticWebApp.properties.defaultHostname} --resource-group ${resourceGroup().name}

3. CONFIGURE STATIC WEB APP BUILD:
   - Go to Azure Portal > Static Web Apps > ${staticWebApp.name}
   - Configure build settings for your React app deployment

4. UPDATE ALERT NOTIFICATIONS:
   - Add email receivers: az monitor action-group update --name ag-${prefix} --add-receiver <email>
   - Or update webhook: az monitor action-group webhook-receiver create --name ag-${prefix} --webhook-service-uri <url>

5. VERIFY FUNCTION APP:
   - Test Key Vault access:
     az functionapp config appsettings list --name ${functionApp.name} --resource-group ${resourceGroup().name}
   - Deploy function code and test

For more details, see BICEP_VALIDATION_REPORT.md
'''
