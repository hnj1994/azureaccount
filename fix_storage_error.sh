#!/bin/bash

# ============================================================================
# Azure Function App AzureWebJobsStorage Error Diagnostic Script
# ============================================================================
# This script helps diagnose and fix the "Error creating a Blob container 
# reference" error related to AzureWebJobsStorage connection string issues.
# 
# Usage: bash fix_storage_error.sh
# ============================================================================

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
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
# Input Collection
# ============================================================================

print_header "Azure Function App Storage Error Diagnostic Tool"

echo "Please provide the following information:"
echo ""

read -p "Function App Name (e.g., func-vmhealth-prod-abc01): " FUNCTION_APP
read -p "Resource Group Name: " RESOURCE_GROUP
read -p "Subscription ID (press Enter to use current): " SUBSCRIPTION_ID

if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
    if [ -z "$SUBSCRIPTION_ID" ]; then
        print_error "Could not determine subscription. Please set it: az account set --subscription <id>"
        exit 1
    fi
fi

# Extract storage account name from function app name
# Pattern: func-<appname>-<env>-<suffix>
STORAGE_ACCOUNT_BASE=$(echo "$FUNCTION_APP" | sed 's/func-//; s/-/ /g' | awk '{print $1}')
echo ""
print_info "Based on function app name, storage account likely starts with: st${STORAGE_ACCOUNT_BASE}"

read -p "Storage Account Name (or press Enter to auto-detect): " STORAGE_ACCOUNT

if [ -z "$STORAGE_ACCOUNT" ]; then
    # Try to auto-detect
    print_info "Attempting to auto-detect storage account..."
    STORAGE_ACCOUNTS=$(az storage account list --resource-group $RESOURCE_GROUP --query "[].name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$STORAGE_ACCOUNTS" ]; then
        print_error "Could not auto-detect storage account. Please provide the name manually."
        exit 1
    else
        STORAGE_ACCOUNT=$(echo "$STORAGE_ACCOUNTS" | head -1)
        print_success "Auto-detected storage account: $STORAGE_ACCOUNT"
    fi
fi

# ============================================================================
# Diagnostics Phase
# ============================================================================

print_header "Phase 1: Running Diagnostics"

ERRORS_FOUND=0
WARNINGS_FOUND=0

# 1. Check if function app exists
print_info "Checking if Function App exists..."
if az functionapp show --name $FUNCTION_APP --resource-group $RESOURCE_GROUP &>/dev/null; then
    print_success "Function App '$FUNCTION_APP' exists"
else
    print_error "Function App '$FUNCTION_APP' not found in resource group '$RESOURCE_GROUP'"
    ERRORS_FOUND=$((ERRORS_FOUND + 1))
fi

# 2. Check if storage account exists
print_info "Checking if Storage Account exists..."
if az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP &>/dev/null; then
    print_success "Storage Account '$STORAGE_ACCOUNT' exists"
    
    # Get storage account details
    STORAGE_STATUS=$(az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query "provisioningState" -o tsv)
    if [ "$STORAGE_STATUS" == "Succeeded" ]; then
        print_success "Storage Account is in 'Succeeded' state"
    else
        print_warning "Storage Account is in '$STORAGE_STATUS' state (expected: Succeeded)"
        WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    fi
else
    print_error "Storage Account '$STORAGE_ACCOUNT' not found"
    ERRORS_FOUND=$((ERRORS_FOUND + 1))
fi

# 3. Check AzureWebJobsStorage setting
print_info "Checking AzureWebJobsStorage setting..."
AZURE_WEB_JOBS=$(az functionapp config appsettings list --name $FUNCTION_APP --resource-group $RESOURCE_GROUP --query "[?name=='AzureWebJobsStorage'].value" -o tsv 2>/dev/null || echo "")

if [ -z "$AZURE_WEB_JOBS" ]; then
    print_warning "AzureWebJobsStorage setting is missing or empty"
    WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
else
    if [[ "$AZURE_WEB_JOBS" == *"AccountName"* ]]; then
        print_success "AzureWebJobsStorage setting exists"
        if [[ "$AZURE_WEB_JOBS" == *"$STORAGE_ACCOUNT"* ]]; then
            print_success "Setting references correct storage account: $STORAGE_ACCOUNT"
        else
            print_warning "Setting may reference wrong storage account (expected: $STORAGE_ACCOUNT)"
            WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
        fi
    else
        print_warning "AzureWebJobsStorage setting may be invalid format"
        WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    fi
fi

# 4. Check Function App Managed Identity
print_info "Checking Function App Managed Identity..."
PRINCIPAL_ID=$(az functionapp identity show --name $FUNCTION_APP --resource-group $RESOURCE_GROUP --query "principalId" -o tsv 2>/dev/null || echo "")

if [ -z "$PRINCIPAL_ID" ]; then
    print_error "Function App does not have SystemAssigned Managed Identity"
    ERRORS_FOUND=$((ERRORS_FOUND + 1))
else
    print_success "Function App has Managed Identity: $PRINCIPAL_ID"
fi

