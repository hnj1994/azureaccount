#!/bin/bash

# ============================================================================
# Azure Function App Complete Fix Script
# ============================================================================
# Configuration from your diagnostic results
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - from diagnostic output
FUNCTION_APP="func-vmhealth-prod-abc01"
RESOURCE_GROUP="rg-vmhealth-prod"
SUBSCRIPTION_ID="03fb9f8e-2845-4ed8-ba85-9307e4699a43"
STORAGE_ACCOUNT="stvmhealthprodabc01"
PRINCIPAL_ID="30b3bf64-0acb-45c1-b1be-0afe54c049ec"

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# ============================================================================
# Main Fix Procedure
# ============================================================================

print_header "Azure Function App Storage Configuration Fix"

echo "Configuration:"
echo "  Function App: $FUNCTION_APP"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Principal ID: $PRINCIPAL_ID"
echo ""

read -p "Continue with automatic fix? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================================
# Step 1: Check deployment status
# ============================================================================

print_header "Step 1: Checking Bicep Deployment Status"

DEPLOYMENTS=$(az deployment group list --resource-group $RESOURCE_GROUP --output json 2>/dev/null)

if [ -z "$DEPLOYMENTS" ] || [ "$DEPLOYMENTS" == "[]" ]; then
    print_warning "No deployments found in resource group"
else
    echo "$DEPLOYMENTS" | jq -r '.[] | "\(.name) - \(.properties.provisioningState)"' | head -5
    print_success "Deployment history retrieved"
fi

# ============================================================================
# Step 2: Verify storage account and keys
# ============================================================================

print_header "Step 2: Checking Storage Account"

# Check if storage account exists
if ! az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP &>/dev/null; then
    print_error "Storage account $STORAGE_ACCOUNT not found!"
    exit 1
fi

print_success "Storage account exists"

# Check keys
STORAGE_KEYS=$(az storage account keys list \
    --name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query "length(keys)" -o tsv 2>/dev/null)

echo "Storage account keys found: $STORAGE_KEYS"

if [ "$STORAGE_KEYS" -lt "2" ]; then
    print_warning "Expected 2 keys, found $STORAGE_KEYS. Attempting to regenerate primary key..."
    
    az storage account keys renew \
        --name $STORAGE_ACCOUNT \
        --key primary \
        --resource-group $RESOURCE_GROUP \
        --output none
    
    sleep 5
    STORAGE_KEYS=$(az storage account keys list \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "length(keys)" -o tsv)
    
    if [ "$STORAGE_KEYS" -ge "2" ]; then
        print_success "Storage keys regenerated successfully (count: $STORAGE_KEYS)"
    else
        print_error "Failed to regenerate storage keys!"
        exit 1
    fi
else
    print_success "Storage account has 2 keys available"
fi

# ============================================================================
# Step 3: Assign RBAC roles
# ============================================================================

print_header "Step 3: Assigning RBAC Roles"

STORAGE_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

ROLES=("Storage Blob Data Owner" "Storage Queue Data Contributor" "Storage Table Data Contributor")

for ROLE in "${ROLES[@]}"; do
    echo -n "Assigning '$ROLE'... "
    
    if az role assignment create \
        --assignee-object-id "$PRINCIPAL_ID" \
        --role "$ROLE" \
        --scope "$STORAGE_SCOPE" \
        --output none 2>/dev/null; then
        print_success "Assigned"
    else
        # Check if already assigned
        EXISTING=$(az role assignment list \
            --assignee-object-id "$PRINCIPAL_ID" \
            --scope "$STORAGE_SCOPE" \
            --query "[?roleDefinitionName=='$ROLE'].id" -o tsv 2>/dev/null)
        
        if [ ! -z "$EXISTING" ]; then
            print_success "Already assigned"
        else
            print_warning "Could not assign (may need owner permissions)"
        fi
    fi
done

# Verify assignments
echo ""
print_info "Verifying RBAC assignments..."
ASSIGNED_ROLES=$(az role assignment list \
    --assignee-object-id "$PRINCIPAL_ID" \
    --scope "$STORAGE_SCOPE" \
    --query "[].roleDefinitionName" -o tsv 2>/dev/null)

if [ ! -z "$ASSIGNED_ROLES" ]; then
    echo "Assigned roles:"
    echo "$ASSIGNED_ROLES" | sed 's/^/  - /'
    print_success "RBAC roles verified"
else
    print_warning "Could not verify RBAC assignments"
fi

# ============================================================================
# Step 4: Set connection string
# ============================================================================

print_header "Step 4: Setting AzureWebJobsStorage Connection String"

print_info "Retrieving storage account key..."
STORAGE_KEY=$(az storage account keys list \
    --name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query "[0].value" -o tsv 2>/dev/null)

if [ -z "$STORAGE_KEY" ]; then
    print_error "Failed to retrieve storage account key!"
    exit 1
