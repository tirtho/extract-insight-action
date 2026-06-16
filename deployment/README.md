# Infrastructure Deployment

This folder contains the numbered scripts that deploy and operate the Azure
infrastructure for the extract-insight-action (EIA) project. Each step has a
PowerShell (`.ps1`) script and a matching Bash (`.sh`) script with identical
functionality. Run the steps in prefix-number order.

> For the full end-to-end runbook (including local validation and user
> onboarding), see the root [README.md](../README.md). This document focuses on
> the deployment folder itself.

## Overview

The deployment scripts create and configure the following Azure resources:

- **Resource Group** - Container for all project resources
- **Key Vault** - Secure storage for secrets and configuration
- **Storage Account** - Required for the Azure Functions runtime
- **Service Bus** - Message queuing between the functions
- **Application Insights** - Application monitoring and logging
- **App Service Plan** - Hosting plan for the Function Apps and Web App
- **Function Apps** - Three Java-based function apps:
  - `mailbox-to-queue` - Polls the M365 mailbox and enqueues messages
  - `queue-to-db` - Processes queued messages and persists to Cosmos DB
  - `cu-queue-to-db` - Runs Content Understanding analysis and persists results
- **Web App** - Spring Boot UI for secure user review and actions
- **Cosmos DB** - Persistence for extracted insight
- **AI Foundry** - Hosts the triage / decision-support agents
- **Content Understanding** - Document, image, audio and video analyzers
- **Microsoft Graph API Registration** - For accessing mailbox data
- **Managed Identities** - Secure service-to-service authentication
- **RBAC Permissions** - Least-privilege access controls for all resources

## Prerequisites

1. **Azure CLI** installed and authenticated
   ```bash
   # Login to Azure
   az login

   # Set your subscription (if you have multiple)
   az account set --subscription "your-subscription-id"
   ```

2. **Shell environment**:
   - **Windows**: Windows PowerShell 5.1 or PowerShell 7.x (run the `.ps1` scripts)
   - **Linux / macOS**: Bash, with `jq` and `curl` available (run the `.sh` scripts)
   - **Alternative**: Azure Cloud Shell (Bash or PowerShell)

3. **Build tooling** (required by `3.deploy-agents` and `5.deploy-code`):
   - Java 21 JDK (`JAVA_HOME` must point to Java 21)
   - Maven (`mvn` on `PATH`)

4. **Appropriate Azure permissions**:
   - Contributor (or Owner) on the subscription or resource group
   - Entra Application Administrator (for creating app registrations)
   - Entra Privileged Role Administrator / Global Administrator for admin consent

## Usage

Every step ships as both a PowerShell and a Bash script. Each script accepts
`-Environment`/`--environment` and `-Suffix`/positional suffix; if omitted, the
script prompts for them (and for location). Keep the environment, suffix and
location consistent across all steps for the same deployment.

Example deployment key: `eia-dev-1`

### Script order

| Step | PowerShell | Bash | Purpose |
|------|-----------|------|---------|
| 1 | `1.deploy-infrastructure.ps1` | `1.deploy-infrastructure.sh` | Create all core Azure resources; write `env.bat` |
| 2 | `2.grant-graph-consent.ps1` | `2.grant-graph-consent.sh` | Grant admin consent for the Graph API app registration |
| 3 | `3.deploy-agents.ps1` | `3.deploy-agents.sh` | Build and provision the AI Foundry agents |
| 4 | `4.content-understanding-add-schema.ps1` | `4.content-understanding-add-schema.sh` | Register the Content Understanding analyzer schemas |
| 5 | `5.deploy-code.ps1` | `5.deploy-code.sh` | Build and deploy the function and web app code |
| 6 | `6.operation-dev.ps1` / `6.operation-prod.ps1` | `6.operation-dev.sh` / `6.operation-prod.sh` | Apply the environment posture (run **last**) |

Step 6 is an either/or posture choice, run after everything else is deployed:

- **`6.operation-dev`** - opens public access and grants the signed-in user
  data-plane RBAC for local testing.
- **`6.operation-prod`** - hardens the network (VNet, private endpoints,
  disables public access). It then prompts **"Allow local testing access?"**:
  answer **yes** to punch a temporary firewall hole for your current public IP
  and grant your signed-in user the data-plane RBAC (Storage, Key Vault, Cosmos
  DB built-in data roles, Cognitive Services) needed to test against the
  hardened resources; answer **no** to remove that access and keep everything
  fully private.

