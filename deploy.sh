#!/usr/bin/env bash
# =============================================================================
# Azure VM Health Assistant — Full Deployment Script
# Run once to provision the entire infrastructure.
#
# PREREQUISITES
#   - Azure CLI >= 2.50  (az login completed before running)
#   - jq installed
#   - Bicep CLI (bundled with Azure CLI >= 2.20)
#   - Node.js >= 20
#   - zip utility
#
# USAGE
#   chmod +x deploy.sh
#   ./deploy.sh
#
# The script will prompt you for all required values interactively.
# Secrets are collected via silent prompts and never echoed to the terminal.
#
# SECURITY NOTE
#   Never hardcode secrets or IDs directly in this file.
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ---------------------------------------------------------------------------
# Interactive prompts — collect all inputs securely
# ---------------------------------------------------------------------------

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Azure VM Health Assistant — Deployment Setup            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  Secrets are entered silently and never stored in this script."
echo ""

# Non-secret config
read -rp "📌 Subscription ID: " SUBSCRIPTION_ID
read -rp "📌 Tenant ID: " TENANT_ID
read -rp "📌 Resource Group [rg-vmhealth-prod]: " RESOURCE_GROUP
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-vmhealth-prod}"
read -rp "📌 Location [eastasia]: " LOCATION
LOCATION="${LOCATION:-eastasia}"
read -rp "📌 Unique Suffix 3-6 chars [abc01]: " UNIQUE_SUFFIX
UNIQUE_SUFFIX="${UNIQUE_SUFFIX:-abc01}"
ENVIRONMENT="prod"

# Secrets — silent input
echo ""
read -rsp "🔐 Anthropic API Key (sk-ant-...): " ANTHROPIC_API_KEY
echo ""
read -rsp "🔐 SP Client Secret (leave blank if creating new SP): " SP_CLIENT_SECRET
echo ""

# ---------------------------------------------------------------------------
# Validate required inputs
# ---------------------------------------------------------------------------

: "${SUBSCRIPTION_ID:?❌ Subscription ID cannot be empty.}"
: "${TENANT_ID:?❌ Tenant ID cannot be empty.}"
: "${ANTHROPIC_API_KEY:?❌ Anthropic API Key cannot be empty.}"
: "${UNIQUE_SUFFIX:?❌ Unique Suffix cannot be empty.}"

# ---------------------------------------------------------------------------
# STEP 0 — Set active Azure subscription
# ---------------------------------------------------------------------------

echo ""
echo "🔐 Setting Azure subscription..."
az account set --subscription "$SUBSCRIPTION_ID"
echo "✅ Subscription set: $SUBSCRIPTION_ID"

# ---------------------------------------------------------------------------
# STEP 1 — Create Resource Group (idempotent)
# ---------------------------------------------------------------------------

echo ""
echo "📦 Creating Resource Group: $RESOURCE_GROUP in $LOCATION..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags application=AzureVMHealthAssistant environment="$ENVIRONMENT" managedBy=Bicep \
  --output none
echo "✅ Resource group ready"

# ---------------------------------------------------------------------------
# STEP 2 — Create / reuse App Registration (idempotent)
# ---------------------------------------------------------------------------

SP_NAME="sp-vmhealth-${ENVIRONMENT}-${UNIQUE_SUFFIX}"
echo ""
echo "🔑 Checking for existing service principal: $SP_NAME ..."

EXISTING_SP_ID=$(az ad sp list \
  --display-name "$SP_NAME" \
  --query "[0].appId" \
  -o tsv 2>/dev/null || echo "")

if [ -z "$EXISTING_SP_ID" ] || [ "$EXISTING_SP_ID" = "None" ]; then
  echo "   Not found — creating new service principal..."
  SP_OUTPUT=$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --role "Monitoring Reader" \
    --scopes "/subscriptions/$SUBSCRIPTION_ID" \
    --output json)

  SP_CLIENT_ID=$(echo "$SP_OUTPUT" | jq -r '.appId')

  # Use the auto-generated secret if SP_CLIENT_SECRET was not provided
  if [ -z "${SP_CLIENT_SECRET:-}" ]; then
    SP_CLIENT_SECRET=$(echo "$SP_OUTPUT" | jq -r '.password')
    echo "   ℹ️  SP secret auto-generated. Store it securely — it will not be shown again."
  fi

  echo "✅ Service Principal created: $SP_CLIENT_ID"
