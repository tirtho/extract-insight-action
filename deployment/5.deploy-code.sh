#!/usr/bin/env bash
# =============================================================================
# Builds and deploys Azure Function apps and the Spring Boot web app to Azure.
# Mirrors 5.deploy-code.ps1.
#
# Requires: bash 4+, az CLI, mvn, curl, zip, sha256sum.
#
# Usage:
#   ./5.deploy-code.sh <suffix>
#       [--maven-timeout-minutes N]      (default 15, 0 disables)
#       [--retry-count N]                (default 3)
#       [--retry-delay-seconds N]        (default 10)
#       [--web-app-deploy-timeout-minutes N] (default 20)
# =============================================================================
set -uo pipefail

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
SUFFIX=""
MAVEN_TIMEOUT_MIN=15
RETRY_COUNT=3
RETRY_DELAY_SECONDS=10
WEBAPP_DEPLOY_TIMEOUT_MIN=20

while [[ $# -gt 0 ]]; do
    case "$1" in
        --maven-timeout-minutes)        MAVEN_TIMEOUT_MIN="$2";          shift 2 ;;
        --retry-count)                   RETRY_COUNT="$2";                shift 2 ;;
        --retry-delay-seconds)           RETRY_DELAY_SECONDS="$2";        shift 2 ;;
        --web-app-deploy-timeout-minutes) WEBAPP_DEPLOY_TIMEOUT_MIN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0"
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

if [[ -z "$SUFFIX" ]]; then
    echo "[ERROR] Suffix is required." >&2
    echo "Usage: $0 <suffix> [options]" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration (mirrors 1.deploy-infrastructure.sh naming conventions)
# -----------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJ_CLEAN="${PROJECT_NAME//-/}"
ResourceGroupName="${RESOURCE_GROUP_NAME:-rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
FuncMailboxName="${FUNCTION_APP_MAILBOX_NAME:-func-mailbox-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
FuncQueueDbName="${FUNCTION_APP_QUEUE_DB_NAME:-func-queuedb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
FuncCuQueueDbName="${FUNCTION_APP_CU_QUEUE_DB_NAME:-func-cuqueuedb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
StorageAccountName="${STORAGE_ACCOUNT_NAME:-st${PROJ_CLEAN}${ENVIRONMENT}${SUFFIX}}"
WebAppName="${WEB_APP_NAME:-app-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
FUNCTIONS_ROOT="$REPO_ROOT/extract/functions"
UI_ROOT="$REPO_ROOT/insight/ui"

