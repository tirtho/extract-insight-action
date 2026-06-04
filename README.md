# extract-insight-action

## What This Application Does

extract-insight-action is an email intelligence workflow that ingests mailbox messages, processes attachments, and turns content into searchable operational insight.

It uses:

- Azure Functions and Service Bus for orchestration
- Azure Content Understanding analyzers for document, image, audio, and video extraction
- Cosmos DB for persistence
- A Spring Boot web app for secure user review and actions
- AI agents for triage and decision support

## Deployment And Operations Runbook (PowerShell)

This runbook covers setup, deployment, code push, code deployment, and app run/validation.

## 1. Prerequisites

Install and verify:

- Azure CLI
- Java 21 JDK (JAVA_HOME must point to Java 21)
- Maven (mvn on PATH)

Recommended permissions for first-time environment setup:

- Contributor (or Owner) on target Azure subscription
- Entra Application Administrator (or higher)
- Entra Privileged Role Administrator or Global Administrator for admin consent and role operations

If your tenant uses PIM, activate roles before deployment.

## 2. Open The Repo And Sign In

```powershell
cd C:\path\to\extract-insight-action
az login
az account set --subscription <your-subscription-id>
az account show --query "{name:name,id:id,tenantId:tenantId}" -o json
```

## 3. Pick Environment And Suffix

Choose an environment (for example dev) and a short suffix such as 1. Use the same values for all deployment scripts.

Example deployment key: eia-dev-1

## 4. Deploy Infrastructure

Run:

```powershell
.\deployment\2.deploy-infrastructure.ps1 -Environment dev -Suffix 1
```

If you omit `-Environment` or `-Suffix`, the script prompts for them. The deployment scripts still prompt for location unless you accept the default shown in the prompt. It then creates core resources and writes env.bat at the repo root with AZURE_KEY_VAULT_URL.

## 5. Complete Platform Setup

Run in order:

```powershell
.\deployment\3.grant-graph-consent.ps1 -Environment dev -Suffix 1
.\deployment\4.operation-dev.ps1 -Environment dev -Suffix 1
.\deployment\5.content-understanding-add-schema.ps1 -Environment dev -Suffix 1
.\deployment\8.deploy-agents.ps1 -Environment dev -Suffix 1
```

## 6. Build And Deploy Application Code

Run:

```powershell
.\deployment\9.deploy-code.ps1 -Environment dev -Suffix 1
```

Select workloads when prompted (All for first deployment, or only the component you changed).

## 7. Onboard Users

Run:

```powershell
.\deployment\11.admin-user-access.ps1 -Environment dev -Suffix 1
```

This configures access groups and user profile metadata for the web app.

## 8. Push Code Changes

After local code changes:

```powershell
git status
git add .
git commit -m "<your message>"
git push
```

Then redeploy changed workloads:

```powershell
.\deployment\9.deploy-code.ps1 -Environment dev -Suffix 1
```

## 9. Run The App Locally

For local validation, use:

```powershell
.\deployment\100.local-test-deploy.ps1
```

Optional debug mode for a single selected function app:

```powershell
.\deployment\100.local-test-deploy.ps1 -Debug
```

If needed, explicitly pass Key Vault URL:

```powershell
.\deployment\100.local-test-deploy.ps1 -KeyVaultUrl https://<your-vault>.vault.azure.net
```

## 10. Recommended First-Time Script Order

1. deployment/2.deploy-infrastructure.ps1
2. deployment/3.grant-graph-consent.ps1
3. deployment/4.operation-dev.ps1
4. deployment/5.content-understanding-add-schema.ps1
5. deployment/8.deploy-agents.ps1
6. deployment/9.deploy-code.ps1
7. deployment/11.admin-user-access.ps1

## 11. Utilities

Rotate Graph secret:

```powershell
.\deployment\rotate-graph-api-secret.ps1 -Environment dev -Suffix 1
```

Delete all deployed resources (destructive):

```powershell
.\deployment\10.delete-all.ps1 -Environment dev -Suffix 1
```

## Notes

- Keep Suffix, Environment, and Location consistent across scripts for the same environment.