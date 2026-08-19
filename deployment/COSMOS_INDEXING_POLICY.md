# Cosmos DB Vector Indexing Policy Configuration

## Overview

The `EmailExtracts` container now includes a **vector indexing policy** to enable efficient vector search on the embedding field for semantic search capabilities.

## What Was Changed

The deployment scripts now configure the Cosmos DB container with:

### Indexing Policy Structure
```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/_etag/?" },
    { "path": "/embedding/*" }
  ],
  "vectorIndexes": [
    {
      "path": "/embedding",
      "type": "quantizedFlat"
    }
  ],
  "fullTextIndexes": [
    { "path": "/subject" },
    { "path": "/bodyContent" }
  ]
}
```

### Full-Text Policy Structure
```json
{
  "defaultLanguage": "en-US",
  "fullTextPaths": [
    { "path": "/subject", "language": "en-US" },
    { "path": "/bodyContent", "language": "en-US" }
  ]
}
```

The full-text policy enables Cosmos-native BM25 keyword scoring (`FullTextScore`) on `/subject` and `/bodyContent`, and the matching `fullTextIndexes` back those columns. `/embedding/*` is excluded from the default term index (the vector index handles it) to keep RU cost down.

### Key Components

| Component | Value | Purpose |
|---|---|---|
| **indexingMode** | `consistent` | Indexes updated synchronously with writes (required for vector search) |
| **automatic** | `true` | Cosmos DB automatically indexes all properties except excluded paths |
| **includedPaths** | `/*` | Index all document paths by default |
| **excludedPaths** | `/_etag/?` | Exclude system property _etag from indexing (already tracked separately) |
| **vectorIndexes[0].path** | `/embedding` | Index the `embedding` float array field for vector search |
| **vectorIndexes[0].type** | `quantizedFlat` | Use quantized flat indexing (memory-efficient, fast approximate nearest neighbor) |

## How Vector Search Works

### Query Types Enabled

1. **Vector Search (Pure)**
   - Find documents by vector similarity to query embedding
   - Use case: "Find similar emails to this one"
   - Method: Cosmos DB vector search query

2. **Hybrid Search (RRF: Vector + Full-Text)**
   - Fuse vector similarity with BM25 keyword relevance using Reciprocal Rank Fusion
   - Use case: "Find emails about 'claims' — surface docs that match strongly on keyword OR semantics"
   - Method: Cosmos-native `ORDER BY RANK RRF(...)`:
     ```sql
     SELECT TOP @top * FROM c
     ORDER BY RANK RRF(
       VectorDistance(c.embedding, @embedding),
       FullTextScore(c.subject, @t0, @t1, ...),
       FullTextScore(c.bodyContent, @t0, @t1, ...)
     )
     ```
   - RRF returns a fused rank (not a 0-1 score), so the UI hides the score badge for Hybrid. Unlike a keyword-AND filter, a doc ranks high on strong keyword *or* strong semantic match.

3. **Semantic Reranking (LLM)**
   - Rerank a candidate pool with the chat model (`gpt-5.6-luna`) for relevance ordering
   - Use case: Rank results by relevance rather than raw similarity score
   - Method: Post-process a candidate pool via LLM rerank (the Cosmos Java SDK semantic reranker is not yet published to Maven)

### Query Performance

- **Vector Index Type: quantizedFlat**
  - **Pros**: Memory-efficient (60-70% smaller than full precision), fast (milliseconds)
  - **Cons**: Slight accuracy loss vs. full precision (negligible for semantic search)
  - **Use Case**: Production semantic search with high RU efficiency
  - **Alternative**: `diskANN` for very large result sets (millions of vectors)

### Vector Dimensions

