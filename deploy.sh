#!/bin/bash
# =============================================================================
# Azure VM Health Assistant — Full Deployment Script
# Run this once to deploy the entire infrastructure
# Prerequisites: Azure CLI installed, logged in (az login)
# =============================================================================

set -e  # Exit on any error

# ---------------------------------------------------------------------------
# CONFIGURATION — Edit these values before running
# ---------------------------------------------------------------------------

SUBSCRIPTION_ID="03fb9f8e-2845-4ed8-ba85-9307e4699a43"
RESOURCE_GROUP="rg-vmhealth-prod"
LOCATION="eastus"
UNIQUE_SUFFIX="abc01"          # 3-6 chars, lowercase alphanumeric
ENVIRONMENT="prod"

# Your Azure AD details
TENANT_ID="7bc034e8-6823-4a80-b537-0256adba45e7"

# Secrets (will be stored in Key Vault — avoid hardcoding in production)
SP_CLIENT_SECRET="CSC8Q~oCKqXcS83M7KiKpGAaL8ZaU09v298Jba.X"
ANTHROPIC_API_KEY="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"

# ---------------------------------------------------------------------------
# STEP 0 — Login and set subscription
# ---------------------------------------------------------------------------

echo "🔐 Logging in to Azure..."
az account set --subscription "$SUBSCRIPTION_ID"
echo "✅ Subscription set: $SUBSCRIPTION_ID"

# ---------------------------------------------------------------------------
# STEP 1 — Create Resource Group
# ---------------------------------------------------------------------------

echo ""
echo "📦 Creating Resource Group: $RESOURCE_GROUP in $LOCATION..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags application=AzureVMHealthAssistant environment=$ENVIRONMENT managedBy=Bicep

echo "✅ Resource group created"

# ---------------------------------------------------------------------------
# STEP 2 — Create App Registration (Service Principal)
# ---------------------------------------------------------------------------

echo ""
echo "🔑 Creating App Registration for VM monitoring..."
SP_OUTPUT=$(az ad sp create-for-rbac \
  --name "sp-vmhealth-$ENVIRONMENT-$UNIQUE_SUFFIX" \
  --role "Monitoring Reader" \
  --scopes "/subscriptions/$SUBSCRIPTION_ID" \
  --output json)

SP_CLIENT_ID=$(echo $SP_OUTPUT | jq -r '.appId')
SP_OBJECT_ID=$(az ad sp show --id "$SP_CLIENT_ID" --query id -o tsv)

echo "✅ Service Principal created"
echo "   Client ID: $SP_CLIENT_ID"
echo "   Object ID: $SP_OBJECT_ID"

# ---------------------------------------------------------------------------
# STEP 3 — Get the deploying user's Object ID (for Key Vault access)
# ---------------------------------------------------------------------------

echo ""
echo "👤 Getting deploying user identity..."
DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
echo "✅ Deployer Object ID: $DEPLOYER_OBJECT_ID"

# ---------------------------------------------------------------------------
# STEP 4 — Deploy Main Infrastructure (Bicep)
# ---------------------------------------------------------------------------

echo ""
echo "🚀 Deploying main infrastructure (this takes ~3-5 minutes)..."
DEPLOY_OUTPUT=$(az deployment group create \
  --name "vmhealth-main-$(date +%Y%m%d%H%M%S)" \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "./main.bicep" \
  --parameters \
      environment="$ENVIRONMENT" \
      location="$LOCATION" \
      uniqueSuffix="$UNIQUE_SUFFIX" \
      tenantId="$TENANT_ID" \
      spClientId="$SP_CLIENT_ID" \
      spClientSecret="$SP_CLIENT_SECRET" \
      anthropicApiKey="$ANTHROPIC_API_KEY" \
      monitoredSubscriptionId="$SUBSCRIPTION_ID" \
      deployerObjectId="$DEPLOYER_OBJECT_ID" \
  --output json)

echo "✅ Main infrastructure deployed"

# Extract outputs
FUNCTION_APP_URL=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.functionAppUrl.value')
FUNCTION_APP_NAME=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.functionAppName.value')
STATIC_WEB_APP_URL=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.staticWebAppUrl.value')
STATIC_WEB_APP_NAME=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.staticWebAppName.value')
KEY_VAULT_NAME=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.keyVaultName.value')
FUNCTION_APP_PRINCIPAL_ID=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.functionAppPrincipalId.value')
APP_INSIGHTS_CONNECTION=$(echo $DEPLOY_OUTPUT | jq -r '.properties.outputs.appInsightsConnectionString.value')

echo ""
echo "📋 Infrastructure Outputs:"
echo "   Function App URL:    $FUNCTION_APP_URL"
echo "   Static Web App URL:  $STATIC_WEB_APP_URL"
echo "   Key Vault:           $KEY_VAULT_NAME"

# ---------------------------------------------------------------------------
# STEP 5 — Deploy RBAC at Subscription Scope
# ---------------------------------------------------------------------------

echo ""
echo "🔐 Assigning RBAC roles to Function App Managed Identity..."
az deployment sub create \
  --name "vmhealth-rbac-$(date +%Y%m%d%H%M%S)" \
  --location "$LOCATION" \
  --template-file "./rbac.bicep" \
  --parameters \
      functionAppPrincipalId="$FUNCTION_APP_PRINCIPAL_ID" \
      monitoredSubscriptionId="$SUBSCRIPTION_ID"

echo "✅ RBAC roles assigned (Monitoring Reader + Reader)"

# ---------------------------------------------------------------------------
# STEP 6 — Deploy Function App Code
# ---------------------------------------------------------------------------

echo ""
echo "📦 Packaging and deploying Function App code..."

# Navigate to api folder, install deps, zip deploy
cd ./api
npm install --production
zip -r ../api-deploy.zip . -x "*.test.js" -x "node_modules/.cache/*"
cd ..

az functionapp deployment source config-zip \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src "./api-deploy.zip"

rm -f ./api-deploy.zip
echo "✅ Function App code deployed"

# ---------------------------------------------------------------------------
# STEP 7 — Get Static Web App Deployment Token & Configure
# ---------------------------------------------------------------------------

echo ""
echo "🌐 Configuring Static Web App..."
SWA_TOKEN=$(az staticwebapp secrets list \
  --name "$STATIC_WEB_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.apiKey" -o tsv)

echo "✅ Static Web App deployment token retrieved"
echo ""
echo "⚠️  Add this secret to your GitHub repository:"
echo "   Secret name:  AZURE_STATIC_WEB_APPS_API_TOKEN"
echo "   Secret value: $SWA_TOKEN"

# ---------------------------------------------------------------------------
# STEP 8 — Output summary
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "✅  DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "🌍 Frontend URL:    $STATIC_WEB_APP_URL"
echo "⚡  API Base URL:   $FUNCTION_APP_URL/api"
echo "🔑  Key Vault:      https://portal.azure.com/#resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"
echo ""
echo "📋 Next steps:"
echo "   1. Add AZURE_STATIC_WEB_APPS_API_TOKEN to your GitHub repo secrets"
echo "   2. Push your React app — GitHub Actions will auto-deploy it"
echo "   3. Set REACT_APP_API_URL=$FUNCTION_APP_URL/api in your React env"
echo "   4. Visit $STATIC_WEB_APP_URL to view the dashboard"
echo ""
echo "📊 Monitor your deployment:"
echo "   az monitor metrics list --resource $FUNCTION_APP_NAME ..."
echo "============================================================"
