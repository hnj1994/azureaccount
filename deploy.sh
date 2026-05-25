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
# REQUIRED ENVIRONMENT VARIABLES
#   Export these before running — do NOT hardcode secrets here.
#
#   SUBSCRIPTION_ID      Your Azure Subscription ID
#   TENANT_ID            Your Azure AD Tenant ID
#   ANTHROPIC_API_KEY    Your Anthropic API key (from console.anthropic.com)
#
# OPTIONAL ENVIRONMENT VARIABLES
#   RESOURCE_GROUP       Defaults to: rg-vmhealth-prod
#   LOCATION             Defaults to: eastasia
#   UNIQUE_SUFFIX        Defaults to: abc01  (3-6 lowercase alphanumeric)
#   ENVIRONMENT          Defaults to: prod
#   SP_CLIENT_SECRET     Only required if the service principal already exists.
#                        If creating a new SP, the secret is generated automatically.
#
# USAGE
#   export SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   chmod +x deploy.sh
#   ./deploy.sh
#
# SECURITY NOTE
#   Never hardcode secrets or subscription IDs directly in this file.
#   Use environment variables or a secrets manager (e.g. Azure Key Vault,
#   GitHub Actions secrets, or a local .env file excluded from git).
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ---------------------------------------------------------------------------
# CONFIGURATION — Static values (non-secret). Override via env vars if needed.
# ---------------------------------------------------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-vmhealth-prod}"
LOCATION="${LOCATION:-eastasia}"
UNIQUE_SUFFIX="${UNIQUE_SUFFIX:-abc01}"   # 3-6 lowercase alphanumeric
ENVIRONMENT="${ENVIRONMENT:-prod}"
echo "⚠️  SECURITY NOTICE: Never hardcode secrets in scripts!"
echo ""
echo "Enter your Azure configuration:"
echo ""

read -p "📌 Enter Subscription ID: " SUBSCRIPTION_ID
read -p "📌 Enter Tenant ID: " TENANT_ID
read -p "📌 Enter Resource Group name (default: rg-vmhealth-prod): " RESOURCE_GROUP
RESOURCE_GROUP=${RESOURCE_GROUP:-"rg-vmhealth-prod"}

read -p "📌 Enter Location (default: eastasia): " LOCATION
LOCATION=${LOCATION:-"eastasia"}

read -p "📌 Enter Unique Suffix 3-6 chars, lowercase alphanumeric (e.g., abc01): " UNIQUE_SUFFIX
ENVIRONMENT="prod"

# Secrets (will be stored in Key Vault — avoid hardcoding in production)
read -sp "🔐 Enter Service Principal Client Secret: " SP_CLIENT_SECRET
echo ""

read -sp "🔐 Enter Anthropic API Key: " ANTHROPIC_API_KEY
echo ""

# ---------------------------------------------------------------------------
# Validate required environment variables — fail fast with clear messages
# ---------------------------------------------------------------------------

: "${SUBSCRIPTION_ID:?
  ❌ SUBSCRIPTION_ID is not set.
     Run: export SUBSCRIPTION_ID=\"<your-azure-subscription-id>\"}"

: "${TENANT_ID:?
  ❌ TENANT_ID is not set.
     Run: export TENANT_ID=\"<your-azure-tenant-id>\"}"

: "${ANTHROPIC_API_KEY:?
  ❌ ANTHROPIC_API_KEY is not set.
     Run: export ANTHROPIC_API_KEY=\"sk-ant-...\"
     Get your key from: https://console.anthropic.com}"

# ---------------------------------------------------------------------------
# STEP 0 — Set active Azure subscription
# ---------------------------------------------------------------------------

echo ""
echo "🔐 Setting Azure subscription..."
echo ""
echo "🔐 Logging in to Azure..."
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
#
# FIX: Was creating a new SP on every run, accumulating orphaned principals.
#      Now checks if one already exists before creating.
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

  # Use the auto-generated secret if SP_CLIENT_SECRET wasn't pre-set
  if [ -z "${SP_CLIENT_SECRET:-}" ]; then
    SP_CLIENT_SECRET=$(echo "$SP_OUTPUT" | jq -r '.password')
    echo "   ℹ️  SP secret was auto-generated. Store it securely."
    echo "      Secret will not be displayed again."
  fi

  echo "✅ Service Principal created: $SP_CLIENT_ID"
else
  SP_CLIENT_ID="$EXISTING_SP_ID"
  echo "   Reusing existing Service Principal: $SP_CLIENT_ID"

  # Existing SP — secret must be provided externally
  : "${SP_CLIENT_SECRET:?
  ❌ Service Principal already exists but SP_CLIENT_SECRET is not set.
     Export the client secret: export SP_CLIENT_SECRET=\"<secret>\"
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
#
# FIX: The SWA hostname is auto-generated by Azure and cannot be predicted
#      at Bicep deploy time. We update CORS here after the SWA is created.
# ---------------------------------------------------------------------------

echo ""
echo "🌐 Updating Function App CORS with actual SWA hostname..."
az functionapp cors add \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --allowed-origins "https://${STATIC_WEB_APP_HOSTNAME}" \
  --output none

# Remove the wildcard '*' origin that was set during initial deploy
az functionapp cors remove \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --allowed-origins "*" \
  --output none 2>/dev/null || true

echo "✅ CORS updated — allowed origin: https://${STATIC_WEB_APP_HOSTNAME}"

# ---------------------------------------------------------------------------
# STEP 6 — Deploy RBAC at Subscription Scope (Monitoring Reader + Reader)
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
echo "   Secret name:  AZURE_STATIC_WEB_APPS_API_TOKEN"
echo "   Secret value: $SWA_TOKEN"
echo ""
echo "   Secret name:  REACT_APP_API_URL"
echo "   Secret value: $FUNCTION_APP_URL/api"
echo ""
echo "📋 Next steps:"
echo "   1. Add the secrets above to your GitHub repo"
echo "   2. Push your React app — GitHub Actions will auto-deploy it"
echo "   3. Visit $STATIC_WEB_APP_URL to view the dashboard"
echo ""
echo "⏳ RBAC note: Role propagation can take 5-15 minutes after deployment."
echo "   If the Function App shows Key Vault errors on first cold start, wait"
echo "   a few minutes then restart:"
echo "   az functionapp restart --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
echo "============================================================"