To **undo** the prod hardening, re-run `6.operation-prod` with the rollback
switch. It deletes the VNet / private endpoints / private DNS zones, re-enables
public network access, and removes the VNet integration, restoring the
pre-hardening state. RBAC role assignments are left untouched.

```powershell
.\deployment\6.operation-prod.ps1 -Environment prod -Suffix 1 -Rollback
```

```bash
./deployment/6.operation-prod.sh 1 --environment prod --rollback
```

### Example (PowerShell)

```powershell
.\deployment\1.deploy-infrastructure.ps1 -Environment dev -Suffix 1
.\deployment\2.grant-graph-consent.ps1 -Environment dev -Suffix 1
.\deployment\3.deploy-agents.ps1 -Environment dev -Suffix 1
.\deployment\4.content-understanding-add-schema.ps1 -Environment dev -Suffix 1
.\deployment\5.deploy-code.ps1 -Environment dev -Suffix 1
.\deployment\6.operation-dev.ps1 -Environment dev -Suffix 1
```

### Example (Bash)

```bash
./deployment/1.deploy-infrastructure.sh 1 --environment dev
./deployment/2.grant-graph-consent.sh 1 --environment dev
./deployment/3.deploy-agents.sh 1 --environment dev
./deployment/4.content-understanding-add-schema.sh 1 --environment dev
./deployment/5.deploy-code.sh 1 --environment dev
./deployment/6.operation-dev.sh 1 --environment dev
```

### Utility scripts

These sit outside the numbered sequence:

| Script | Purpose |
|--------|---------|
| `110.admin-user-access.ps1` | Configure access groups and user profile metadata |
| `1000.local-deploy.ps1` | Run the app locally for validation |
| `rotate-graph-api-secret.ps1` / `.sh` | Rotate the Graph API client secret |
| `100.admin-delete-all.ps1` | **Destructive** - delete all deployed resources |

## Configuration Variables

The scripts derive resource names from a small set of values. They are passed as
script parameters (`-Environment`/`-Suffix`) or picked up from the environment;
any missing value is prompted for at runtime.

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `PROJECT_NAME` | Base name for all resources | `eia` | `eia` |
| `Environment` | Environment name | `dev` (prod scripts default `prod`) | `dev`, `prod` |
| `Suffix` | Short suffix to keep names unique | `1` | `1`, `999` |
| `Location` | Azure region | `centralus` | `eastus`, `westus2` |

## Resource Naming Convention

The scripts follow a consistent naming convention using the deployment key
`{project}-{environment}-{suffix}`:

- Resource Group: `rg-{project}-{environment}-{suffix}`
- Key Vault: `kv-{project}-{environment}-{suffix}`
- Storage Account: `st{project}{environment}{suffix}` (no hyphens, max 24 chars)
- Service Bus: `sb-{project}-{environment}-{suffix}`
- Cosmos DB: `cosmos-{project}-{environment}-{suffix}`
- AI Foundry: `oai-{project}-{environment}-{suffix}`
- Content Understanding: `cu-{project}-{environment}-{suffix}`
- Function Apps: `func-{type}-{project}-{environment}-{suffix}`
- Web App: `app-{project}-{environment}-{suffix}`

Keep `Suffix`, `Environment` and `Location` consistent across every script for
the same deployment.

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

To remove all created resources, use the destructive admin script (it deletes
the resource group and the Graph API app registration):

**PowerShell:**
```powershell
.\deployment\100.admin-delete-all.ps1 -Environment dev -Suffix 1
```

Or delete the resource group directly:

```bash
# Delete the entire resource group (WARNING: This deletes everything!)
az group delete --name "rg-eia-dev-1" --yes --no-wait
```

## Support

For issues with the deployment script:

1. Check the troubleshooting section above
2. Verify all prerequisites are met
3. Review the Azure CLI error messages
4. Check Azure Portal for resource status

For Azure service-specific issues, consult the official Azure documentation.

## TODO

- While the PowerShell scripts are tested, the Bash shell scripts (for installing from a Linux OS) are not tested yet.
