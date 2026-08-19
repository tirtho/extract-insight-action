# Embeddings Model Deployment Updates

## Summary
Updated deployment scripts (`1.deploy-infrastructure.ps1` and `1.deploy-infrastructure.sh`) to provision and configure the Azure OpenAI embeddings model for email and attachment vector search integration.

## Changes Made

### 1. Added Embeddings Model Configuration Variables

**PowerShell (1.deploy-infrastructure.ps1)** - Lines 164-169:
```powershell
# AI Foundry embeddings model for vector search on emails and attachments.
# Used by the orchestration functions for generating embeddings for semantic search.
$AiFoundryEmbeddingsDeploymentName = "text-embedding-3-small"
$AiFoundryEmbeddingsModelName      = "text-embedding-3-small"
$AiFoundryEmbeddingsModelVersion   = "1"
$AiFoundryEmbeddingsSkuCapacity    = "50"
```

**Bash (1.deploy-infrastructure.sh)** - Lines 156-161:
```bash
# AI Foundry embeddings model for vector search on emails and attachments
AiFoundryEmbeddingsDeploymentName="text-embedding-3-small"
AiFoundryEmbeddingsModelName="text-embedding-3-small"
AiFoundryEmbeddingsModelVersion="1"
AiFoundryEmbeddingsSkuCapacity="50"
```

**Configuration Details:**
- **Model**: `text-embedding-3-small` (can be changed to `text-embedding-3-large` for higher quality)
- **Version**: `1` (current version for embedding models)
- **SKU Capacity**: `50` (K TPM - tokens per minute; adjust based on workload)
- **Purpose**: Generates vector embeddings for email bodies and attachment content for semantic search

### 2. Added Embeddings to Key Vault Secrets

**PowerShell (1.deploy-infrastructure.ps1)** - Lines 2097-2098 (in $kvSecrets hashtable):
```powershell
"AiFoundryEmbeddingsDeploymentName"     = $AiFoundryEmbeddingsDeploymentName
"AiFoundryEmbeddingsModelName"          = $AiFoundryEmbeddingsModelName
```

**Bash (1.deploy-infrastructure.sh)** - Lines 1708-1709 (in KV_SECRETS array):
```bash
[AiFoundryEmbeddingsDeploymentName]="$AiFoundryEmbeddingsDeploymentName"
[AiFoundryEmbeddingsModelName]="$AiFoundryEmbeddingsModelName"
```

**Storage Details:**
- These secrets are stored in Azure Key Vault and accessed by Java functions via `AzConnection.getAiFoundryEmbeddingsDeploymentName()`
- The deployment name is used to instantiate the OpenAI embeddings client
- Non-sensitive (deployment names are public configuration)

### 3. Added AI Foundry Embeddings Model Deployment

**PowerShell (1.deploy-infrastructure.ps1)** - Lines 1626-1650 (new section after CU embedding deployment):
```powershell
# Deploy AI Foundry embeddings model for email and attachment vector search.
# This deployment is separate from Content Understanding and used by the Java
# orchestration functions for generating embeddings for semantic search.
Write-Host ""
Write-Host ">>> Deploying AI Foundry embeddings model for email/attachment search" -ForegroundColor White

$aiFoundryEmbedDeploymentExists = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--deployment-name',$AiFoundryEmbeddingsDeploymentName,'--query','name','-o','tsv')).Output
if ($aiFoundryEmbedDeploymentExists) {
    Write-Host "[WARNING] AI Foundry embeddings model deployment $AiFoundryEmbeddingsDeploymentName already exists on $AiFoundryName, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Deploying AI Foundry embeddings model $AiFoundryEmbeddingsModelName on $AiFoundryName ($AiFoundrySkuName, ${AiFoundryEmbeddingsSkuCapacity}K TPM)" `
        -Arguments @('cognitiveservices','account','deployment','create',
                     '--name',$AiFoundryName,'--resource-group',$ResourceGroupName,
                     '--deployment-name',$AiFoundryEmbeddingsDeploymentName,
                     '--model-name',$AiFoundryEmbeddingsModelName,
                     '--model-version',$AiFoundryEmbeddingsModelVersion,
                     '--model-format','OpenAI',
                     '--sku-name',$AiFoundrySkuName,
                     '--sku-capacity',$AiFoundryEmbeddingsSkuCapacity,
                     '--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] AI Foundry embeddings model $AiFoundryEmbeddingsModelName deployed as $AiFoundryEmbeddingsDeploymentName on $AiFoundryName" -ForegroundColor Green
    }
}
```

**Bash (1.deploy-infrastructure.sh)** - Lines 1289-1310 (new section after CU embedding deployment):
```bash
# Deploy AI Foundry embeddings model for email and attachment vector search.
echo ""
echo ">>> Deploying AI Foundry embeddings model for email/attachment search"

ai_foundry_embed_exists=$(az cognitiveservices account deployment show \
    --name "$AiFoundryName" --resource-group "$ResourceGroupName" \
    --deployment-name "$AiFoundryEmbeddingsDeploymentName" --query name -o tsv 2>/dev/null || true)
