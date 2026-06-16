#!/usr/bin/env bash
# =============================================================================
# Registers Content Understanding analyzer schemas. Mirrors
# 4.content-understanding-add-schema.ps1.
#
# Requires: bash 4+, az CLI, curl, jq.
#
# Usage:
#   ./4.content-understanding-add-schema.sh <suffix> [schema-folder]
# =============================================================================
set -uo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "[ERROR] Suffix is required." >&2
    echo "Usage: $0 <suffix> [schema-folder]" >&2
    exit 1
fi
SUFFIX="$1"
SCHEMA_FOLDER="${2:-}"

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] 'jq' is required (used for JSON manipulation)." >&2
    exit 1
fi

PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
API_VERSION="2025-11-01"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
if [[ -z "$SCHEMA_FOLDER" ]]; then
    SCHEMA_FOLDER="$SCRIPT_DIR/cu-schemas"
fi
KEY_VAULT_NAME="kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"

echo "============================================================"
echo " Content Understanding - Register Analyzer Schemas"
echo "============================================================"

echo "[INFO] Reading Content Understanding endpoint from Key Vault ($KEY_VAULT_NAME)..."
CU_ENDPOINT=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name ContentUnderstandingEndpoint --query value -o tsv 2>/dev/null || true)
if [[ -z "$CU_ENDPOINT" ]]; then
    echo "[ERROR] Failed to read ContentUnderstandingEndpoint from Key Vault." >&2
    exit 1
fi
CU_ENDPOINT="${CU_ENDPOINT%/}"
echo "[OK]   Endpoint: $CU_ENDPOINT"

echo "[INFO] Acquiring bearer token for Cognitive Services..."
TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>/dev/null || true)
if [[ -z "$TOKEN" ]]; then
    echo "[ERROR] Failed to acquire bearer token." >&2
    exit 1
fi
echo "[OK]   Token acquired"
echo ""

# -----------------------------------------------------------------------------
# List existing custom analyzers
# -----------------------------------------------------------------------------
echo "[INFO] Listing existing analyzers..."
LIST_URL="$CU_ENDPOINT/contentunderstanding/analyzers?api-version=$API_VERSION"
LIST_RESP=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$LIST_URL" 2>/dev/null || echo '{"value":[]}')
EXISTING_JSON=$(echo "$LIST_RESP" | jq '[.value[] | select(.analyzerId | startswith("prebuilt-") | not)]' 2>/dev/null || echo '[]')
EXISTING_COUNT=$(echo "$EXISTING_JSON" | jq 'length')

declare -A EXISTING_BASE   # analyzerId -> baseAnalyzerId
declare -A EXISTING_STATUS # analyzerId -> status
while IFS=$'\t' read -r ID BASE STATUS; do
    [[ -z "$ID" ]] && continue
    EXISTING_BASE["$ID"]="$BASE"
    EXISTING_STATUS["$ID"]="$STATUS"
done < <(echo "$EXISTING_JSON" | jq -r '.[] | [.analyzerId, (.baseAnalyzerId // ""), (.status // "")] | @tsv')

if (( EXISTING_COUNT > 0 )); then
    echo "[INFO] Found $EXISTING_COUNT custom analyzer(s):"
    for id in "${!EXISTING_BASE[@]}"; do
        echo "         - $id  (status: ${EXISTING_STATUS[$id]})"
    done
    echo ""
    read -r -p "Delete ALL custom analyzers and exit? (y/N): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        echo ""
        echo "[WARNING] This will permanently delete $EXISTING_COUNT custom analyzer(s). This action cannot be undone."
        read -r -p "Are you sure? Type 'yes' to confirm: " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "[INFO] Cancelled. No analyzers deleted."
            echo ""
        else
            for id in "${!EXISTING_BASE[@]}"; do
                echo "[INFO] Deleting analyzer '$id'..."
                DEL_URL="$CU_ENDPOINT/contentunderstanding/analyzers/$id?api-version=$API_VERSION"
                if curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" "$DEL_URL" >/dev/null 2>&1; then
                    echo "[OK]   Deleted '$id'"
                else
                    echo "[ERROR] Failed to delete '$id'" >&2
                fi
            done
            echo ""
            echo "[INFO] All custom analyzers deleted."
            echo "[INFO] Clearing ContentUnderstandingAnalyzers secret from Key Vault..."
            if az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name ContentUnderstandingAnalyzers --value '[]' --output none 2>/dev/null; then
                echo "[OK]   Secret 'ContentUnderstandingAnalyzers' cleared in $KEY_VAULT_NAME"
            else
                echo "[WARN] Failed to clear secret"
            fi
            exit 0
        fi
    fi
else
    echo "[INFO] No custom analyzers found."
fi
echo ""

# -----------------------------------------------------------------------------
# Validate schema folder
# -----------------------------------------------------------------------------
if [[ ! -d "$SCHEMA_FOLDER" ]]; then
    echo "[ERROR] Schema folder not found: $SCHEMA_FOLDER" >&2
    exit 1
