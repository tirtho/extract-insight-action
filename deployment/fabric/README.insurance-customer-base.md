# InsuranceCustomerBase: Azure SQL to Fabric

These custom scripts provision and populate an insurance-specific customer database
with customer, address, and insurance policy tables. They are not generic database
setup scripts. The Azure SQL server and resource group retain the environment naming convention.

`create-insurance-customer-base-db.ps1` creates or reuses `sql-eia-{environment}-{suffix}`
in the existing `rg-eia-{environment}-{suffix}` resource group and creates the
`InsuranceCustomerBase` Azure SQL database. It applies `sql/InsuranceCustomerBaseDB.sql` using
`Invoke-Sqlcmd`, including SQL batch separators (`GO`). The schema creates missing
objects; it does not migrate existing table definitions or seed data.

The script creates a Fabric **MirroredDatabase**, named
`InsuranceCustomerBase-{environment}-{suffix}`, and starts replication into OneLake.
The default Fabric connection is named
`InsuranceCustomerBase-{environment}-{suffix}-{workspace-guid}`.
It does not create a Lakehouse or an Azure SQL shortcut. The mirrored database
provides a read-only SQL analytics endpoint; writes still go to Azure SQL.

## Generate State Insurance Business Documents

Run the business-document script independently of the SQL population and policy
document scripts:

```powershell
cd deployment/fabric
./create-insurance-business-documents.ps1 `
  -WorkspaceId 'bfdbced0-16ef-4af2-b335-8635f8d75af3'

# Generate only Massachusetts and California locally, without Azure authentication.
./create-insurance-business-documents.ps1 -States MA,CA -LocalOnly

# Preview all 450 documents without browser, file, authentication, or Fabric calls.
./create-insurance-business-documents.ps1 -WhatIf

# Restart after stopping an earlier run; keep complete local PDFs, render missing
# ones, and replace matching or partially uploaded remote files.
./create-insurance-business-documents.ps1 `
  -WorkspaceId 'bfdbced0-16ef-4af2-b335-8635f8d75af3' -ReuseLocal -Overwrite

# Continue from the first unverified file; leave all earlier paths untouched.
./create-insurance-business-documents.ps1 `
  -WorkspaceId 'bfdbced0-16ef-4af2-b335-8635f8d75af3' `
  -StartAt 'InsuranceBusinessKnowledge/Auto/LA/Compliance/Auto_LA_Compliance.pdf' -ReuseLocal -Overwrite
```

The default is all 50 US states, excluding DC and territories, with three insurance
lines (`Auto`, `Home`, `Business`) and three documents per line: **450 PDFs**.
The script creates or reuses the exact-name **InsuranceBusinessDocuments** lakehouse
and explicitly creates the InsuranceBusinessKnowledge, line, state, and document-kind directories
under **Files**:

```text
InsuranceBusinessDocuments/
  Files/
    InsuranceBusinessKnowledge/
      Auto/
        MA/
          Compliance/
            Auto_MA_Compliance.pdf
          Guidelines/
            Auto_MA_Guidelines.pdf
          Regulatory/
            Auto_MA_Regulatory.pdf
        NY/
          Compliance/
            Auto_NY_Compliance.pdf
      Home/
        MA/
          Compliance/
            Home_MA_Compliance.pdf
      Business/
        MA/
          Compliance/
            Business_MA_Compliance.pdf
```

Every state under each line has all three document-kind folders. Filenames repeat
the exact line, state code, and document kind, joined with underscores.
Local PDFs use the same `InsuranceBusinessKnowledge/<Line>/<State>/<Kind>/<Line>_<State>_<Kind>.pdf`
layout under `deployment/fabric/InsuranceBusinessDocuments/`. Override this with
`-OutputDirectory`. Supply `-Overwrite` to replace matching local and remote PDFs;
otherwise both are protected. `-ReuseLocal` takes precedence over local overwrite:
it checks PDF header and end-of-file markers, keeps existing complete PDFs, and
renders only missing files. This is a structural check, not a freshness or full
PDF-integrity check; use `-Overwrite` without `-ReuseLocal` to regenerate content
after template changes. Remote overwrite still requires `-Overwrite`.
Files from the previous `<State>/<line>/<Kind>.pdf` or `Knowledge/` layouts are not moved, renamed,
or deleted, locally or in OneLake. A new run generates the new layout; `-ReuseLocal`
only reuses files already at the new paths. When building a knowledge source, scope
it to `Files/InsuranceBusinessKnowledge` to exclude the older copies. Folder display order in Fabric
is controlled by the explorer's sorting, not upload order.
`-StartAt` accepts an exact, case-sensitive relative document path. The path must
belong to the selected states. Processing includes that file and every subsequent
file, with lines ordered Auto/Home/Business, then states in selected-state order,
and documents ordered Compliance/Guidelines/Regulatory. Earlier local files are
not checked or changed and earlier remote files are not uploaded. Choose the
first unverified file from the failed run, not the last successfully verified
file. This is an explicit resume boundary, not a remote-content comparison.

