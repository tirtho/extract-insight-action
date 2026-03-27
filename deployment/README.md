# Infrastructure Deployment

This folder contains scripts and configuration for deploying the Azure infrastructure required for the extract-insight-action project.

## Overview

The deployment script creates and configures the following Azure resources:

- **Resource Group** - Container for all project resources
- **Key Vault** - Secure storage for secrets and configuration
- **Storage Account** - Required for Azure Functions runtime
- **Service Bus** - Message queuing service with topic and subscription
- **Application Insights** - Application monitoring and logging
- **App Service Plan** - Hosting plan for Function Apps
- **Function Apps** - Two Java-based function apps:
  - `mailbox-to-queue` - Processes emails from mailbox and sends to Service Bus
  - `queue-to-db` - Processes messages from Service Bus and stores in database
- **Microsoft Graph API Registration** - For accessing mailbox data
- **Managed Identities** - Secure authentication between services
- **RBAC Permissions** - Proper access controls for all resources

## Prerequisites

1. **Azure CLI** installed and authenticated
   ```bash
   # Install Azure CLI (if not already installed)
   # Windows: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows
   # macOS: brew install azure-cli
   # Linux: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux
   
   # Login to Azure
   az login
   
   # Set your subscription (if you have multiple)
   az account set --subscription "your-subscription-id"
   ```

2. **Shell environment**:
   - **Linux / macOS**: Bash
   - **Windows**: Command Prompt (cmd.exe) — native `.cmd` scripts are provided
   - **Alternative**: Azure Cloud Shell (bash)

3. **Appropriate Azure permissions**:
   - Contributor role on the subscription or resource group
   - Application Administrator role in Azure AD (for creating app registrations)

## Usage

Both Linux/macOS (bash) and Windows (cmd) scripts are provided with identical functionality.

---

### Linux / macOS (Bash)

#### 1. Configure Environment Variables

**Option A: Export variables in your shell**
```bash
export PROJECT_NAME="eia"
export ENVIRONMENT="dev"
export LOCATION="eastus"
export SUBSCRIPTION_ID="your-subscription-id"
```

**Option B: Use the configuration file**
```bash
# Edit the configuration file with your values
nano deployment/config.env

# Source the configuration
source deployment/config.env
```

#### 2. Run the Deployment Script

```bash
chmod +x deployment/deploy-infrastructure.sh
./deployment/deploy-infrastructure.sh
```

---

### Windows (Command Prompt)

#### 1. Configure Environment Variables

**Option A: Set variables in your cmd session**
```cmd
set "PROJECT_NAME=eia"
set "ENVIRONMENT=dev"
set "LOCATION=centalus"
set "SUBSCRIPTION_ID=your-subscription-id"
```

**Option B: Use the configuration file**
```cmd
REM Edit config.cmd with your values, then run it
notepad deployment\config.cmd
deployment\config.cmd
```

#### 2. Run the Deployment Script

```cmd
deployment\deploy-infrastructure.cmd
```

### 3. Post-Deployment Steps

After the script completes successfully:

1. **Grant Microsoft Graph API permissions**:
   - Go to Azure Portal > Azure Active Directory > App registrations
   - Find your app registration (e.g., "extract-insight-action-graph-api-dev")
   - Go to "API permissions"
   - Click "Grant admin consent" for the required permissions

2. **Deploy your function code**:
   ```bash
   # Navigate to your function folders and deploy
   cd extract/functions/mailbox-to-queue
   func azure functionapp publish func-mailbox-extract-insight-action-dev
   
   cd ../queue-to-db
   func azure functionapp publish func-queuedb-extract-insight-action-dev
   ```

## Configuration Variables

The script uses the following environment variables for configuration:

