# Azure VM Health Assistant — Infrastructure

Complete Bicep/ARM deployment for the Azure VM Health AI Assistant.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Azure Subscription                        │
│                                                             │
│  ┌──────────────────┐    ┌──────────────────────────────┐  │
│  │  Static Web App  │───▶│      Function App (API)      │  │
│  │  (React UI)      │    │  GET /api/vms                │  │
│  └──────────────────┘    │  GET /api/vms/{id}/metrics   │  │
│                          └────────────┬─────────────────┘  │
│                                       │ Managed Identity    │
│  ┌──────────────────┐    ┌────────────▼─────────────────┐  │
│  │    Key Vault     │◀───│       Azure Monitor API      │  │
│  │  (secrets store) │    │  + ARM API (list VMs)        │  │
│  └──────────────────┘    └──────────────────────────────┘  │
│                                                             │
│  ┌──────────────────┐    ┌──────────────────────────────┐  │
│  │  App Insights    │    │    Log Analytics Workspace   │  │
│  │  (monitoring)    │───▶│    (logs + metrics store)   │  │
│  └──────────────────┘    └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `main.bicep` | Core infrastructure (Function App, Static Web App, Key Vault, App Insights) |
| `rbac.bicep` | Subscription-scoped RBAC roles for Managed Identity |
| `main.prod.parameters.json` | Production parameter values |
| `deploy.sh` | One-shot deployment script |
| `api/getVMs/index.js` | Function App backend — fetches real VM metrics |
| `api/host.json` | Function App runtime config |
| `.github/workflows/deploy.yml` | GitHub Actions CI/CD pipeline |

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) ≥ 2.50
- Azure subscription with Owner or Contributor role
- [Bicep CLI](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) (or use Azure CLI ≥ 2.20 which includes it)
- Node.js ≥ 20 (for local development)
- Anthropic API key from [console.anthropic.com](https://console.anthropic.com)

## Quick Deploy

### 1. Clone and configure

```bash
git clone <your-repo>
cd azure-vm-health-infra

# Edit deploy.sh and fill in your values:
#   SUBSCRIPTION_ID, TENANT_ID, SP_CLIENT_SECRET, ANTHROPIC_API_KEY
nano deploy.sh
```

### 2. Login to Azure

```bash
az login
az account set --subscription "<YOUR-SUBSCRIPTION-ID>"
```

### 3. Run deployment

```bash
chmod +x deploy.sh
./deploy.sh
```

That's it. The script will:
1. Create the resource group
2. Register an App Service Principal
3. Deploy all Bicep infrastructure
4. Assign RBAC roles
5. Deploy the Function App code
6. Output your URLs and next steps

### 4. Connect your React app

Update your React app's environment:
```bash
# .env.production
REACT_APP_API_URL=https://func-vmhealth-prod-abc01.azurewebsites.net/api
```

Then in the React app, replace the hardcoded `vmProfiles` with:
```javascript
useEffect(() => {
  fetch(`${process.env.REACT_APP_API_URL}/vms`)
    .then(r => r.json())
    .then(data => setVmProfiles(data.vms));
}, []);
```

### 5. Set up GitHub CI/CD

Add these secrets to your GitHub repository:
```
AZURE_CREDENTIALS              # az ad sp create-for-rbac output (JSON)
AZURE_STATIC_WEB_APPS_API_TOKEN  # from deploy.sh output
REACT_APP_API_URL              # your Function App URL
```

Push to `main` — GitHub Actions deploys automatically.

## Manual Bicep Deploy (without the script)

```bash
# 1. Create resource group
az group create --name rg-vmhealth-prod --location eastus

# 2. Deploy main infrastructure
az deployment group create \
  --resource-group rg-vmhealth-prod \
  --template-file main.bicep \
  --parameters main.prod.parameters.json \
               spClientSecret="<secret>" \
               anthropicApiKey="<key>"

# 3. Deploy RBAC (subscription scope)
az deployment sub create \
  --location eastus \
  --template-file rbac.bicep \
  --parameters functionAppPrincipalId="<principal-id-from-output>"
```

## Resources Deployed

| Resource | SKU/Tier | Monthly Cost (est.) |
|----------|----------|-------------------|
| Static Web App | Free | $0 |
| Function App | Consumption (Y1) | ~$0–5 (pay per call) |
| App Service Plan | Y1 Dynamic | $0 |
| Storage Account | Standard LRS | ~$1 |
| Key Vault | Standard | ~$0.03/10k ops |
| Log Analytics | Pay-per-GB | ~$2–5 |
| App Insights | Pay-per-GB | ~$0–3 |
| **Total** | | **~$3–14/month** |

## Security

- **No secrets in code** — all credentials stored in Key Vault
- **Managed Identity** used by Function App to read Key Vault (no stored credentials)
- **HTTPS only** enforced on all resources
- **RBAC least-privilege** — Function App gets `Monitoring Reader` + `Reader` only
- **TLS 1.2 minimum** on all endpoints

## Troubleshooting

**Function App can't read VMs:**
```bash
# Check managed identity has correct roles
az role assignment list --assignee <principal-id> --all
```

**Key Vault access denied:**
```bash
# Verify Function App identity has Secrets User role
az keyvault show --name <kv-name> --query properties.accessPolicies
```

**Static Web App CORS error:**
```bash
# Update CORS in Function App settings to include your SWA URL
az functionapp cors add --name <func-name> --resource-group <rg> \
  --allowed-origins "https://<your-swa>.azurestaticapps.net"
```