For uploads, the script resolves the workspace and lakehouse before rendering.
If `-WorkspaceId` is omitted, it offers an interactive workspace picker; choose Q
to cancel without rendering or uploading. One background runspace renders the
next PDF while the main thread uploads and verifies the current one. At most one
PDF is rendered ahead; browser processes are not launched in bulk. Upload counts
and a progress indicator show completed work. `-LocalOnly` remains sequential and
does not authenticate. Generation still launches an isolated browser per document,
so a full run can take several minutes. Use `-States MA -LocalOnly` for a smaller
initial run. An already-running invocation does not pick up script changes: stop
it before restarting, and do not run two invocations against the same files.

Prerequisites: PowerShell 7+, Microsoft Edge or Google Chrome (or
`-BrowserExecutable`), and, for uploads, Azure CLI signed in with lakehouse creation
and OneLake write permissions in a capacity-backed Fabric workspace. No SQL module,
database access, Python, or model deployment is needed. The script does not read or
modify customer records, policy URLs, permissions, capacity, or DataAgents.

Content consists of hypothetical internal operating guidelines, jurisdictional
compliance review controls, and regulatory research registers. Guidelines include
line-specific underwriting, coverage, claims, and regional risk-screening topics.
These are templates localized by jurisdiction and screening priorities, not 50
independently researched bodies of state law. PDFs have no demo/example watermarks.
They identify their internal authority and unverified legal-source status instead;
compliance and regulatory documents do not invent statutes, required limits,
deadlines, or government approvals. Validate and replace review tasks with approved,
primary-source requirements before relying on them for legal determinations.

Uploads use Entra tokens, bounded requests, conditional file creation, binary
append/flush, and remote byte-length verification. A rendering or upload failure
stops both stages and retains completed local PDFs and already-uploaded files;
there is no cross-file rollback. Some PDFs can be uploaded before a later render
fails. The script reports its verified upload count, disposes the renderer, and
cleans up any active browser. Resolve the failure and rerun the affected states
with `-ReuseLocal -Overwrite`. This reuploads local PDFs, including previously
verified ones; use `-StartAt` to exclude earlier completed paths. The script does
not otherwise skip existing remote files.

GET and HEAD requests retry transient HTTP 408/429/500/502/503/504 responses and
transport failures, with four attempts total, exponential backoff and jitter,
and Retry-After handling (delays capped at 120 seconds). With `-Overwrite`, a
transient upload failure restarts that file from create, then append/flush/verify,
with at most four full-file attempts. It never blindly retries an uncertain
append in place. Without `-Overwrite`, upload writes are not retried because the
outcome may be uncertain; rerun that file with `-ReuseLocal -Overwrite`. Lakehouse
creation POSTs are not retried, and authentication/authorization errors and byte
length mismatches stop the run. Upload failures identify the relative file and
stage (create, append, flush, or verify). No two writers should target these paths
at the same time.

A same-name automatic
SQL endpoint does not prevent lakehouse reuse. Fabric still creates that endpoint;
these PDFs are not SQL tables and are not indexed or added to a knowledge base by
this script.

Offline and optional real-browser checks:

```powershell
pwsh -NoProfile -File ./deployment/tests/create-insurance-business-documents.Tests.ps1
pwsh -NoProfile -File ./deployment/tests/create-insurance-business-documents.Tests.ps1 -RenderPdf
```

## Create the Business Knowledge Base

After uploading the business PDFs, run from the repository root:

