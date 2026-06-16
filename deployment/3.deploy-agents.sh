#!/usr/bin/env bash
# =============================================================================
# Builds and provisions Azure AI Foundry agents.
# Mirrors 3.deploy-agents.ps1.
#
# Prompts the user to select which agent(s) to provision, gathers the agent
# instructions, builds each JAR with Maven (also updating project-lib/java via
# the -Dlibrary profile), then runs the provisioning main() to register the
# agent in Azure AI Foundry.
#
# Self-sufficient: grants the signed-in user the AI Foundry data-plane roles
# the agents API requires (so it does not depend on 6.operation-dev.sh).
#
# Requires: bash 4+, az CLI, mvn, java (JAVA_HOME), jq.
#
# Usage:
#   ./3.deploy-agents.sh <suffix>
#       [--environment ENV]              (default dev)
#       [--maven-timeout-minutes N]      (default 15, 0 disables)
# =============================================================================
set -uo pipefail

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
SUFFIX=""
ENVIRONMENT="${ENVIRONMENT:-}"
MAVEN_TIMEOUT_MIN=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment)            ENVIRONMENT="$2";       shift 2 ;;
        --maven-timeout-minutes)  MAVEN_TIMEOUT_MIN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,19p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$SUFFIX" ]]; then
                SUFFIX="$1"
            else
                echo "[ERROR] Unknown argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

command -v az  >/dev/null 2>&1 || { echo "[ERROR] Azure CLI is not installed." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "[ERROR] 'jq' is required." >&2; exit 1; }
command -v mvn >/dev/null 2>&1 || { echo "[ERROR] Maven (mvn) is not on PATH." >&2; exit 1; }

# -----------------------------------------------------------------------------
# Inputs (prompt for any not supplied)
# -----------------------------------------------------------------------------
read -r -p "Enter location [default: centralus, example: centralus]: " LOCATION_INPUT
LOCATION="$(echo "${LOCATION_INPUT:-centralus}" | tr '[:upper:]' '[:lower:]' | xargs)"

if [[ -z "${ENVIRONMENT// }" ]]; then
    read -r -p "Enter environment [default: dev, example: dev]: " ENV_INPUT
    ENVIRONMENT="$(echo "${ENV_INPUT:-dev}" | tr '[:upper:]' '[:lower:]' | xargs)"
else
    ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]' | xargs)"
fi

if [[ -z "${SUFFIX// }" ]]; then
    read -r -p "Enter suffix [default: 1, example: 1]: " SUFFIX_INPUT
    SUFFIX="$(echo "${SUFFIX_INPUT:-1}" | xargs)"
else
    SUFFIX="$(echo "$SUFFIX" | xargs)"
fi

PROJECT_NAME="${PROJECT_NAME:-eia}"

echo "[INFO] Deployment key: ${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX} (location: ${LOCATION})"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ResourceGroupName="rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
KeyVaultName="kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
AiFoundryName="oai-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
AiFoundryProjectName="proj-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
AGENTS_ROOT="$REPO_ROOT/insight/agents"
TMPDIR="${TMPDIR:-/tmp}"

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Agent Provisioning"
echo "[INFO] Project     : $PROJECT_NAME"
echo "[INFO] Environment : $ENVIRONMENT"
echo "[INFO] Suffix      : $SUFFIX"
echo "[INFO] ============================================================"
echo ""

