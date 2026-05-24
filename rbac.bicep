// =============================================================================
// Azure VM Health Assistant — RBAC Template (Subscription Scope)
// Grants the Function App Managed Identity read access to monitor VMs
// Deploy separately: az deployment sub create ...
// =============================================================================

targetScope = 'subscription'

@description('Principal ID of the Function App Managed Identity (from main.bicep output)')
param functionAppPrincipalId string

@description('Subscription ID to grant monitoring access on')
param monitoredSubscriptionId string = subscription().subscriptionId

// ---------------------------------------------------------------------------
// Role: Monitoring Reader
// Allows reading all monitoring data — metrics, alerts, logs
// Built-in role ID: 43d0d8ad-25c7-4714-9337-8ba259a9fe05
// ---------------------------------------------------------------------------

resource monitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitoredSubscriptionId, functionAppPrincipalId, 'monitoring-reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Azure VM Health Assistant — read monitoring metrics'
  }
}

// ---------------------------------------------------------------------------
// Role: Reader
// Allows listing VMs and their properties via ARM
// Built-in role ID: acdd72a7-3385-48ef-bd42-f606fba81ae7
// ---------------------------------------------------------------------------

resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitoredSubscriptionId, functionAppPrincipalId, 'reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Azure VM Health Assistant — list VMs and resource properties'
  }
}

output monitoringReaderAssignmentId string = monitoringReaderRole.id
output readerAssignmentId string = readerRole.id