TMPDIR="${TMPDIR:-/tmp}"

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Application Code Deployment"
echo "[INFO] Project     : $PROJECT_NAME"
echo "[INFO] Environment : $ENVIRONMENT"
echo "[INFO] Suffix      : $SUFFIX"
echo "[INFO] Retry Count : $RETRY_COUNT"
echo "[INFO] Retry Delay : $RETRY_DELAY_SECONDS second(s)"
echo "[INFO] WebApp Deploy Timeout : $WEBAPP_DEPLOY_TIMEOUT_MIN minute(s)"
echo "[INFO] ============================================================"
echo ""

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "[ERROR] Azure CLI is not installed." >&2; exit 1; }
command -v mvn >/dev/null 2>&1 || { echo "[ERROR] Maven (mvn) is not on PATH." >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "[ERROR] 'zip' is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ERROR] 'curl' is required." >&2; exit 1; }
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "[ERROR] sha256sum or shasum is required." >&2; exit 1
fi
if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "[ERROR] JAVA_HOME is not set." >&2; exit 1
fi
if ! state=$(az account show --query state -o tsv 2>/dev/null) || [[ "$state" != "Enabled" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2; exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
sha256_file() {
    local f="$1"
    [[ ! -f "$f" ]] && return
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print toupper($1)}'
    else
        shasum -a 256 "$f" | awk '{print toupper($1)}'
    fi
}

ensure_function_host_settings() {
    local app="$1" rg="$2" sa="$3"
    echo "[INFO] Ensuring required Functions host settings on $app..."
    if ! az functionapp config appsettings set \
            --name "$app" --resource-group "$rg" \
            --settings "AzureWebJobsStorage__accountName=$sa" \
            --output none 2>/tmp/fhs-err.$$; then
        echo "[ERROR] Failed to set required app settings on $app:" >&2
        cat /tmp/fhs-err.$$ >&2 || true
        rm -f /tmp/fhs-err.$$
        return 1
    fi
    rm -f /tmp/fhs-err.$$
    return 0
}

# Run mvn with timeout, streaming output. Returns exit code.
invoke_maven_package() {
    local source_dir="$1" label="$2" timeout_min="$3" skip_clean="$4"
    local args=()
    if [[ "$skip_clean" == "1" ]]; then
        args=(package -DskipTests --no-transfer-progress)
    else
        args=(clean package -DskipTests --no-transfer-progress)
    fi
    if [[ "$timeout_min" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
        ( cd "$source_dir" && timeout "${timeout_min}m" mvn "${args[@]}" )
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            echo "[ERROR] Maven build for $label exceeded the timeout of ${timeout_min} minute(s)." >&2
            return 1
        fi
        return $rc
    else
        ( cd "$source_dir" && mvn "${args[@]}" )
        return $?
    fi
}

# Returns 0 when SCM has no active deployments
wait_for_scm_idle() {
    local scm_host="$1" arm_token="$2" label="$3"
    local max=60 i
    for (( i=1; i<=max; i++ )); do
        body=$(curl -fsS --max-time 30 -H "Authorization: Bearer $arm_token" \
            "https://$scm_host/api/deployments" 2>/dev/null || echo "")
        if [[ -n "$body" ]]; then
            # Active deployments are entries with .complete != true
            active=$(echo "$body" | jq -r '[.[] | select(.complete != true) | .id] | join(", ")' 2>/dev/null || echo "")
            if [[ -z "$active" ]]; then
                return 0
            fi
            echo "[INFO] Waiting for active deployment(s) on $label to finish: $active"
        else
            echo "[WARNING] Could not query current SCM deployments for $label; retrying..."
        fi
        sleep "$RETRY_DELAY_SECONDS"
    done
    return 1
}

# -----------------------------------------------------------------------------
# Step 1: select workloads
# -----------------------------------------------------------------------------
echo "Which workload(s) do you want to deploy?"
echo "  1. mailbox-to-queue"
echo "  2. queue-to-db"
echo "  3. cu-queue-to-db"
echo "  4. insight-ui web app"
echo "  5. All"
echo ""
echo "  You can enter a single number or comma-separated list (e.g. 1,3)"
echo ""

SELECTIONS=()
while true; do
    read -r -p "Enter selection(s): " raw
    raw="${raw//[[:space:]]/}"
    IFS=',' read -ra parts <<< "$raw"
    SELECTIONS=()
    valid=1
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue
        case "$p" in
            1|2|3|4|5) SELECTIONS+=("$p") ;;
            *) valid=0; break ;;
        esac
    done
    if [[ $valid -eq 1 && ${#SELECTIONS[@]} -gt 0 ]]; then break; fi
    echo "[ERROR] Please enter 1, 2, 3, 4, 5, or a comma-separated list (e.g. 1,4)."
done

# Expand 5 → 1,2,3,4
expanded=()
for s in "${SELECTIONS[@]}"; do
    if [[ "$s" == "5" ]]; then
        expanded=(1 2 3 4)
        break
    fi
    expanded+=("$s")
done
# Dedupe
declare -A SEEN_SEL
SELECTIONS=()
for s in "${expanded[@]}"; do
    if [[ -z "${SEEN_SEL[$s]+x}" ]]; then SELECTIONS+=("$s"); SEEN_SEL[$s]=1; fi
done

# Build target arrays in order
T_LABEL=()
T_APP=()
T_DIR=()
T_KIND=()

for s in "${SELECTIONS[@]}"; do
    case "$s" in
        1) T_LABEL+=("mailbox-to-queue"); T_APP+=("$FuncMailboxName");   T_DIR+=("$FUNCTIONS_ROOT/mailbox-to-queue"); T_KIND+=("function") ;;
        2) T_LABEL+=("queue-to-db");      T_APP+=("$FuncQueueDbName");   T_DIR+=("$FUNCTIONS_ROOT/queue-to-db");      T_KIND+=("function") ;;
        3) T_LABEL+=("cu-queue-to-db");   T_APP+=("$FuncCuQueueDbName"); T_DIR+=("$FUNCTIONS_ROOT/cu-queue-to-db");   T_KIND+=("function") ;;
        4) T_LABEL+=("insight-ui");       T_APP+=("$WebAppName");        T_DIR+=("$UI_ROOT");                          T_KIND+=("webapp")   ;;
    esac