The embeddings are generated using `text-embedding-3-small`:
- **Dimensions**: 1,536 (smaller than large variant's 3,072)
- **Storage**: ~6.1 KB per embedding (quantized: ~1.8-2.4 KB)
- **Recommendation**: Sufficient for semantic search, cost-effective

## Deployment Behavior

### New Deployments
When creating a new container:
```bash
az cosmosdb sql container create --account-name <name> \
  --name EmailExtracts \
  --partition-key-path /id \
  --indexing-policy @indexing-policy.json
```
- Container created with vector indexing policy applied immediately
- No additional steps needed

### Existing Deployments
When updating an existing container:
```bash
az cosmosdb sql container update --account-name <name> \
  --name EmailExtracts \
  --indexing-policy @indexing-policy.json
```
- Policy is applied without recreating the container
- In-progress indexing updates documents (may take time for large containers)
- No downtime required

## RU Cost Impact

### Indexing Cost
- Vector index adds **minimal indexing cost** (~5-10% increase)
- Quantized indexing reduces memory footprint
- Cost amortized over index lifetime

### Query Cost
- **Vector search query**: 2-5 RU per query (depends on result set size)
- **Hybrid query**: 3-8 RU per query (vector search + filter)
- Much cheaper than non-indexed full table scan

### Example Cost Estimate
- 100,000 emails with embeddings
- Average query: 3 RU
- 1,000 queries/day: 3,000 RU/day = ~$450/month at standard pricing
- Hybrid search with semantic reranking: similar cost as vector search alone

## Verifying Indexing Policy

### Check Current Policy (PowerShell)
```powershell
$policy = az cosmosdb sql container show `
  --account-name eia-dev-1 `
  --database-name DocAIDatabase `
  --name EmailExtracts `
  --resource-group rg-eia-dev-1 `
  --query 'resource.indexingPolicy' -o json

$policy | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

### Check Current Policy (Bash)
```bash
az cosmosdb sql container show \
  --account-name eia-dev-1 \
  --database-name DocAIDatabase \
  --name EmailExtracts \
  --resource-group rg-eia-dev-1 \
  --query 'resource.indexingPolicy' -o json | jq .
```

### Expected Output
```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/_etag/?" },
    { "path": "/embedding/*" }
  ],
  "vectorIndexes": [
    {
      "path": "/embedding",
      "type": "quantizedFlat"
    }
  ],
  "fullTextIndexes": [
    { "path": "/subject" },
    { "path": "/bodyContent" }
  ]
}
```

## Index Rebuild Status

### Monitor Indexing Progress
```bash
# Check transformation progress (while indexing)
az cosmosdb sql container show \
  --account-name eia-dev-1 \
  --database-name DocAIDatabase \
  --name EmailExtracts \
  --resource-group rg-eia-dev-1 \
  --query 'resource.indexingPolicy.compositeIndexes' -o json
```

### Timeline for Existing Containers
- **Small** (< 10K docs): Seconds
- **Medium** (10K-100K docs): Minutes
- **Large** (100K-1M+ docs): Hours to days

During indexing:
- Queries work but may not use vector index until indexing complete
- RU cost temporarily higher for writes
- No downtime or service interruption

## Querying with Vector Search

### Vector Search Query (Cosmos SDK)
```java
// Using Azure Cosmos DB SDK v4
Container container = client.getDatabase("DocAIDatabase")
    .getContainer("EmailExtracts");

// Vector search query
SqlQuerySpec querySpec = new SqlQuerySpec(
    "SELECT TOP 10 * FROM c WHERE VectorDistance(c.embedding, @queryVector) > @similarity " +
    "ORDER BY VectorDistance(c.embedding, @queryVector) DESC",
    Arrays.asList(
        new SqlParameter("@queryVector", queryEmbedding),  // List<Double>
        new SqlParameter("@similarity", 0.7)
    )
);

CosmosPagedIterable<EmailDocument> results = container.queryItems(querySpec, new CosmosQueryRequestOptions(), EmailDocument.class);
```

### Hybrid Search Query (RRF)
Reciprocal Rank Fusion fuses vector similarity with BM25 keyword relevance. This is
what the `Hybrid` tab in the UI runs (`AzureEmailStore.rrfHybridQuery`). Unlike a
keyword-AND filter, a document ranks high on a strong keyword match **or** a strong
semantic match.
```java
// Query terms are tokenized into @t0, @t1, ... and passed to FullTextScore
SqlQuerySpec querySpec = new SqlQuerySpec(
    "SELECT TOP @top * FROM c " +
    "ORDER BY RANK RRF(" +
    "  VectorDistance(c.embedding, @embedding)," +
    "  FullTextScore(c.subject, @t0, @t1)," +
    "  FullTextScore(c.bodyContent, @t0, @t1))",
    Arrays.asList(
        new SqlParameter("@top", 10),
        new SqlParameter("@embedding", queryEmbedding),
        new SqlParameter("@t0", "claims"),
        new SqlParameter("@t1", "coverage")
    )
);
```
> RRF returns a fused **rank**, not a 0-1 similarity score, so the UI hides the score
> badge for Hybrid results.

## Performance Tuning

### Adjusting Similarity Threshold
- **0.9+**: High precision, fewer results (most similar documents)
- **0.7-0.9**: Balanced precision/recall (recommended)
- **0.5-0.7**: High recall, more results (less similar documents)
- **< 0.5**: Very loose matching (rarely used)

### Limiting Result Set
- Use `TOP n` in query to limit results
- Reduce post-processing cost
- Example: `SELECT TOP 10 * FROM c WHERE...` (default is unbounded)

### Vector Index Considerations
- **quantizedFlat**: Best for most use cases (fast, memory-efficient)
- **diskANN**: Use only if indexing > 1M vectors AND need <2s query latency
- Trade-off: diskANN slower to update but better for massive scale

## Troubleshooting

### Vector Queries Return No Results
**Symptoms**: Vector search returns empty even though documents exist

**Causes**:
- Indexing policy not applied (check with verify command above)
- Indexing still in progress (wait for transformation to complete)
- Similarity threshold too high (reduce threshold)
- Vector field doesn't exist in documents (verify embedding field exists)

**Solutions**:
1. Verify indexing policy applied: `az cosmosdb sql container show --query resource.indexingPolicy`
2. Check document structure: Query a sample document and confirm it has `embedding` field
3. Lower similarity threshold and retry
4. For new documents: Ensure application populates `embedding` field before insert

### Queries Slower Than Expected
**Symptoms**: Vector search queries taking longer than expected

**Causes**:
- Indexing still in progress for existing container
- Vector index not yet fully built (background task)
- Query result set very large (retrieving 1000+ docs)
- Similarity threshold too low (returning too many results)

**Solutions**:
1. Wait for indexing to complete (check progress with verify command)
2. Reduce result limit: `SELECT TOP 50 * FROM c WHERE...`
3. Increase similarity threshold: `@similarity 0.75` instead of 0.5
4. Consider adding additional WHERE clause filters for hybrid search

### RU Cost Too High
**Symptoms**: Vector search queries consuming more RU than expected

**Causes**:
- Large result set being returned
- Index still building (temporary RU spike)
- Multiple vector searches without filtering
- Similarity threshold too low (too many matches)

**Solutions**:
1. Add filters to narrow result set: `WHERE c.type = 'email' AND c.sentDate > @date`
2. Reduce `TOP n` limit to reduce data transfer
3. Increase similarity threshold to reduce matching documents
4. For high-volume queries: consider Azure Cognitive Search for scale

## References

- [Cosmos DB Vector Search](https://learn.microsoft.com/en-us/azure/cosmos-db/vector-search)
- [Indexing Policy Overview](https://learn.microsoft.com/en-us/azure/cosmos-db/index-policy)
- [Vector Index Types](https://learn.microsoft.com/en-us/azure/cosmos-db/vector-search-overview#vector-indexing-modes)
- [Query Vector Data](https://learn.microsoft.com/en-us/azure/cosmos-db/query-vector-data)
- [Vector Search Pricing](https://azure.microsoft.com/en-us/pricing/details/cosmos-db/autoscale)