fi
shopt -s nullglob
SCHEMA_FILES=("$SCHEMA_FOLDER"/*.json)
shopt -u nullglob
if (( ${#SCHEMA_FILES[@]} == 0 )); then
    echo "[ERROR] No .json files found in $SCHEMA_FOLDER" >&2
    exit 1
fi

echo "[INFO] Schema folder : $SCHEMA_FOLDER"
echo "[INFO] Schema files  : ${#SCHEMA_FILES[@]}"
echo ""

echo "[INFO] Reading completion model from Key Vault..."
COMPLETION_MODEL=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name ContentUnderstandingCompletionModel --query value -o tsv 2>/dev/null || true)
if [[ -z "$COMPLETION_MODEL" ]]; then
    echo "[ERROR] Failed to read ContentUnderstandingCompletionModel from Key Vault." >&2
    exit 1
fi
echo "[OK]   Completion model: $COMPLETION_MODEL"
echo ""

# -----------------------------------------------------------------------------
# Create analyzers
# -----------------------------------------------------------------------------
declare -a R_FILE R_ID R_BASE R_STATUS R_HTTP

for file in "${SCHEMA_FILES[@]}"; do
    fname=$(basename "$file")
    analyzer_id="${fname%.json}"
    echo "------------------------------------------------------------"

    if [[ -n "${EXISTING_BASE[$analyzer_id]+x}" ]]; then
        echo "[INFO] Analyzer '$analyzer_id' already exists (status: ${EXISTING_STATUS[$analyzer_id]})"
        read -r -p "       Replace it? (y/N): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo "[INFO] Deleting '$analyzer_id' before re-creating..."
            DEL_URL="$CU_ENDPOINT/contentunderstanding/analyzers/$analyzer_id?api-version=$API_VERSION"
            if curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" "$DEL_URL" >/dev/null 2>&1; then
                echo "[OK]   Deleted '$analyzer_id'"
                unset 'EXISTING_BASE[$analyzer_id]'
                unset 'EXISTING_STATUS[$analyzer_id]'
            else
                echo "[ERROR] Failed to delete '$analyzer_id'" >&2
                R_FILE+=("$analyzer_id"); R_ID+=("$analyzer_id"); R_BASE+=(""); R_STATUS+=("error"); R_HTTP+=("")
                continue
            fi
        else
            echo "[OK]   Keeping existing '$analyzer_id'"
            R_FILE+=("$analyzer_id"); R_ID+=("$analyzer_id"); R_BASE+=("${EXISTING_BASE[$analyzer_id]}"); R_STATUS+=("kept"); R_HTTP+=("")
            continue
        fi
    fi

    echo "[INFO] Creating analyzer '$analyzer_id' from $fname..."

    # Inject completion model where missing
    BODY=$(jq --arg cm "$COMPLETION_MODEL" '
        if .models == null then . + {models: {completion: $cm}}
        elif (.models.completion // null) == null then .models.completion = $cm
        else . end
    ' "$file") || {
        echo "[ERROR] Failed to parse $fname" >&2
        R_FILE+=("$analyzer_id"); R_ID+=("$analyzer_id"); R_BASE+=(""); R_STATUS+=("error"); R_HTTP+=("")
        continue
    }

    URL="$CU_ENDPOINT/contentunderstanding/analyzers/$analyzer_id?api-version=$API_VERSION"
    HEADERS_FILE=$(mktemp)
    BODY_OUT=$(curl -sS -D "$HEADERS_FILE" -o /tmp/cu-create-body.$$ -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data "$BODY" \
        "$URL")
    HTTP_CODE="$BODY_OUT"
    RESP_BODY=$(cat /tmp/cu-create-body.$$ 2>/dev/null || true)
    rm -f /tmp/cu-create-body.$$

    if [[ "$HTTP_CODE" == "409" ]]; then
        echo "[OK]   Analyzer '$analyzer_id' already exists (HTTP 409)"
        base="${EXISTING_BASE[$analyzer_id]:-}"
        R_FILE+=("$analyzer_id"); R_ID+=("$analyzer_id"); R_BASE+=("$base"); R_STATUS+=("kept"); R_HTTP+=("409")
        rm -f "$HEADERS_FILE"
        continue
    fi
    if [[ ! "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        echo "[ERROR] Failed to create analyzer '$analyzer_id': HTTP $HTTP_CODE" >&2
        if [[ -n "$RESP_BODY" ]]; then echo "[ERROR] Response: $RESP_BODY" >&2; fi
        R_FILE+=("$analyzer_id"); R_ID+=("$analyzer_id"); R_BASE+=(""); R_STATUS+=("error"); R_HTTP+=("$HTTP_CODE")
        rm -f "$HEADERS_FILE"
        continue
    fi
    echo "[OK]   HTTP $HTTP_CODE"

    # Look for Operation-Location header
    OP_LOC=$(grep -i '^Operation-Location:' "$HEADERS_FILE" | head -1 | sed -E 's/^[^:]+:[[:space:]]*//I' | tr -d '\r\n')
    rm -f "$HEADERS_FILE"
    OP_ID=""
    if [[ -n "$OP_LOC" && "$OP_LOC" =~ /operations/([^?]+) ]]; then
        OP_ID="${BASH_REMATCH[1]}"
    fi

    op_status="succeeded"
    if [[ -n "$OP_ID" ]]; then
        echo "[INFO] Polling operation '$OP_ID'..."
        POLL_URL="$CU_ENDPOINT/contentunderstanding/analyzers/$analyzer_id/operations/$OP_ID?api-version=$API_VERSION"
        op_status="running"
        for ((attempt=1; attempt<=30; attempt++)); do
            sleep 2
            POLL_RESP=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$POLL_URL" 2>/dev/null || echo '{}')
            op_status=$(echo "$POLL_RESP" | jq -r '.status // "running"')
            if [[ "$op_status" == "succeeded" || "$op_status" == "failed" || "$op_status" == "canceled" ]]; then
                break
            fi
            echo "       ... status: $op_status (attempt $attempt/30)"
        done
        if [[ "$op_status" == "succeeded" ]]; then
            echo "[OK]   Analyzer '$analyzer_id' provisioned successfully"
        else
            echo "[WARN] Analyzer '$analyzer_id' finished with status: $op_status"
        fi
    else
        echo "[OK]   Analyzer '$analyzer_id' created (synchronous)"
    fi

    api_id="$analyzer_id"
    api_base=""
    if [[ -n "$RESP_BODY" ]]; then
        x=$(echo "$RESP_BODY" | jq -r '.analyzerId // empty' 2>/dev/null || true)
        [[ -n "$x" ]] && api_id="$x"
        x=$(echo "$RESP_BODY" | jq -r '.baseAnalyzerId // empty' 2>/dev/null || true)
        [[ -n "$x" ]] && api_base="$x"
    fi

    R_FILE+=("$analyzer_id"); R_ID+=("$api_id"); R_BASE+=("$api_base"); R_STATUS+=("$op_status"); R_HTTP+=("$HTTP_CODE")
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Summary"
echo "============================================================"
printf '%-30s %-30s %-12s %s\n' "FileName" "AnalyzerId" "Status" "HttpCode"
printf '%-30s %-30s %-12s %s\n' "--------" "----------" "------" "--------"
ready=0
failed=0
total=${#R_FILE[@]}
for i in "${!R_FILE[@]}"; do
    printf '%-30s %-30s %-12s %s\n' "${R_FILE[$i]}" "${R_ID[$i]}" "${R_STATUS[$i]}" "${R_HTTP[$i]}"
    case "${R_STATUS[$i]}" in
        succeeded|kept) ((ready++)) || true ;;
        error)          ((failed++)) || true ;;
    esac
