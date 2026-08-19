import sys
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

ep = "https://cosmos-eia-search-1.documents.azure.com:443/"
cred = DefaultAzureCredential()
client = CosmosClient(ep, cred)
cont = client.get_database_client("DocAIDatabase").get_container_client("EmailExtracts")

# 1) grab a real embedding from an existing doc
row = list(cont.query_items(
    "SELECT TOP 1 c.id, c.embedding FROM c WHERE IS_DEFINED(c.embedding)",
    enable_cross_partition_query=True))
if not row:
    print("NO embeddings found"); sys.exit(0)
qv = row[0]["embedding"]
print("query vector dims:", len(qv), "from id:", row[0]["id"][:40])

# 2) run the same vector query the app runs, parameterized
q = ("SELECT TOP 100 c.id, VectorDistance(c.embedding, @e) AS s "
     "FROM c WHERE IS_DEFINED(c.embedding) "
     "ORDER BY VectorDistance(c.embedding, @e)")
res = list(cont.query_items(query=q, parameters=[{"name": "@e", "value": qv}],
                            enable_cross_partition_query=True))
print("PARAMETERIZED vector query returned:", len(res))
for r in res[:3]:
    print("  ", round(r["s"], 4), r["id"][:50])

# 3) run the app's EXACT query text: SELECT * ... @embedding, param name @embedding
qapp = ("SELECT TOP 100 * FROM c WHERE IS_DEFINED(c.embedding) "
        "ORDER BY VectorDistance(c.embedding, @embedding)")
res2 = list(cont.query_items(query=qapp,
                             parameters=[{"name": "@embedding", "value": qv}],
                             enable_cross_partition_query=True))
print("APP-EXACT (SELECT *) query returned:", len(res2))

# 4) hybrid variant like the app builds
qh = ("SELECT TOP 100 * FROM c WHERE IS_DEFINED(c.embedding) "
      "AND (CONTAINS(LOWER(c.subject), LOWER(@query)) "
      "OR CONTAINS(LOWER(c.bodyPreview), LOWER(@query)) "
      "OR CONTAINS(LOWER(c.body), LOWER(@query))) "
      "ORDER BY VectorDistance(c.embedding, @embedding)")
resh = list(cont.query_items(query=qh,
                             parameters=[{"name": "@query", "value": "insurance"},
                                         {"name": "@embedding", "value": qv}],
                             enable_cross_partition_query=True))
print("APP-HYBRID query returned:", len(resh))