```powershell
./deployment/fabric/create-insurance-business-knowledgebase.ps1 `
    -Environment ins -Suffix 1 `
    -WorkspaceId bfdbced0-16ef-4af2-b335-8635f8d75af3
```

The script prompts for an AI Search name. Press Enter to keep
`aais-bzkb-eia-ins-1`, enter another globally unique name, or enter `Q` to cancel.
The default follows `aais-bzkb-eia-<environment>-<suffix>`. Omit `-WorkspaceId`
to select an accessible workspace. The default resource group is
`rg-eia-<environment>-<suffix>`; `-ResourceGroupName` and `-Location` override
the group and its default location.

It creates or reuses Azure AI Search (Basic by default) and creates the
**fou-iq-kb-business** knowledge base with the managed `insurance-business-onelake`
knowledge source. Foundry IQ knowledge bases are Search data-plane objects,
not separate ARM resources. Search manages the backing data source, skillset,
indexer, and index. Ingestion recursively targets only
`InsuranceBusinessDocuments/Files/InsuranceBusinessKnowledge`, excluding older
document trees, and refreshes hourly. Existing source or knowledge-base names
bound to different data are rejected, not overwritten.

Prerequisites and scope:

- PowerShell 7+, Azure CLI login, permission to create Search and assign Azure
  roles, and Fabric workspace access sufficient to list items and manage roles.
- Search and Fabric must use the same tenant. The Fabric tenant must allow
  external applications to access OneLake. The caller also needs permission to
  list files in the selected OneLake folder for coverage verification.
- The script assigns the caller Search Service Contributor and Search Index
  Data Contributor. For service-principal logins, supply `-CallerObjectId`.
- The Search system-assigned identity requires Fabric workspace Contributor.
  The script asks before granting this workspace-wide write permission.
  `-GrantFabricAccess` explicitly approves that grant without the prompt.
- New Search services incur ongoing charges. Existing services require Basic
  or higher, a system-assigned identity, Entra data-plane authentication, and
  endpoint connectivity. Existing service configuration is not changed.
- The stable `2026-04-01` API provides text ingestion and extractive retrieval
  without embedding or chat deployments. It does not configure LLM planning,
  answer synthesis, private networking, or document-level ACL trimming.
  Restrict Search access accordingly: retrieval does not filter documents by
  each caller's OneLake permissions. No Foundry project or agent connection is
  created by this script.

Search provisioning has a separate 30-minute wait, adjustable with
`-ProvisioningTimeoutMinutes` (1-120). Progress reports the provisioning state,
service status, and managed-identity readiness. A timeout does not delete the
service; inspect its reported state and rerun with the same name to reuse it.

The final monitoring loop runs by default, polling every 15 seconds for up to
30 minutes (`-IngestionTimeoutMinutes`, 1-120). It requires a completed
synchronization and a successful managed indexer execution without failed items
or document errors. It recursively lists the current OneLake files, follows
pagination, and checks that every file has a `doc_url` in the generated index.
Chunk counts and incremental processed counts are not used as file totals.
Files modified after the successful run began prevent completion until a later
scheduled run processes them. Empty folders are rejected rather than reported
as successfully indexed; indexer warnings are printed for review. Verification
confirms file coverage, not that every byte of text was extracted without truncation.

Rerunning with the same Search name reuses matching resources and monitors any
active indexing run. It never creates a second managed indexer or runs/resets
the existing indexer. Once coverage is verified, the script exits and reports
`VerifiedFileCount`; hourly scheduled indexing remains enabled. Missing files
continue to be polled until the timeout, which reports progress and leaves all
resources unchanged. New uploads may require waiting for the next hourly run.
`-WaitForIngestion:$false` explicitly skips monitoring and makes no completion
claim. The output includes the ingestion/indexer status, knowledge-base, and
retrieve URLs. Use `-WhatIf` for an offline preview without authentication,
prompts, or cloud changes.

Offline regression checks (all cloud calls are mocked):

```powershell
pwsh -NoProfile -File ./deployment/tests/create-insurance-business-knowledgebase.Tests.ps1
```