done

# -----------------------------------------------------------------------------
# Step 2: confirm / override
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] Derived deployment targets:"
for i in "${!T_LABEL[@]}"; do
    printf "  %-20s -> %s [%s]\n" "${T_LABEL[$i]}" "${T_APP[$i]}" "${T_KIND[$i]}"
done
echo "  Resource Group: $ResourceGroupName"
echo ""

if [[ ${#T_LABEL[@]} -eq 1 ]]; then
    read -r -p "Press [Enter] to accept app name '${T_APP[0]}', or type a new name to override: " override
    override="${override#"${override%%[![:space:]]*}"}"; override="${override%"${override##*[![:space:]]}"}"
    if [[ -n "$override" ]]; then
        T_APP[0]="$override"
        echo "[INFO] Using overridden app name: $override"
    fi
fi

read -r -p "Press [Enter] to accept Resource Group '$ResourceGroupName', or type a new name to override: " override
override="${override#"${override%%[![:space:]]*}"}"; override="${override%"${override##*[![:space:]]}"}"
if [[ -n "$override" ]]; then
    ResourceGroupName="$override"
    echo "[INFO] Using overridden Resource Group: $ResourceGroupName"
fi

echo ""
echo "[INFO] ============================================================"
echo "[INFO] About to deploy:"
for i in "${!T_LABEL[@]}"; do
    printf "  %-20s -> %s [%s]\n" "${T_LABEL[$i]}" "${T_APP[$i]}" "${T_KIND[$i]}"
done
echo "  Resource Group: $ResourceGroupName"
echo "[INFO] ============================================================"
echo ""

read -r -p "Proceed with deployment? [Y/n]: " go
case "$go" in
    n|N|no|No|NO) echo "[INFO] Deployment cancelled."; exit 0 ;;
esac

# -----------------------------------------------------------------------------
# Step 3+4: build and deploy
# -----------------------------------------------------------------------------
DEPLOYMENT_ERRORS=()

for i in "${!T_LABEL[@]}"; do
    label="${T_LABEL[$i]}"
    app="${T_APP[$i]}"
    sdir="${T_DIR[$i]}"
    kind="${T_KIND[$i]}"

    echo ""
    echo "[INFO] ---- Deploying: $label ----"

    if [[ ! -d "$sdir" ]]; then
        echo "[ERROR] Source directory not found: $sdir" >&2
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi
    if [[ ! -f "$sdir/pom.xml" ]]; then
        echo "[ERROR] pom.xml not found in: $sdir" >&2
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi

    echo "[INFO] Building $label with Maven..."
    if [[ "$MAVEN_TIMEOUT_MIN" -gt 0 ]]; then
        echo "[INFO] Maven timeout for this build: $MAVEN_TIMEOUT_MIN minute(s)."
    else
        echo "[INFO] Maven timeout disabled for this build."
    fi
    skip_clean=0
    [[ "$kind" == "webapp" ]] && skip_clean=1
    if ! invoke_maven_package "$sdir" "$label" "$MAVEN_TIMEOUT_MIN" "$skip_clean"; then
        echo "[ERROR] Maven build failed for $label" >&2
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi
    echo "[SUCCESS] Maven build completed for $label"

    if [[ "$kind" == "webapp" ]]; then
        # Locate newest .jar in target (excluding *.original)
        jar=""
        while IFS= read -r f; do
            [[ "$f" == *.original ]] && continue
            jar="$f"
            break
        done < <(ls -1t "$sdir/target"/*.jar 2>/dev/null || true)
        if [[ -z "$jar" ]]; then
            echo "[ERROR] Spring Boot JAR not found under $sdir/target" >&2
            DEPLOYMENT_ERRORS+=("$label"); continue
        fi
        h=$(sha256_file "$jar")
        [[ -n "$h" ]] && echo "[INFO] Deploying artifact: $(basename "$jar") (SHA256: $h)"

        echo "[INFO] Deploying web app JAR to $app..."
        DEPLOY_LOG=$(mktemp)
        # --async returns once the file uploads
        if command -v timeout >/dev/null 2>&1; then
            timeout "${WEBAPP_DEPLOY_TIMEOUT_MIN}m" \
                az webapp deploy --name "$app" --resource-group "$ResourceGroupName" \
                    --src-path "$jar" --type jar --clean true --async true >"$DEPLOY_LOG" 2>&1
            rc=$?
        else
            az webapp deploy --name "$app" --resource-group "$ResourceGroupName" \
                --src-path "$jar" --type jar --clean true --async true >"$DEPLOY_LOG" 2>&1
            rc=$?
        fi
        cat "$DEPLOY_LOG" || true
        rm -f "$DEPLOY_LOG"
        if [[ $rc -ne 0 ]]; then
            echo "[ERROR] Web app deployment failed for $label (exit $rc)" >&2
            DEPLOYMENT_ERRORS+=("$label"); continue
        fi
        echo "[SUCCESS] JAR deployed for $label - waiting for site to come up..."

        host=$(az webapp show --name "$app" --resource-group "$ResourceGroupName" --query defaultHostName -o tsv 2>/dev/null || true)
        if [[ -n "$host" ]]; then
            url="https://$host"
            echo "[INFO] Web app URL: $url"
            poll_start=$(date +%s)
            poll_deadline=$(( poll_start + WEBAPP_DEPLOY_TIMEOUT_MIN * 60 ))
            poll_interval=15
            ready=0
            while (( $(date +%s) < poll_deadline )); do
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo "000")
                if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then
                    echo "[SUCCESS] App is responding (HTTP $code)."
                    ready=1
                    break
                fi
                elapsed=$(( $(date +%s) - poll_start ))
                echo "[INFO] App not yet ready (${elapsed}s elapsed, last HTTP $code), retrying in ${poll_interval}s..."
                sleep $poll_interval
            done
            if [[ $ready -eq 0 ]]; then
                echo "[WARNING] App did not respond within $WEBAPP_DEPLOY_TIMEOUT_MIN min. Check Azure portal for status."
            fi
        fi
        continue
    fi

    # Function app: locate staging directory
    staging_base="$sdir/target/azure-functions"
    staging_dir=""
    if [[ -d "$staging_base" ]]; then
        for d in "$staging_base"/*/; do
            staging_dir="${d%/}"
            break
        done
    fi
    if [[ -z "$staging_dir" || ! -d "$staging_dir" ]]; then
        echo "[ERROR] Staging directory not found under $staging_base" >&2
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi
    echo "[INFO] Staging directory: $staging_dir"

    zip_path="$TMPDIR/$app-deployment.zip"
    rm -f "$zip_path"
    ( cd "$staging_dir" && zip -rq "$zip_path" . )
    echo "[INFO] Created deployment package: $zip_path"
    h=$(sha256_file "$zip_path")
    [[ -n "$h" ]] && echo "[INFO] Deployment package SHA256: $h"

    if ! ensure_function_host_settings "$app" "$ResourceGroupName" "$StorageAccountName"; then
        rm -f "$zip_path"
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi

    arm_token=$(az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$arm_token" ]]; then
        echo "[ERROR] Failed to obtain ARM access token." >&2
        rm -f "$zip_path"
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi

    scm_host="$app.scm.azurewebsites.net"

    if ! wait_for_scm_idle "$scm_host" "$arm_token" "$label"; then
        echo "[ERROR] Timed out waiting for existing deployment(s) to finish on $label before starting a new deploy." >&2
        rm -f "$zip_path"
        DEPLOYMENT_ERRORS+=("$label"); continue
    fi

    deploy_ok=0
    deploy_status="unknown"
    recorded=0

    for (( attempt=1; attempt<=RETRY_COUNT; attempt++ )); do
        echo "[INFO] Deploying package to $app via OneDeploy (SCM) (attempt $attempt/$RETRY_COUNT)..."
        resp_file=$(mktemp)
        http_code=$(curl -sS -o "$resp_file" -w '%{http_code}' --max-time 120 \
            -X POST \
            -H "Authorization: Bearer $arm_token" \
            -H "Content-Type: application/zip" \
            --data-binary "@$zip_path" \
            "https://$scm_host/api/publish?type=zip&async=true" || echo "000")
        if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            echo "[ERROR] Failed to initiate deployment for $label (HTTP $http_code)" >&2
            cat "$resp_file" >&2 || true
            rm -f "$resp_file"
            DEPLOYMENT_ERRORS+=("$label"); recorded=1
            break
        fi
        deploy_id=$(cat "$resp_file" | tr -d '"' | tr -d '[:space:]')
        rm -f "$resp_file"
        echo "[INFO] Deployment accepted (id: $deploy_id). Polling for completion..."

        for (( poll=0; poll<60; poll++ )); do
            sleep "$RETRY_DELAY_SECONDS"
            poll_body=$(curl -fsS --max-time 30 -H "Authorization: Bearer $arm_token" \
                "https://$scm_host/api/deployments/$deploy_id" 2>/dev/null || echo "")
            if [[ -z "$poll_body" ]]; then continue; fi
            deploy_status=$(echo "$poll_body" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            complete=$(echo "$poll_body" | jq -r '.complete // false' 2>/dev/null || echo "false")
            if [[ "$complete" == "true" ]]; then
                if [[ "$deploy_status" == "4" ]]; then deploy_ok=1; fi
                break
            fi
        done

        if [[ $deploy_ok -eq 1 ]]; then break; fi

        if [[ "$deploy_status" == "6" && $attempt -lt $RETRY_COUNT ]]; then
            echo "[WARNING] Deployment conflict detected for $label (status 6). Waiting for SCM to become idle before retry..."
            if ! wait_for_scm_idle "$scm_host" "$arm_token" "$label"; then
                echo "[ERROR] Timed out waiting for SCM to become idle for $label before retry." >&2
                break
            fi
            continue
        fi
        break
    done

    rm -f "$zip_path"

    if [[ $deploy_ok -ne 1 ]]; then
        echo "[ERROR] Deployment did not complete successfully for $label (status: $deploy_status)." >&2
        if [[ $recorded -eq 0 ]]; then DEPLOYMENT_ERRORS+=("$label"); fi
        continue
    fi
    echo "[SUCCESS] Deployment completed for $label"

    echo "[INFO] Verifying function discovery..."
    func_list=$(az functionapp function list --name "$app" --resource-group "$ResourceGroupName" \
        --query "[].name" -o tsv 2>/dev/null || true)
    if [[ -n "$func_list" ]]; then
        echo "[SUCCESS] Discovered functions: $func_list"
    else
        echo "[WARNING] No functions discovered yet. They may appear after the first cold start."
    fi
    echo ""
    echo "[INFO] To view logs use Application Insights in the portal,"
    echo "       or: az monitor app-insights query ..."
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
if [[ ${#DEPLOYMENT_ERRORS[@]} -gt 0 ]]; then
    echo "[FAILED] =========================================="
    echo "[FAILED] Deployment completed with errors:"
    for e in "${DEPLOYMENT_ERRORS[@]}"; do
        echo "  - $e"
    done
    echo "[FAILED] =========================================="
    exit 1
fi
echo "[SUCCESS] =========================================="
echo "[SUCCESS] All deployments complete!"
echo "[SUCCESS] =========================================="
for i in "${!T_LABEL[@]}"; do
    printf "  %-20s -> %s [%s]\n" "${T_LABEL[$i]}" "${T_APP[$i]}" "${T_KIND[$i]}"
done
echo "  Resource Group   : $ResourceGroupName"
echo ""
echo "[INFO] Flex Consumption has no Kudu - use Application Insights for function logs:"
for i in "${!T_LABEL[@]}"; do
    if [[ "${T_KIND[$i]}" == "function" ]]; then
        echo "  Portal > ${T_APP[$i]} > Application Insights > Live Metrics"
    fi
done