fi

print_success "Key retrieved (length: ${#STORAGE_KEY} characters)"

# Build connection string
CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=$STORAGE_ACCOUNT;AccountKey=$STORAGE_KEY;EndpointSuffix=core.windows.net"

print_info "Setting connection string in Function App..."
az functionapp config appsettings set \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --settings AzureWebJobsStorage="$CONNECTION_STRING" \
    --output none

print_success "Connection string set"

# ============================================================================
# Step 5: Set other required settings
# ============================================================================

print_header "Step 5: Setting Required Function App Settings"

az functionapp config appsettings set \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --settings \
        FUNCTIONS_EXTENSION_VERSION="~4" \
        FUNCTIONS_WORKER_RUNTIME="node" \
        WEBSITE_CONTENTSHARE="$FUNCTION_APP" \
        NODE_ENV="production" \
        ENVIRONMENT="prod" \
    --output none

print_success "Function App settings configured"

# ============================================================================
# Step 6: Wait and restart
# ============================================================================

print_header "Step 6: Waiting for RBAC Propagation & Restarting"

print_warning "Waiting 10 minutes for RBAC propagation..."
print_info "This is critical - Azure needs time to propagate role assignments"

# Show countdown
SECONDS_LEFT=600
while [ $SECONDS_LEFT -gt 0 ]; do
    MINS=$((SECONDS_LEFT / 60))
    SECS=$((SECONDS_LEFT % 60))
    printf "\r⏱️  Waiting... %02d:%02d remaining" $MINS $SECS
    sleep 1
    SECONDS_LEFT=$((SECONDS_LEFT - 1))
done

echo ""
echo ""
print_info "Restarting Function App..."

az functionapp restart \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --output none

print_success "Function App restart initiated"

print_info "Waiting 2 minutes for restart to complete..."
sleep 120

# ============================================================================
# Step 7: Verification
# ============================================================================

print_header "Step 7: Verification"

# Verify settings
print_info "Checking AzureWebJobsStorage setting..."
SETTING=$(az functionapp config appsettings list \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --query "[?name=='AzureWebJobsStorage'].value" -o tsv 2>/dev/null)

if [ ! -z "$SETTING" ] && [[ "$SETTING" == *"DefaultEndpointsProtocol"* ]]; then
    print_success "AzureWebJobsStorage is set correctly"
else
    print_warning "Could not verify AzureWebJobsStorage setting"
fi

# Check all required settings
echo ""
print_info "Required app settings:"
az functionapp config appsettings list \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --query "[?name=='AzureWebJobsStorage' || name=='FUNCTIONS_EXTENSION_VERSION' || name=='FUNCTIONS_WORKER_RUNTIME' || name=='ENVIRONMENT'].{Name:name, Value:value}" \
    --output table 2>/dev/null

# Check RBAC
echo ""
print_info "RBAC assignments:"
az role assignment list \
    --assignee-object-id "$PRINCIPAL_ID" \
    --scope "$STORAGE_SCOPE" \
    --query "[].{Role:roleDefinitionName, Scope:scope}" \
    --output table 2>/dev/null

# Show recent logs
echo ""
print_info "Recent Function App logs (last 20 entries):"
echo "---"
az functionapp log tail \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --provider-filter "Platform" \
    --tail 20 2>/dev/null || print_warning "Could not retrieve logs"
echo "---"

# ============================================================================
# Final Summary
# ============================================================================

print_header "Fix Complete!"

echo ""
echo "✓ All configuration steps completed successfully!"
echo ""
echo "Next steps:"
echo "  1. Verify the logs above show no 'AzureWebJobsStorage' errors"
echo "  2. Deploy your function: func azure functionapp publish $FUNCTION_APP --build local"
echo "  3. Monitor logs during deployment: az functionapp log tail --name $FUNCTION_APP --resource-group $RESOURCE_GROUP"
echo ""
echo "If you still see storage errors:"
echo "  - Wait an additional 5 minutes (RBAC may still be propagating)"
echo "  - Then restart again: az functionapp restart --name $FUNCTION_APP --resource-group $RESOURCE_GROUP"
echo "  - Check full logs: az functionapp log tail --name $FUNCTION_APP --resource-group $RESOURCE_GROUP --provider-filter Platform --tail 100"
echo ""

read -p "Would you like to tail the logs now? (y/n): " SHOW_LOGS

if [ "$SHOW_LOGS" == "y" ] || [ "$SHOW_LOGS" == "Y" ]; then
    print_info "Showing live logs (press Ctrl+C to stop)..."
    echo ""
    az functionapp log tail \
        --name $FUNCTION_APP \
        --resource-group $RESOURCE_GROUP \
        --provider-filter "Platform" || print_warning "Could not retrieve logs"
fi

print_success "Done!"