if [[ -n "$ai_foundry_embed_exists" ]]; then
    echo "[WARNING] AI Foundry embeddings model deployment $AiFoundryEmbeddingsDeploymentName already exists on $AiFoundryName, skipping"
else
    if az cognitiveservices account deployment create \
            --name "$AiFoundryName" --resource-group "$ResourceGroupName" \
            --deployment-name "$AiFoundryEmbeddingsDeploymentName" \
            --model-name "$AiFoundryEmbeddingsModelName" --model-version "$AiFoundryEmbeddingsModelVersion" \
            --model-format OpenAI --sku-name "$AiFoundrySkuName" --sku-capacity "$AiFoundryEmbeddingsSkuCapacity" \
            --output table 2>/dev/null; then
        echo "[SUCCESS] AI Foundry embeddings model $AiFoundryEmbeddingsModelName deployed as $AiFoundryEmbeddingsDeploymentName on $AiFoundryName"
    else
        DEPLOYMENT_ERRORS+=("Deploying AI Foundry embeddings model $AiFoundryEmbeddingsModelName on $AiFoundryName")
    fi
fi
```

**Deployment Details:**
- Checks if embeddings model deployment already exists (idempotent)
- Deploys to the same AI Foundry account as the primary LLM model
- Uses `GlobalStandard` SKU (same as primary model)
- Allocates 50K TPM capacity (adjustable based on workload)
- Runs after Content Understanding model deployment, before application configuration

## Related Code Components

These deployment changes support the Java implementation:
- **AzOpenAiEmbeddings.java**: Helper class using OpenAI embeddings API
- **ExtractMail.java**: Orchestrator with new CreateEmailEmbeddings activity
- **PollCuAnalysis.java**: Timer function generating attachment embeddings
- **AzEnvNames.java**: Key Vault constant `KV_AI_FOUNDRY_EMBEDDINGS_DEPLOYMENT_NAME`
- **CreateEmailEmbeddingsInput.java**: DTO for activity parameter

## Key Vault Configuration

After running the deployment script, the following secrets will be available:

| Secret Name | Example Value | Usage |
|---|---|---|
| `AiFoundryEmbeddingsDeploymentName` | `text-embedding-3-small` | Deployment name for embeddings client |
| `AiFoundryEmbeddingsModelName` | `text-embedding-3-small` | Model name for reference |

## Execution Flow

1. **Infrastructure Deployment** (Step 1):
   - Provisions AI Foundry account (existing)
   - Deploys embeddings model on AI Foundry
   - Stores configuration in Key Vault

2. **Code Deployment** (Step 5):
   - Function apps retrieve `AiFoundryEmbeddingsDeploymentName` from Key Vault
   - AzConnection factory creates OpenAI embeddings client

3. **Runtime** (Email Processing):
   - **Email Body**: Embeddings generated immediately in orchestrator Step 5 (CreateEmailEmbeddings activity)
   - **Attachments**: Embeddings generated after CU analysis completes (PollCuAnalysis timer function)
   - Both stored in Cosmos DB `embedding` field for vector search

## Model Selection

The default `text-embedding-3-small` model is recommended for:
- Cost efficiency (lower pricing than large variant)
- Sufficient for semantic search on emails and attachments (1536 dimensions)
- Adequate for hybrid search with BM25 + semantic ranking

To use `text-embedding-3-large` (3072 dimensions):
1. Edit the deployment script and change:
   ```powershell
   $AiFoundryEmbeddingsModelName = "text-embedding-3-large"
   ```
2. Redeploy: `.\1.deploy-infrastructure.ps1 -Suffix <your-suffix>`
3. The script will detect no changes to KV secrets but will update the model deployment if needed

## Capacity Planning

Current allocation: **50K TPM** per embeddings model

Estimate your workload:
- Email body: ~100-500 tokens per embedding
- Attachment analysis text: ~200-2000 tokens per embedding
- For 1000 emails/month with 2 attachments: ~400-4000K tokens/month = 13-133K TPM average

Adjust `$AiFoundryEmbeddingsSkuCapacity` if needed and redeploy.

## Troubleshooting

### Model deployment fails with "Model not available in region"
- Check `supported-service-locations.csv` for your location
- Alternative: Use a different region that supports text-embedding-3-small
- Or modify the script to request user-selected model during deployment

### Key Vault secrets not populated
- Verify user has "Key Vault Administrator" role on the vault
- Check Key Vault network rules (if private endpoints configured)
- Manually set: `az keyvault secret set --vault-name <vault> --name AiFoundryEmbeddingsDeploymentName --value text-embedding-3-small`

### Embeddings generation fails in Java
- Confirm Key Vault secrets are set correctly
- Check managed identity has RBAC permissions to Key Vault
- Verify OpenAI endpoint and deployment name in configuration
- Check Azure OpenAI quota and throttling

## References

- Azure OpenAI Embeddings: https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/understand-embeddings
- text-embedding-3 models: https://platform.openai.com/docs/guides/embeddings/embedding-models
- Azure Key Vault integration: https://learn.microsoft.com/en-us/azure/key-vault/general/overview