# 5. Check RBAC assignments
if [ ! -z "$PRINCIPAL_ID" ]; then
    print_info "Checking RBAC role assignments on storage account..."
    
    STORAGE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"
    
    ROLES=$(az role assignment list --scope "$STORAGE_ID" --query "[?principalId=='$PRINCIPAL_ID'].roleDefinitionName" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$ROLES" ]; then
        print_warning "No RBAC role assignments found for Function App on Storage Account"
        WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
    else
        print_success "RBAC roles assigned:"
        echo "$ROLES" | while read role; do
            print_success "  - $role"
        done
    fi
fi

# 6. Check storage account keys
print_info "Checking Storage Account Keys..."
KEYS=$(az storage account keys list --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query "length(keys)" -o tsv 2>/dev/null || echo "0")

if [ "$KEYS" -eq "2" ]; then
    print_success "Storage Account has 2 access keys available"
else
    print_warning "Expected 2 storage account keys, found: $KEYS"
    WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
print_header "Diagnostic Summary"
echo ""
echo "Errors found: $ERRORS_FOUND"
echo "Warnings found: $WARNINGS_FOUND"
echo ""

if [ $ERRORS_FOUND -eq 0 ] && [ $WARNINGS_FOUND -eq 0 ]; then
    print_success "All diagnostics passed! The configuration looks correct."
    echo ""
    echo "If you're still getting storage errors, it may be due to:"
    echo "  1. RBAC propagation delay (5-15 minutes)"
    echo "  2. Network connectivity issues"
    echo "  3. Function App code error"
    echo ""
    print_info "Recommendation: Wait 5-15 minutes, then restart the Function App"
    echo ""
elif [ $ERRORS_FOUND -eq 0 ]; then
    print_warning "Diagnostics found $WARNINGS_FOUND warning(s) but no critical errors."
    print_info "Minor fixes may be needed. Review warnings above."
    echo ""
else
    print_error "Diagnostics found $ERRORS_FOUND error(s) that need to be fixed."
    echo ""
fi

# ============================================================================
# Fix Options
# ============================================================================

echo ""
read -p "Would you like to attempt automatic repairs? (y/n): " AUTO_FIX

if [ "$AUTO_FIX" != "y" ] && [ "$AUTO_FIX" != "Y" ]; then
    print_info "Skipping automatic repairs. Please refer to DEPLOYMENT_ERROR_ANALYSIS.md for manual steps."
    exit 0
fi

print_header "Phase 2: Applying Fixes"

# Fix 1: Create/update connection string setting
print_info "Fixing AzureWebJobsStorage setting..."

STORAGE_KEY=$(az storage account keys list \
    --name $STORAGE_ACCOUNT \
    --resource-group $RESOURCE_GROUP \
    --query "[0].value" -o tsv 2>/dev/null || echo "")

if [ -z "$STORAGE_KEY" ]; then
    print_error "Could not retrieve storage account key"
    exit 1
fi

CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=$STORAGE_ACCOUNT;AccountKey=$STORAGE_KEY;EndpointSuffix=core.windows.net"

az functionapp config appsettings set \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --settings AzureWebJobsStorage="$CONNECTION_STRING" \
    --output none

print_success "Updated AzureWebJobsStorage setting"

# Fix 2: Ensure required app settings exist
print_info "Checking other required settings..."

REQUIRED_SETTINGS=("FUNCTIONS_EXTENSION_VERSION:~4" "FUNCTIONS_WORKER_RUNTIME:node" "WEBSITE_CONTENTSHARE:func-${FUNCTION_APP}")

for setting in "${REQUIRED_SETTINGS[@]}"; do
    NAME="${setting%%:*}"
    VALUE="${setting#*:}"
    
    CURRENT=$(az functionapp config appsettings list --name $FUNCTION_APP --resource-group $RESOURCE_GROUP --query "[?name=='$NAME'].value" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$CURRENT" ]; then
        print_info "Setting $NAME: $VALUE"
        az functionapp config appsettings set \
            --name $FUNCTION_APP \
            --resource-group $RESOURCE_GROUP \
            --settings "$NAME=$VALUE" \
            --output none
    fi
done

print_success "Verified required settings"

# Fix 3: Ensure RBAC is correct (if identity exists)
if [ ! -z "$PRINCIPAL_ID" ]; then
    print_info "Verifying RBAC role assignments..."
    
    STORAGE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"
    
    # Check if role already assigned
    EXISTING_ROLE=$(az role assignment list --scope "$STORAGE_ID" --query "[?principalId=='$PRINCIPAL_ID' && roleDefinitionName=='Storage Blob Data Owner'].id" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$EXISTING_ROLE" ]; then
        print_info "Assigning Storage Blob Data Owner role..."
        az role assignment create \
            --assignee-object-id "$PRINCIPAL_ID" \
            --role "Storage Blob Data Owner" \
            --scope "$STORAGE_ID" \
            --output none 2>/dev/null || print_warning "Could not create role assignment (may already exist)"
    else
        print_success "Storage Blob Data Owner role already assigned"
    fi
fi

# ============================================================================
# Final Steps
# ============================================================================

print_header "Phase 3: Completing Recovery"

print_info "Restarting Function App..."
az functionapp restart \
    --name $FUNCTION_APP \
    --resource-group $RESOURCE_GROUP \
    --output none

print_success "Function App restarted"

echo ""
print_info "Waiting 30 seconds for restart to complete..."
sleep 30

echo ""
print_header "Recovery Complete"

echo ""
echo "Next steps:"
echo "  1. Wait an additional 5-15 minutes for RBAC propagation (if newly assigned)"
echo "  2. Retry your deployment: func azure functionapp publish $FUNCTION_APP --build local"
echo "  3. Check logs if still having issues: az functionapp log tail --name $FUNCTION_APP --resource-group $RESOURCE_GROUP"
echo ""

read -p "Would you like to tail the logs now? (y/n): " TAIL_LOGS

if [ "$TAIL_LOGS" == "y" ] || [ "$TAIL_LOGS" == "Y" ]; then
    print_info "Showing last 50 log lines (press Ctrl+C to stop)..."
    az functionapp log tail \
        --name $FUNCTION_APP \
        --resource-group $RESOURCE_GROUP \
        --provider-filter "Platform" \
        --tail 50 || print_warning "Could not retrieve logs"
fi

print_success "Done!"