### Required Configuration
| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PROJECT_NAME` | Base name for all resources | `extract-insight-action` | `my-project` |
| `ENVIRONMENT` | Environment suffix | `dev` | `prod`, `staging` |
| `LOCATION` | Azure region | `eastus` | `westus2`, `canadacentral` |

### Optional Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `SUBSCRIPTION_ID` | Azure subscription ID | Current subscription |
| `RESOURCE_GROUP_NAME` | Resource group name | `rg-{PROJECT_NAME}-{ENVIRONMENT}` |
| `KEY_VAULT_NAME` | Key Vault name | `kv-{PROJECT_NAME}-{ENVIRONMENT}-{random}` |
| `SERVICE_BUS_NAMESPACE` | Service Bus namespace | `sb-{PROJECT_NAME}-{ENVIRONMENT}` |
| `STORAGE_ACCOUNT_NAME` | Storage account name | `st{PROJECT_NAME}{ENVIRONMENT}{random}` |

### Graph API Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `GRAPH_APP_NAME` | Graph API app registration name | `{PROJECT_NAME}-graph-api-{ENVIRONMENT}` |
| `GRAPH_CLIENT_ID` | Existing client ID (optional) | Created automatically |
| `GRAPH_CLIENT_SECRET` | Existing client secret (optional) | Created automatically |

## Resource Naming Convention

The script follows Azure naming conventions:

- Resource Group: `rg-{project}-{environment}`
- Key Vault: `kv-{project}-{environment}-{random}`
- Storage Account: `st{project}{environment}{random}` (no hyphens, max 24 chars)
- Service Bus: `sb-{project}-{environment}`
- Function Apps: `func-{type}-{project}-{environment}`

Random suffixes are added to globally unique resources to avoid naming conflicts.

## Idempotency

The script is idempotent, meaning you can run it multiple times safely. It will:

- Skip creating resources that already exist
- Update configurations where necessary
- Only create new resources when needed

This allows you to:
- Re-run the script if it fails partway through
- Update configurations by modifying variables and re-running
- Add new resources to existing deployments

## Security Features

The deployment implements several security best practices:

1. **Managed Identities** - No stored credentials for service-to-service authentication
2. **Key Vault References** - Sensitive configuration stored securely in Key Vault
3. **RBAC** - Principle of least privilege access controls
4. **Network Security** - Resources configured with appropriate access controls

## Monitoring and Observability

The deployment includes Application Insights for:

- Function execution monitoring
- Performance metrics
- Error tracking and alerting
- Distributed tracing across services

## Troubleshooting

### Common Issues

1. **Permission Errors**
   ```
   Error: Insufficient privileges to complete the operation
   ```
   - Ensure you have Contributor role on the subscription
   - For Graph API registration, you need Application Administrator role in Azure AD

2. **Naming Conflicts**
   ```
   Error: The storage account name is already taken
   ```
   - The script adds random suffixes to avoid this
   - If it still occurs, modify the `PROJECT_NAME` or `ENVIRONMENT` variables

3. **Quota Limits**
   ```
   Error: Operation results in exceeding quota limits
   ```
   - Check your Azure subscription limits
   - Consider using a different region or subscription

4. **Graph API Permissions**
   ```
   Functions can't access mailbox data
   ```
   - Ensure admin consent was granted for Graph API permissions
   - Verify the app registration has the correct permissions

### Logs and Debugging

- The script provides colored output for easy reading
- All operations are logged with status indicators
- Use Azure CLI with `--debug` flag for detailed troubleshooting:
  ```bash
  az --debug account show
  ```

### Cleanup

To remove all created resources:

**Bash:**
```bash
# Delete the entire resource group (WARNING: This deletes everything!)
az group delete --name "rg-eia-dev" --yes --no-wait

# Delete the Graph API app registration separately
az ad app delete --id "$GRAPH_CLIENT_ID"
```

**Windows cmd:**
```cmd
REM Delete the entire resource group (WARNING: This deletes everything!)
az group delete --name "rg-eia-dev" --yes --no-wait

REM Delete the Graph API app registration separately
az ad app delete --id "%GRAPH_CLIENT_ID%"
```

## Support

For issues with the deployment script:

1. Check the troubleshooting section above
2. Verify all prerequisites are met
3. Review the Azure CLI error messages
4. Check Azure Portal for resource status

For Azure service-specific issues, consult the official Azure documentation.