acct_state="$(az account show --query state -o tsv 2>/dev/null || true)"
if [[ "$acct_state" != "Enabled" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2
    exit 1
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "[ERROR] JAVA_HOME is not set." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Helper: run Maven with an optional timeout, streaming output.
# -----------------------------------------------------------------------------
invoke_maven_package() {
    local source_dir="$1" label="$2" timeout_min="$3"; shift 3
    local extra_args=("$@")

    pushd "$source_dir" >/dev/null
    local rc=0
    if [[ "$timeout_min" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_min}m" mvn clean package -DskipTests --no-transfer-progress "${extra_args[@]}" || rc=$?
        if [[ $rc -eq 124 ]]; then
            popd >/dev/null
            echo "[ERROR] Maven build for $label exceeded the timeout of ${timeout_min} minute(s)." >&2
            return 1
        fi
    else
        mvn clean package -DskipTests --no-transfer-progress "${extra_args[@]}" || rc=$?
    fi
    popd >/dev/null

    if [[ $rc -ne 0 ]]; then
        echo "[ERROR] Maven build failed for $label with exit code $rc." >&2
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# STEP 1: Select which agent(s) to provision
# -----------------------------------------------------------------------------
echo "Which agent(s) do you want to provision?"
echo "  1. eia-email-reviewer"
echo "  2. All"
echo ""
echo "  You can enter a single number or comma-separated list (e.g. 1)"
echo ""

while true; do
    read -r -p "Enter selection(s): " RAW_INPUT
    IFS=',' read -r -a SELECTIONS <<< "$RAW_INPUT"
    cleaned=()
    all_valid=1
    for s in "${SELECTIONS[@]}"; do
        s="$(echo "$s" | xargs)"
        [[ -z "$s" ]] && continue
        if [[ "$s" != "1" && "$s" != "2" ]]; then all_valid=0; fi
        cleaned+=("$s")
    done
    if [[ ${#cleaned[@]} -gt 0 && $all_valid -eq 1 ]]; then break; fi
    echo "[ERROR] Please enter 1, 2, or a comma-separated list."
done

SELECTED_ALL=0
for s in "${cleaned[@]}"; do [[ "$s" == "2" ]] && SELECTED_ALL=1; done

# Provision eia-email-reviewer when '1' or 'All' (2) is selected.
WANT_EMAIL_REVIEWER=0
for s in "${cleaned[@]}"; do [[ "$s" == "1" || "$s" == "2" ]] && WANT_EMAIL_REVIEWER=1; done

# Build the target list (parallel arrays: label / source dir / instructions).
TARGET_LABELS=()
TARGET_DIRS=()
TARGET_INSTRUCTIONS=()

# -----------------------------------------------------------------------------
# STEP 2: Gather agent instructions
# -----------------------------------------------------------------------------
echo ""
echo ">>> Step 2: Agent instructions"
echo "[INFO] Instructions become the system prompt registered with the agent in Azure AI Foundry."
echo ""

# Default instructions per agent label. Add a new case here when a new agent is added.
default_instructions_for() {
    case "$1" in
        eia-email-reviewer)
            echo "You are a helpful assistant, who can read user data, detect anomalies, missing data, recommend action items, classify content into a multi-class hierarchy, summarize content, and provide insights."
            ;;
        *)
            echo ""
            ;;
    esac
}

add_target() {
    local label="$1"
    local source_dir="$AGENTS_ROOT/$label"
    local default_instr; default_instr="$(default_instructions_for "$label")"
    if [[ -z "$default_instr" ]]; then
        echo "[ERROR] No default instructions configured for agent '$label'. Add it to default_instructions_for() in this script." >&2
        exit 1
    fi

    local instr="$default_instr"
    if [[ $SELECTED_ALL -eq 1 ]]; then
        echo "[INFO] '$label' selected via 'All' - using default instructions."
    else
        echo "Default instructions for '$label':"
        echo "  $default_instr"
        read -r -p "Press [Enter] to keep default, or type edited instructions: " INSTR_INPUT
        INSTR_INPUT="$(echo "$INSTR_INPUT" | xargs)"
        [[ -n "$INSTR_INPUT" ]] && instr="$INSTR_INPUT"
    fi

    TARGET_LABELS+=("$label")
    TARGET_DIRS+=("$source_dir")
    TARGET_INSTRUCTIONS+=("$instr")
}

if [[ $WANT_EMAIL_REVIEWER -eq 1 ]]; then
    add_target "eia-email-reviewer"
fi

# -----------------------------------------------------------------------------
# STEP 3: Confirm
# -----------------------------------------------------------------------------
read -r -p "Press [Enter] to accept Resource Group '$ResourceGroupName', or type a new name to override: " CONFIRM_RG
CONFIRM_RG="$(echo "$CONFIRM_RG" | xargs)"
if [[ -n "$CONFIRM_RG" ]]; then
    ResourceGroupName="$CONFIRM_RG"
    echo "[INFO] Using overridden Resource Group: $ResourceGroupName"
fi

echo ""
echo "[INFO] ============================================================"
echo "[INFO] About to provision:"
for i in "${!TARGET_LABELS[@]}"; do
    echo "  ${TARGET_LABELS[$i]}"
    echo "    Instructions: ${TARGET_INSTRUCTIONS[$i]}"
done
echo "  Resource Group : $ResourceGroupName"
echo "  Key Vault      : $KeyVaultName"
echo "[INFO] ============================================================"
echo ""

read -r -p "Proceed with provisioning? [Y/n]: " GO
if [[ "$GO" =~ ^[Nn] ]]; then
    echo "[INFO] Provisioning cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# STEP 4: Resolve Key Vault URL
# -----------------------------------------------------------------------------
echo ""
echo ">>> Step 4: Resolving Key Vault URL"

KV_URL="$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query properties.vaultUri -o tsv 2>/dev/null || true)"
if [[ -z "$KV_URL" ]]; then
    echo "[ERROR] Could not retrieve Key Vault '$KeyVaultName' in '$ResourceGroupName'. Verify the name/suffix and that you are logged in." >&2
    exit 1
fi
KV_URL="${KV_URL%/}"
echo "[OK] Key Vault URL: $KV_URL"

# -----------------------------------------------------------------------------
# STEP 4b: Ensure current-user AI Foundry RBAC (self-sufficient provisioning)
# -----------------------------------------------------------------------------
# The provisioner runs as the signed-in user (DefaultAzureCredential) and
# registers the agent via the AI Foundry agents API. These are the data-plane
# roles that API needs, so this script does NOT depend on 6.operation-dev.sh.
echo ""
echo ">>> Step 4b: Ensuring AI Foundry RBAC for current user"

CURRENT_USER_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -z "$CURRENT_USER_ID" ]]; then
    echo "[ERROR] Could not determine the signed-in user. Run 'az login' first." >&2
    exit 1
fi
SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
AI_FOUNDRY_ID="$(az cognitiveservices account show --name "$AiFoundryName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)"

# Idempotent role assignment for the signed-in user. Accepts a role name or a
# role-definition ID (custom roles must be referenced by ID at sub-resource scope).
add_current_user_role() {
    local role="$1" scope="$2" label="$3"
    local existing
    existing="$(az role assignment list --assignee "$CURRENT_USER_ID" --role "$role" --scope "$scope" --query '[0].id' -o tsv 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        echo "  [OK] $label - already assigned"
        return
    fi
    az role assignment create --assignee "$CURRENT_USER_ID" --role "$role" --scope "$scope" --output none 2>/dev/null || true
    echo "  [SUCCESS] $label - assigned"
}

if [[ -z "$AI_FOUNDRY_ID" ]]; then
    echo "[WARNING] AI Foundry account '$AiFoundryName' not found; skipping RBAC grants. Agent provisioning may fail."
else
    AI_FOUNDRY_PROJECT_ID="${AI_FOUNDRY_ID}/projects/${AiFoundryProjectName}"

    # Built-in data-plane roles (account scope) + Agents API access (account + project)
    add_current_user_role "Cognitive Services User"        "$AI_FOUNDRY_ID"         "Cognitive Services User (account)"
    add_current_user_role "Cognitive Services OpenAI User" "$AI_FOUNDRY_ID"         "Cognitive Services OpenAI User (account)"
    add_current_user_role "Azure AI Developer"             "$AI_FOUNDRY_ID"         "Azure AI Developer (account)"
    add_current_user_role "Azure AI Developer"             "$AI_FOUNDRY_PROJECT_ID" "Azure AI Developer (project)"

    # Custom role: Azure AI Developer covers OpenAI/* but not the AIServices/*
    # data actions used by the agents endpoint. Create it if absent.
    EIA_AGENT_WRITER_ROLE="EIA AI Foundry Agent Writer"
    existing_custom_role="$(az role definition list --name "$EIA_AGENT_WRITER_ROLE" --query '[0].name' -o tsv 2>/dev/null || true)"
    if [[ -z "$existing_custom_role" ]]; then
        echo "  [INFO] Creating custom role '$EIA_AGENT_WRITER_ROLE'"
        tmp_role_file="$TMPDIR/eia-custom-role-$(date +%s)-$$.json"
        jq -n \
            --arg name "$EIA_AGENT_WRITER_ROLE" \
            --arg desc "Grants AIServices/* data-plane access needed for AI Foundry agents API (AIServices/* absent from Azure AI Developer role definition)" \
            --arg scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${ResourceGroupName}" \
            '{Name:$name, Description:$desc, Actions:[], DataActions:["Microsoft.CognitiveServices/accounts/AIServices/*"], AssignableScopes:[$scope]}' \
            > "$tmp_role_file"
        az role definition create --role-definition "@$tmp_role_file" --output none 2>/dev/null || true
        rm -f "$tmp_role_file"
    fi
    # Resolve by ID — az cannot resolve custom role names at deep sub-resource scopes.
    EIA_AGENT_WRITER_ROLE_ID="$(az role definition list --name "$EIA_AGENT_WRITER_ROLE" --query '[0].id' -o tsv 2>/dev/null | xargs || true)"
    if [[ -n "$EIA_AGENT_WRITER_ROLE_ID" ]]; then
        add_current_user_role "$EIA_AGENT_WRITER_ROLE_ID" "$AI_FOUNDRY_ID"         "$EIA_AGENT_WRITER_ROLE (account)"
        add_current_user_role "$EIA_AGENT_WRITER_ROLE_ID" "$AI_FOUNDRY_PROJECT_ID" "$EIA_AGENT_WRITER_ROLE (project)"
    else
        echo "  [WARNING] Could not resolve custom role '$EIA_AGENT_WRITER_ROLE'; agent registration may fail."
    fi

    echo "  [INFO] RBAC propagation may take up to 5 minutes if roles were just created."
fi

# -----------------------------------------------------------------------------
# STEP 5: Build and provision each agent
# -----------------------------------------------------------------------------
echo ""
echo ">>> Step 5: Build and provision agents"

JAVA_EXE="$JAVA_HOME/bin/java"
[[ -x "$JAVA_EXE" ]] || JAVA_EXE="java"

PROVISION_ERRORS=()

if [[ "$MAVEN_TIMEOUT_MIN" -gt 0 ]]; then
    echo "[INFO] Maven timeout: ${MAVEN_TIMEOUT_MIN} minute(s)."
else
    echo "[INFO] Maven timeout disabled."
fi

for i in "${!TARGET_LABELS[@]}"; do
    LABEL="${TARGET_LABELS[$i]}"
    SOURCE_DIR="${TARGET_DIRS[$i]}"
    INSTRUCTIONS="${TARGET_INSTRUCTIONS[$i]}"

    echo ""
    echo "[INFO] ---- Agent: $LABEL ----"

    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo "[ERROR] Source directory not found: $SOURCE_DIR" >&2
        PROVISION_ERRORS+=("$LABEL"); continue
    fi
    if [[ ! -f "$SOURCE_DIR/pom.xml" ]]; then
        echo "[ERROR] pom.xml not found in: $SOURCE_DIR" >&2
        PROVISION_ERRORS+=("$LABEL"); continue
    fi

    # Maven build — -Dlibrary also copies the thin JAR to project-lib/java
    echo "[INFO] Building $LABEL with Maven..."
    if ! invoke_maven_package "$SOURCE_DIR" "$LABEL" "$MAVEN_TIMEOUT_MIN" "-Dlibrary"; then
        PROVISION_ERRORS+=("$LABEL"); continue
    fi
    echo "[SUCCESS] Maven build completed for $LABEL"

    # Locate the executable fat JAR produced by maven-shade-plugin (newest first)
    JAR_FILE="$(find "$SOURCE_DIR/target" -maxdepth 1 -type f -name '*-exec.jar' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
    if [[ -z "$JAR_FILE" ]]; then
        echo "[ERROR] Executable JAR (*-exec.jar) not found under $SOURCE_DIR/target" >&2
        PROVISION_ERRORS+=("$LABEL"); continue
    fi

    JAR_HASH=""
    if command -v sha256sum >/dev/null 2>&1; then
        JAR_HASH="$(sha256sum "$JAR_FILE" 2>/dev/null | cut -d' ' -f1)"
    fi
    if [[ -n "$JAR_HASH" ]]; then
        echo "[INFO] Provisioning with: $(basename "$JAR_FILE") (SHA256: $JAR_HASH)"
    else
        echo "[INFO] Provisioning with: $(basename "$JAR_FILE")"
    fi

    # Run provisioning — main(keyVaultUrl, instructions...)
    echo "[INFO] Registering agent in Azure AI Foundry..."
    if ! "$JAVA_EXE" -jar "$JAR_FILE" "$KV_URL" "$INSTRUCTIONS"; then
        echo "[ERROR] Provisioning failed for $LABEL" >&2
        PROVISION_ERRORS+=("$LABEL"); continue
    fi
    echo "[SUCCESS] Agent provisioned: $LABEL"
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Provisioning Summary"
echo "[INFO] ============================================================"

if [[ ${#PROVISION_ERRORS[@]} -eq 0 ]]; then
    echo "[SUCCESS] All agents provisioned successfully."
else
    echo "[WARNING] The following agents failed to provision:"
    for err in "${PROVISION_ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi
