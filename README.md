# The Application - what it does

extract-insight-action is an email intelligence workflow that ingests mailbox messages, processes their attachments, and turns raw content into searchable operational insight. It uses Azure Functions and Service Bus to orchestrate pipeline stages from mailbox polling, to message normalization, to persistence in Cosmos DB.

For attachments, the system uses Azure Content Understanding analyzers to extract structured data from documents, images, audio, video, and other file types, then stores both status and analysis output for downstream use. A Spring Boot web application provides a secured review experience where users can browse emails, inspect extracted results, open attachments, and use Foundry deployed AI Agents for triage, decision support, and downstream processing.

The platform is designed for enterprise operations: identity is enforced through Entra, secrets are centralized in Key Vault, and deployment is automated through script-driven infrastructure, consent, and onboarding flows. In short, it connects mailbox intake to AI-powered analysis and presents the results in a user-facing portal that teams can use to review and act quickly.



# extract-insight-action

This guide is the full runbook to deploy everything into a brand new Azure subscription, in the correct order:

- Infrastructure
- Graph permissions and consent
- Environment setup and role setup
- Content Understanding schemas
- Agents
- Application code
- End-user onboarding and access

The steps below are written for Windows PowerShell because this repo includes first-class PowerShell scripts.

## 1. Prerequisites

Install tools:

- Azure CLI
- Java 21 JDK (JAVA_HOME must point to Java 21)
- Maven (mvn on PATH)

Recommended operator privileges for a full first-time deployment:

- Azure subscription Contributor (or Owner) on target subscription
- Entra Application Administrator (or higher) for app registration operations
- Entra Privileged Role Administrator or Global Administrator for:
	- Graph admin consent operations
	- Directory custom role creation and assignment

If your tenant uses PIM, activate the needed Entra roles first, then refresh CLI login.

## 2. Clone And Open

Open this repository in PowerShell:

```powershell
cd C:\path\to\extract-insight-action
```

## 3. Sign In And Target Subscription

```powershell
az login
az account set --subscription <your-subscription-id>
az account show --query "{name:name,id:id,tenantId:tenantId}" -o json
```

## 4. Configure Deployment Variables

Edit deployment/env.config and set values for your environment. At minimum, verify these are correct:

- PROJECT_NAME
- ENVIRONMENT
- LOCATION
- USER_EMAIL_ADDRESS
- SUBSCRIPTION_ID

You can optionally run the helper to load config and derive KEY_VAULT_URL:

```powershell
. .\deployment\1.config.ps1
```

## 5. Choose A Suffix

Pick a suffix for globally unique resources, for example 1.

Use the same suffix for all deployment scripts.

## 6. Deploy Infrastructure

```powershell
.\deployment\2.deploy-infrastructure.ps1 -Suffix 1
```

This creates the core Azure resources, app registrations, identities, and baseline configuration.

## 7. Grant Graph Consent For Mailbox App Registration

```powershell
.\deployment\3.grant-graph-consent.ps1 -Suffix 1
```

Run this with an account that has tenant admin rights required by the script.

## 8. Run Operation Setup (Dev Operations)

```powershell
.\deployment\4.operation-dev.ps1 -Suffix 1
```

When prompted for steps, choose All unless you intentionally want partial setup.

Step 4 in this script now verifies the Key Vault-backed profile store and reminds you that job titles are persisted in a Key Vault JSON secret keyed by email address.

## 9. Register Content Understanding Schemas

```powershell
.\deployment\5.content-understanding-add-schema.ps1 -Suffix 1
```

This reads schema files from deployment/cu-schemas and registers analyzers.

## 10. Deploy AI Agents

```powershell
.\deployment\8.deploy-agents.ps1 -Suffix 1
```

Select the agent workloads to provision and provide instructions when prompted.

## 11. Deploy Application Code

```powershell
.\deployment\9.deploy-code.ps1 -Suffix 1
```

For full first deployment, select All workloads.

For later incremental updates, you can select only the target workload (for example web app only).

## 12. Onboard Users And Assign Access

```powershell
.\deployment\11.admin-user-access.ps1 -Suffix 1
```

This script:

- Ensures portal access group exists
- Creates users if needed
- Adds users to group
- Prompts for each user's job title and stores it in Key Vault as JSON keyed by email

If Key Vault access fails, rerun with an account that has Key Vault Secrets Officer or Key Vault Administrator on the vault.

## 13. Validate End To End

Validate with a newly onboarded user:

1. Sign in to web app URL shown by onboarding script
2. Confirm mailbox content is visible
3. Update Job Title from account menu
4. Verify header updates to Agentic plus job title pulled from Key Vault

## 14. Operational Utilities

- Rotate Graph secret:

```powershell
.\deployment\rotate-graph-api-secret.ps1 -Suffix 1
```

- Delete all deployed resources (destructive):

```powershell
.\deployment\10.delete-all.ps1 -Suffix 1
```

## 15. Recommended First-Time Execution Order (Summary)

Run scripts in this exact order for a brand new subscription:

1. deployment/2.deploy-infrastructure.ps1
2. deployment/3.grant-graph-consent.ps1
3. deployment/4.operation-dev.ps1
4. deployment/5.content-understanding-add-schema.ps1
5. deployment/8.deploy-agents.ps1
6. deployment/9.deploy-code.ps1
7. deployment/11.admin-user-access.ps1

Optional helper before step 2:

1. deployment/1.config.ps1

## 16. Common Issues

Authorization_RequestDenied during profile setup:

- Cause: the web app cannot read or write the Key Vault secret that stores user profiles
- Fix: grant the web app identity Key Vault Secrets Officer on the vault and rerun the deployment

Profile update missing in the header:

- Ensure the user's email exists as a key in the Key Vault JSON secret
- Ensure the JSON entry includes a JobTitle property