API references: [Managed OneLake knowledge sources](https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-onelake)
and [knowledge-source synchronization status](https://learn.microsoft.com/rest/api/searchservice/knowledge-sources/get-status?view=rest-searchservice-2026-04-01).

## Generate Policy PDFs and Upload to a Lakehouse

After running the populate script, generate policy documents directly from the
saved Azure SQL records and upload them to the same Fabric workspace:

```powershell
cd deployment/fabric
./create-insurance-customer-policy-documents.ps1 -Environment ins -Suffix 1
```

The script generates one two-page PDF for each existing seeded policy, normally
ten PDFs, then lists accessible workspaces for selection. Supply
`-WorkspaceId '<workspace-guid>'` to skip the picker. It creates or reuses the
exact-name **InsuranceCustomerPolicies** lakehouse and uploads the generated PDFs
to its **Files** root using OneLake's create/append/flush APIs. It verifies the
remote byte length after each upload, then updates that record's
`obj.InsurancePolicy.PolicyDocumentUrl` to the exact OneLake HTTPS file URL and
refreshes `UpdatedAtUtc` using the SQL server's UTC clock. The update matches both
policy ID and customer ID and fails unless exactly one row matches. It returns policy IDs, local paths,
workspace/lakehouse IDs, and OneLake URLs. Reuse matches both name and Lakehouse
type, so a same-name generated SQL analytics endpoint is not a collision.
Multiple matching lakehouses, or same-name items with no matching lakehouse,
stop the script without modifying those items.

Local PDFs are saved under `deployment/fabric/InsuranceCustomerPolicies/`, regardless
of the current working directory. File names include the policy number and stable
policy ID. Override the destination with `-OutputDirectory '<local-folder>'`.
Only files generated by this run are uploaded, not arbitrary files already in
that folder. Temporary HTML and isolated browser profiles are cleaned up.

```powershell
# Read SQL and generate local PDFs only; no Fabric access required.
./create-insurance-customer-policy-documents.ps1 -Environment ins -LocalOnly

# Regenerate documents and replace matching local and remote PDFs explicitly.
./create-insurance-customer-policy-documents.ps1 -Environment ins `
  -WorkspaceId '<workspace-guid>' -Overwrite

# Preview with no SQL, authentication, browser, file, or Fabric operations.
./create-insurance-customer-policy-documents.ps1 -Environment ins -WhatIf
```

Prerequisites for this document workflow:

- PowerShell 7+, Azure CLI signed in to the intended tenant, and SqlServer module 22+.
- Microsoft Edge or Google Chrome with headless printing enabled by local policy.
  The script detects standard Windows Edge/Chrome paths; use
  `-BrowserExecutable '<full-path-to-browser>'` for another installation.
  No Python, Fabric Python SDK, or PDF package installation is needed.
- SQL network access and an Entra principal with SELECT access to the four `obj`
  tables in `InsuranceCustomerBase`. Upload mode additionally requires UPDATE
  permission on `obj.InsurancePolicy.PolicyDocumentUrl` and `UpdatedAtUtc`.
  `-LocalOnly` does not update SQL and needs only SELECT access. The SQL server defaults to
  `sql-eia-{environment}-{suffix}`; `-SqlServerName` overrides it. The Windows
  ARM64 SqlClient workaround described below also applies to this demo script.
- For upload: active Fabric capacity, Contributor or higher in the target
  workspace, and tenant policy permitting external OneLake access. Lakehouse
  creation requires delegated `Lakehouse.ReadWrite.All` or `Item.ReadWrite.All`;
  workspace discovery requires `Workspace.Read.All` or `Workspace.ReadWrite.All`.
  Fabric management and OneLake use separate Fabric and Storage audience tokens.
  The script does not grant permissions or change capacity or networking.

Document generation reads only the ten stable demo policy IDs seeded by the
populate script. After verified uploads, only their document URLs and update
timestamps are changed. It reads persisted dates and financial amounts rather
than regenerating them. Missing policies produce a warning; zero policies stops
the script. Optional values are marked **Not recorded**. Customer names and other
database text are HTML-encoded before printing. PDFs are prominently marked
**fictional/demo only**, not proof of insurance. They reproduce the recorded
declarations but do not invent legal coverage terms absent from the database.

By default, an existing local PDF stops generation before replacing any local
file, and conditional remote creation prevents replacing an existing OneLake
file. Use `-Overwrite` only when replacement is intended. Uploads are sequential,
not transactional: after a failure, local PDFs and already-created lakehouses or
uploaded files remain. A failed append can leave an empty or incomplete remote
file; inspect it, correct the cause, and rerun with `-Overwrite`. After an async
creation timeout, check the workspace before rerunning. Entering `Q` at the
workspace picker keeps the local PDFs and performs no cloud writes.

SQL URLs are not updated for failed uploads, failed size verification, cancelled
workspace selection, `-LocalOnly`, or `-WhatIf`. If a SQL update fails after an
upload, the script stops and retains the PDF; inspect the database, fix SQL access
or the missing/mismatched row, then rerun with `-Overwrite`. Prior successful
uploads and SQL updates are not rolled back. If PDFs were uploaded by an earlier
version of this script, rerun with `-Overwrite` to upload again and synchronize
their database URLs. The stored OneLake URLs require authenticated access; they
are not public download links. The SQL mirror reflects the updates after its
normal replication delay.

The script does not publish an agent or index PDF contents. Uploading PDFs to
**Files** does not create lakehouse tables or
automatically make their text queryable by a Fabric data agent.

Offline verification from the repository root:

```powershell
pwsh -NoProfile -File ./deployment/tests/create-insurance-customer-policy-documents.Tests.ps1
# Also render actual two-page PDFs using the installed Windows Edge browser:
pwsh -NoProfile -File ./deployment/tests/create-insurance-customer-policy-documents.Tests.ps1 -RenderPdf
```

References: [Create Lakehouse REST API](https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/items/create-lakehouse),
[OneLake access and Storage-audience authentication](https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api),
and [ADLS append and flush](https://learn.microsoft.com/en-us/rest/api/storageservices/datalakestoragegen2/path/update).

## Create a Fabric Data Agent

After the mirror has replicated its tables, run the script to select a workspace
and then a supported data source from that workspace:

```powershell
cd deployment/fabric
./create-fabric-data-agent.ps1
```

The script lists accessible workspaces in the signed-in tenant, then lists supported
source items with their names, types, and IDs. Select each by number; enter `Q` at
either prompt to cancel. To skip the source picker, pass
`-DataSource 'InsuranceCustomerBase-ins-1'` or a source item GUID, not an Azure SQL
database or connection name. The source must be in the selected workspace. Use
`-WorkspaceId '<workspace-guid>'` to skip the workspace picker, `-AgentName 'InsuranceAssistant'`
to override the default `fws-da-<source-name>`, and `-Instructions '...'` to
customize agent instructions without an instruction prompt. `-WhatIf` makes no
remote calls. If the matching item is a single DataAgent, the script offers `T` to
test its existing draft without changing configuration or publication, `C` to
continue setup using that agent, or `Q` to cancel. Test mode accepts repeated
questions; press Enter to finish. Continue mode resumes table selection and
instruction setup without deleting or recreating the agent. To create a separate
agent instead, rerun with a different `-AgentName`. Other same-name item types or duplicate names
stop the script. Existing definitions and unrelated datasource settings are not replaced.

After selecting the source, the interactive workflow is:

1. List available tables and views, including schema names such as `obj.Customer`.
  Enter comma-separated numbers (for example `1,3`), `A` for all, or `Q` to stop.
  Asterisks mark current selections. At least one table must be explicitly chosen.
2. Enter replacement agent instructions, or press Enter to keep existing instructions
  (or the default for a new agent). Confirm before saving the draft. Unchosen tables
  in this source are deselected; selected tables include all columns.
3. Optionally enter a question to test the **draft**, review the displayed answer,
  and repeat. Press Enter to skip or finish testing. A failed last test blocks publication;
  the saved draft remains available for another run. A completed answer is not an
  automated correctness check: review it before approving publication.
4. Explicitly confirm publication with `Y`. Enter or `N` leaves the saved draft
  unpublished by this run. Publishing applies **all pending staging changes** on
  the agent, including edits to other sources. It does not publish to the Microsoft
  365 agent store or grant permissions.

Cancellation or an API failure does not roll back previously saved draft changes,
newly created agents, or datasource attachments. It does not trigger publication.
Table selection configures the agent's query context, not a security boundary;
source permissions remain authoritative. Stop concurrent editing while configuring
or publishing the agent. Use `-DraftOnly` for the previous source-bound-draft-only
behavior; that mode refuses to modify an existing same-name item.

### Optional Quick-Test Setup

Only the quick-test step needs Python. Use a Python **3.10-3.13** environment and
install Microsoft's preview SDK with its dependencies (headless inference requires
version `0.1.33a0` or newer; `0.1.36a0` is the documented version for this script):

```powershell
python -m pip install 'fabric-data-agent-sdk==0.1.36a0'
```

Use `-PythonExecutable '<path-to-python.exe>'` if the environment is not the `python`
on PATH. The SDK uses `AzureCliCredential` with the already signed-in CLI identity,
explicit workspace/agent IDs, and `ai_skill_stage="sandbox"`; it does not sign in
or grant permissions. Tests send the question and query the configured source through
Fabric. Missing dependencies, access failures, or incomplete answers fail the test.
Skip testing to configure and publish using PowerShell alone. Headless SDK inference
does not support workspace private-link routing; skip the local test in that case
and validate the draft from a supported Fabric environment before publishing.

Requires PowerShell 7+, Azure CLI signed in with `az login`, Contributor or higher
in the target workspace, access to the source, a supported Fabric capacity, and
the required data-agent/Copilot tenant settings. The REST API requires delegated
`Item.ReadWrite.All` for a user identity. The script does not change permissions,
tenant settings, capacity, or networking. Supported sources are Fabric
`MirroredDatabase`, `Lakehouse`, `Warehouse`, `KQLDatabase`, and `SemanticModel` items.

The source is attached to a draft using the documented Fabric item definition.
Configuration uses the public staged datasource, element, settings, and publish
REST APIs. These preview capabilities must be available in the target environment;
API failures stop the workflow rather than silently falling back to guessed endpoints.
The result includes workspace/source/agent IDs, selected table names, and `Published`
(whether **this run** published). Async operations are polled with bounded retries;
after a timeout, check Fabric before rerunning.

Offline verification:

```powershell
pwsh -NoProfile -File ./deployment/tests/create-fabric-data-agent.Tests.ps1
```

References: [Create Data Agent REST API](https://learn.microsoft.com/en-us/rest/api/fabric/dataagent/items/create-data-agent),
[Data Agent definition](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/data-agent-definition),
[Microsoft's DataAgent API specification and examples](https://github.com/microsoft/fabric-rest-api-specs/tree/main/dataAgent),
and [Fabric Data Agent SDK](https://pypi.org/project/fabric-data-agent-sdk/).

## Prerequisites

- PowerShell 7+, Azure CLI, and the `SqlServer` PowerShell module version 22+.
- On Windows ARM64, provisioning enables SqlClient managed networking before
  loading the SQL module to avoid missing native `Microsoft.Data.SqlClient.SNI.dll`
  dependencies. Microsoft documents this switch for testing/debugging only; use
  x64 PowerShell with working native SqlClient dependencies for production runs.
  See [SqlClient AppContext switches](https://learn.microsoft.com/en-us/sql/connect/ado-net/appcontext-switches#enable-managed-networking-on-windows).
  After a `TdsParser` initialization failure, restart PowerShell before rerunning;
  the failed initializer and networking setting are cached for the process.
  Dependency-loading failures now stop immediately instead of being retried as
  authentication/network propagation delays.
- Sign in with `az login` and select the intended subscription before running.
  The signed-in tenant and subscription are used; the script never switches them.
- Before SQL provisioning, the script checks `Microsoft.Sql` registration and,
  if needed, registers it with `--wait` and verifies completion. This can take
  several minutes and requires subscription-level provider-registration permission
  (included in Contributor and Owner). Already registered providers are left unchanged.
- The administrator needs Azure resource provisioning permissions and an Admin
  role in the specified Fabric workspace. The workspace must have active Fabric
  capacity and the tenant must permit mirroring and external OneLake access.
- New SQL servers use Entra-only authentication, with the signed-in user as Entra
  administrator and a system-assigned identity. For an existing server, the user
  must already have SQL administrative access. Existing administrators are not
  replaced. A user-assigned primary server identity is not supported by this script.
- New databases use **Standard S3 (100 DTUs), which is billable**. Lower DTU tiers
  do not support mirroring. Existing supported databases are not resized.
- SQL TCP access (port 1433) is required from both the provisioning machine and
  Fabric. Use an existing network path or pass your public IPv4 address to
  `-ClientIpAddress`; its temporary firewall rule is removed in `finally`.
  If the server has public network access disabled, firewall rules alone cannot
  provide access. Run from a network that can reach its private endpoint with
  private DNS resolution, or explicitly enable **Selected networks** under the
  SQL server's **Networking > Public access** settings and allow your client IP.
  The script never enables public network access automatically and stops without
  retrying when SQL explicitly denies public access. Fabric still needs its own
  persistent network path after schema setup.
- Fabric also needs persistent access. `-AllowAzureServices` explicitly enables
  the broad Azure-services firewall rule, which permits network connections from
  **all Azure tenants**, subject to SQL authentication. This rule remains in place.
  For private networking, supply an existing gateway-backed `-FabricConnectionId`
  and run the script from a machine that can reach the SQL private endpoint.

## Run

Omit `-WorkspaceId` to list all Fabric workspaces accessible to the signed-in user
in the current tenant, sorted by name with IDs to distinguish duplicate names.
Enter a workspace number, or `Q` to cancel before any resources are changed:

```powershell
.\deployment\fabric\create-insurance-customer-base-db.ps1 -Environment ins -Suffix 1
```

The list includes all accessible roles; visibility alone does not grant the Admin
permissions or active capacity required for provisioning. Workspace discovery uses
the paginated [Fabric List Workspaces API](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/list-workspaces),
which requires delegated `Workspace.Read.All` or `Workspace.ReadWrite.All` access.
For unattended runs, supply `-WorkspaceId '<fabric-workspace-guid>'` to skip selection.
`-WhatIf` skips discovery and prompting so it makes no cloud calls; without an ID,
the preview shows a workspace-selection placeholder.

When Get Workspace omits identity details, the script first searches Entra service
principals by the workspace's display name, for example `fws-eia-ins-1`. It reuses
a single enabled, exact-name match and resolves its application ID through Entra,
without attempting identity provisioning. Prefix-only matches are ignored. Duplicate
names, disabled identities, and invalid IDs stop setup. If no exact match exists,
the script attempts Fabric identity provisioning and refreshes workspace details.
The signed-in user needs permission to list and read service principals in Entra.

A name match alone cannot prove workspace association. Verify that the matching
Enterprise application is the workspace identity, especially after recreating it.
For ambiguous names or missing metadata, open **Workspace settings > Workspace
identity**, locate its associated **Entra Enterprise application**, and use that
service principal's **Object ID** (not the workspace ID, app registration object ID,
or application/client ID):

```powershell
.\deployment\fabric\create-insurance-customer-base-db.ps1 `
  -Environment ins -Suffix 1 -WorkspaceId '<fabric-workspace-guid>' `
  -WorkspaceIdentityObjectId '<service-principal-object-id>'
```

An explicit object ID takes precedence over name lookup. The script resolves its
application ID through Entra and skips identity provisioning.
You must verify the supplied identity belongs to this workspace; when Fabric omits
its identity metadata, the script cannot independently verify that association.
The signed-in user needs permission to read that service principal in Entra.

From the repository root, preview the resource names without any cloud calls:

```powershell
.\deployment\fabric\create-insurance-customer-base-db.ps1 `
    -Environment dev -Suffix 1 -WorkspaceId '<fabric-workspace-guid>' -WhatIf
```

For a dedicated demo workspace, explicitly opt in to the broad network rule and
SQL server identity workspace permission:

```powershell
.\deployment\fabric\create-insurance-customer-base-db.ps1 `
    -Environment dev -Suffix 1 -WorkspaceId '<fabric-workspace-guid>' `
    -ClientIpAddress '<your-public-ipv4>' -AllowAzureServices `
    -GrantSqlIdentityWorkspaceContributor
```

Omit `-GrantSqlIdentityWorkspaceContributor` for narrower permissions. On the first
run, the script creates the mirror, reports the SQL identity and mirrored item IDs,
and stops before starting replication. In Fabric, grant that SQL server identity
**Read and Write** permission on the mirrored item. Rerun with
`-SqlIdentityItemWriteGranted` to confirm that permission is in place. The script
does not validate item-level permissions; Fabric enforces them when replication starts.

By default, the script provisions a workspace identity if needed, creates its SQL
login and database user, grants the documented mirroring permissions, and creates
an encrypted workspace-identity connection. The login uses the alias
`{Entra-service-principal-display-name}-{workspace-guid}`, resolved by service
principal object ID, rather than assuming the workspace name matches. Azure SQL
requires the original Entra name as the prefix when using `WITH OBJECT_ID`.
The script validates the application ID, escapes SQL identifiers and literals,
and rejects aliases longer than SQL's 128-character limit without truncating the
original name. See [Microsoft's alias naming requirements](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-microsoft-entra-create-users-with-nonunique-names?view=azuresql).
Microsoft Entra server logins for Azure
SQL Database are currently in public preview. The Entra administrator must be able
to resolve that identity through Microsoft Graph. Allow new identities time to
propagate before rerunning if SQL cannot resolve them.

Alternatively, pass `-FabricConnectionId '<connection-guid>'` for an existing SQL
connection targeting this server and database. Configure that connection's SQL
principal and mirroring permissions beforehand. This avoids creating a workspace
identity connection and supports existing OAuth or gateway connections.

Use `-SqlServerName` to override the globally unique server name. The database
name remains `InsuranceCustomerBase`. Reruns reuse matching resources and reject conflicting
connections or mirror sources rather than overwriting them. Partial failures leave
provisioned resources in place for inspection and rerun; they are not deleted.

Existing resources named `CustomerBase` are not renamed or migrated. The scripts
target the new names and leave those older resources untouched.

## Populate Sample Data

After creating the schema, use `populate-insurance-customer-base-db.ps1` to insert ten
fictional customers, ten addresses, ten customer-address links, and ten policies
(personal auto/home and commercial insurance):

```powershell
.\deployment\fabric\populate-insurance-customer-base-db.ps1 -Environment dev -Suffix 1 -WhatIf
.\deployment\fabric\populate-insurance-customer-base-db.ps1 -Environment dev -Suffix 1
```

Use the same `-SqlServerName` override as provisioning when applicable. Requires
Azure CLI sign-in, SqlServer module 22+, and an existing SQL network path with
SELECT/INSERT access on all four tables. No Fabric workspace ID is needed.
This script does not change firewall rules or provision resources. If provisioning
used a temporary client IP rule, establish SQL network access again before seeding.

All inserts run in one transaction. Stable demo IDs allow reruns to skip existing
rows without updating or deleting data; partially missing demo rows are inserted.
Policies initially cover one year from the UTC execution date; reruns do not
refresh existing policies. Output reports the inserted row count for each table.
Emails and document URLs use `example.com`; documents are placeholders, not actual
PDFs. Password fields contain deliberately nonfunctional demo markers, not usable
credentials. These are sample records only, not real customer data.

Run offline checks with `deployment/tests/populate-insurance-customer-base-db.Tests.ps1`.
These mock authentication and SQL execution; actual database execution and
transaction/rerun behavior still need live SQL validation.

## Security And Verification

**All tables, including Customer password hashes and salts, are replicated.**
Source database security is not copied to Fabric. Restrict workspace/item access
before loading sensitive data. The optional Contributor grant covers the whole
workspace; use item-level Read and Write for a narrower scope.

The script returns the OneLake tables path, SQL analytics endpoint, and database
identifiers. `Running` means the mirroring process started, not that every table's
initial snapshot is complete. Check **Monitor replication** in Fabric before
depending on the replicated data.

Offline mocked tests, with no Azure/Fabric/SQL calls:

```powershell
.\deployment\tests\create-insurance-customer-base-db.Tests.ps1
```

References:

- [Azure SQL mirroring prerequisites and permissions](https://learn.microsoft.com/en-us/fabric/mirroring/azure-sql-database-tutorial)
- [Supported Azure SQL tiers](https://learn.microsoft.com/en-us/fabric/mirroring/azure-sql-database#tier-and-purchasing-model-support)
- [Fabric mirroring REST APIs](https://learn.microsoft.com/en-us/fabric/mirroring/mirrored-database-rest-api)
- [Mirrored database definition](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/mirrored-database-definition)
- [Create Fabric connection](https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/create-connection)
- [Azure SQL CREATE LOGIN syntax](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-login-transact-sql?view=azuresqldb-current)