done
echo "[INFO] $ready/$total analyzers ready."
if (( failed > 0 )); then
    echo "[WARN] $failed analyzer(s) did not succeed - review errors above."
fi

# -----------------------------------------------------------------------------
# Store merged analyzer list in Key Vault
# -----------------------------------------------------------------------------
analyzer_type() {
    local b="$1"
    if [[ "$b" =~ ^prebuilt-(.+)$ ]]; then echo "${BASH_REMATCH[1]}"; else echo "$b"; fi
}

LIST_JSON="[]"
declare -A SEEN
# remaining existing (those not deleted)
for id in "${!EXISTING_BASE[@]}"; do
    t=$(analyzer_type "${EXISTING_BASE[$id]}")
    LIST_JSON=$(jq --arg id "$id" --arg t "$t" '. + [{id:$id,type:$t}]' <<< "$LIST_JSON")
    SEEN["$id"]=1
done
for i in "${!R_FILE[@]}"; do
    s="${R_STATUS[$i]}"
    [[ "$s" != "succeeded" && "$s" != "kept" ]] && continue
    id="${R_ID[$i]}"
    [[ -n "${SEEN[$id]+x}" ]] && continue
    t=$(analyzer_type "${R_BASE[$i]}")
    LIST_JSON=$(jq --arg id "$id" --arg t "$t" '. + [{id:$id,type:$t}]' <<< "$LIST_JSON")
    SEEN["$id"]=1
done

LIST_LEN=$(echo "$LIST_JSON" | jq 'length')
if (( LIST_LEN > 0 )); then
    SECRET_VAL=$(echo "$LIST_JSON" | jq -c '.')
    echo "[INFO] Storing ContentUnderstandingAnalyzers in Key Vault..."
    echo "       $SECRET_VAL"
    if az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name ContentUnderstandingAnalyzers --value "$SECRET_VAL" --output none 2>/dev/null; then
        echo "[OK]   Secret 'ContentUnderstandingAnalyzers' saved to $KEY_VAULT_NAME"
    else
        echo "[ERROR] Failed to store secret" >&2
        exit 1
    fi
fi