else
  SP_CLIENT_ID="$EXISTING_SP_ID"
  echo "   Reusing existing Service Principal: $SP_CLIENT_ID"

  : "${SP_CLIENT_SECRET:?
  ❌ Service Principal already exists but SP_CLIENT_SECRET is empty.
     Re-run the script and enter the existing secret when prompted.
     Or rotate it: az ad sp credential reset --id $SP_CLIENT_ID}"

  echo "✅ Reusing existing Service Principal"
fi

SP_OBJECT_ID=$(az ad sp show --id "$SP_CLIENT_ID" --query id -o tsv)
echo "   Client ID: $SP_CLIENT_ID"
echo "   Object ID: $SP_OBJECT_ID"

# ---------------------------------------------------------------------------
# STEP 3 — Get deploying user Object ID (for Key Vault admin during setup)
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
FUNCTION_APP_URL=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppUrl.value')
FUNCTION_APP_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppName.value')
STATIC_WEB_APP_URL=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.staticWebAppUrl.value')
STATIC_WEB_APP_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.staticWebAppName.value')
STATIC_WEB_APP_HOSTNAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.staticWebAppHostname.value')
KEY_VAULT_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.keyVaultName.value')
FUNCTION_APP_PRINCIPAL_ID=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppPrincipalId.value')

echo ""
echo "📋 Infrastructure Outputs:"
echo "   Function App URL:    $FUNCTION_APP_URL"
echo "   Static Web App URL:  $STATIC_WEB_APP_URL"
echo "   Key Vault:           $KEY_VAULT_NAME"

# ---------------------------------------------------------------------------
# STEP 5 — Update Function App CORS with actual SWA hostname
# ---------------------------------------------------------------------------

echo ""
echo "🌐 Updating Function App CORS with actual SWA hostname..."
az functionapp cors add \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --allowed-origins "https://${STATIC_WEB_APP_HOSTNAME}" \
  --output none

az functionapp cors remove \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --allowed-origins "*" \
  --output none 2>/dev/null || true

echo "✅ CORS updated — allowed origin: https://${STATIC_WEB_APP_HOSTNAME}"

# ---------------------------------------------------------------------------
# STEP 6 — Deploy RBAC at Subscription Scope
# ---------------------------------------------------------------------------

echo ""
echo "🔐 Assigning RBAC roles to Function App Managed Identity..."
az deployment sub create \
  --name "vmhealth-rbac-$(date +%Y%m%d%H%M%S)" \
  --location "$LOCATION" \
  --template-file "./rbac.bicep" \
  --parameters \
      functionAppPrincipalId="$FUNCTION_APP_PRINCIPAL_ID" \
      monitoredSubscriptionId="$SUBSCRIPTION_ID" \
  --output none
echo "✅ RBAC roles assigned (Monitoring Reader + Reader)"

# ---------------------------------------------------------------------------
# STEP 7 — Deploy Function App Code
# ---------------------------------------------------------------------------

echo ""
echo "📦 Packaging and deploying Function App code..."
cd ./api
npm install --production
zip -r ../api-deploy.zip . -x "*.test.js" -x "node_modules/.cache/*"
cd ..

az functionapp deployment source config-zip \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --src "./api-deploy.zip" \
  --output none

rm -f ./api-deploy.zip
echo "✅ Function App code deployed"

# ---------------------------------------------------------------------------
# STEP 8 — Retrieve Static Web App deployment token
# ---------------------------------------------------------------------------

echo ""
echo "🌐 Retrieving Static Web App deployment token..."
SWA_TOKEN=$(az staticwebapp secrets list \
  --name "$STATIC_WEB_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.apiKey" -o tsv)

echo "✅ SWA deployment token retrieved"

# ---------------------------------------------------------------------------
# STEP 9 — Summary
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
echo "⚠️  Add these secrets to your GitHub repository:"
echo "   AZURE_STATIC_WEB_APPS_API_TOKEN = $SWA_TOKEN"
echo "   REACT_APP_API_URL               = $FUNCTION_APP_URL/api"
echo ""
echo "📋 Next steps:"
echo "   1. Add the secrets above to your GitHub repo"
echo "   2. Push your React app — GitHub Actions will auto-deploy it"
echo "   3. Visit $STATIC_WEB_APP_URL to view the dashboard"
echo ""
echo "⏳ RBAC note: Role propagation can take 5-15 minutes."
echo "   If Function App shows Key Vault errors on first start, restart it:"
echo "   az functionapp restart --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
echo "============================================================"
