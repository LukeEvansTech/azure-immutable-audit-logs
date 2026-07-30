#!/usr/bin/env bash
#
# Check that the pipeline is actually working: containers exist and are
# protected, records are arriving in the workspace, and blobs are landing in
# storage.
#
# Every read here goes through the caller's own Entra ID identity
# (--auth-mode login), which is both what the storage account is configured to
# require and what makes the read attributable in the blob access logs.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --resource-group <name> --storage-account <name> [options]

Required:
  --resource-group <name>    Resource group holding the storage account.
  --storage-account <name>   Storage account holding the retained records.

Options:
  --workspace-guid <guid>    Workspace GUID, to run the KQL checks. This is the
                             customerId, not the resource ID. Skipped if absent.
  --test-immutability        Additionally attempt a blob delete, which must fail.
                             Off by default because the delete can hang rather
                             than return when the policy rejects it.
  -h, --help                 Show this message.
EOF
    exit "${1:-1}"
}

RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
WORKSPACE_GUID=""
TEST_IMMUTABILITY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
    --resource-group)
        RESOURCE_GROUP="${2:-}"
        shift 2
        ;;
    --storage-account)
        STORAGE_ACCOUNT="${2:-}"
        shift 2
        ;;
    --workspace-guid)
        WORKSPACE_GUID="${2:-}"
        shift 2
        ;;
    --test-immutability)
        TEST_IMMUTABILITY=true
        shift
        ;;
    -h | --help) usage 0 ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        ;;
    esac
done

[[ -n "$RESOURCE_GROUP" && -n "$STORAGE_ACCOUNT" ]] || usage

command -v az >/dev/null 2>&1 || {
    echo "Error: az is required but not installed." >&2
    exit 1
}

PASS=0
FAIL=0
WARN=0

ok() {
    echo "  [ ok ] $*"
    PASS=$((PASS + 1))
}
bad() {
    echo "  [FAIL] $*"
    FAIL=$((FAIL + 1))
}
warn() {
    echo "  [warn] $*"
    WARN=$((WARN + 1))
}

# macOS has no timeout(1). Run a command in the background and kill it if it
# outlives the deadline, so a hung Azure call cannot wedge the whole script.
run_with_timeout() {
    local seconds="$1"
    shift
    "$@" >/dev/null 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$waited" -ge "$seconds" ]]; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

echo
echo "Storage account"
echo "---------------"

ACCOUNT_JSON=$(az storage account show \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --output json 2>/dev/null) || {
    bad "storage account $STORAGE_ACCOUNT not found in $RESOURCE_GROUP"
    exit 1
}

ok "storage account exists ($(jq -r '.sku.name' <<<"$ACCOUNT_JSON") in $(jq -r '.location' <<<"$ACCOUNT_JSON"))"

# Read a boolean property, substituting a default only when it is genuinely
# absent.
#
# Do NOT use jq's `//` operator here. It treats `false` as empty just like
# `null`, so `.allowSharedKeyAccess // true` yields "true" for an account where
# the value is explicitly false - reporting a correctly hardened account as
# insecure. That bug shipped once already.
bool_prop() {
    local key="$1" default="$2"
    jq -r --arg k "$key" --arg d "$default" \
        'if (.[$k] == null) then $d else (.[$k] | tostring) end' <<<"$ACCOUNT_JSON"
}

SHARED_KEY=$(bool_prop allowSharedKeyAccess true)
if [[ "$SHARED_KEY" == "false" ]]; then
    ok "shared key access disabled, so every read is attributable to an identity"
else
    warn "shared key access is enabled - reads authorised with the account key appear in the access log as anonymous, with no user attached"
fi

HTTPS_ONLY=$(bool_prop enableHttpsTrafficOnly false)
if [[ "$HTTPS_ONLY" == "true" ]]; then
    ok "HTTPS-only enforced"
else
    bad "HTTPS-only is not enforced"
fi

PUBLIC_BLOB=$(bool_prop allowBlobPublicAccess true)
if [[ "$PUBLIC_BLOB" == "false" ]]; then
    ok "anonymous blob access disabled"
else
    bad "anonymous blob access is permitted"
fi

# The firewall is the usual reason the data-plane checks below fail, and it
# looks exactly like a missing role assignment if you do not check for it.
FIREWALL_DEFAULT=$(jq -r '.networkRuleSet.defaultAction // "Allow"' <<<"$ACCOUNT_JSON")
IP_RULE_COUNT=$(jq -r '.networkRuleSet.ipRules | length' <<<"$ACCOUNT_JSON")
if [[ "$FIREWALL_DEFAULT" == "Deny" ]]; then
    if [[ "$IP_RULE_COUNT" -eq 0 ]]; then
        warn "firewall denies by default with no IP rules - Azure Monitor can still write via the trusted-services path, but no client can read. Add your address to allowedIpRanges to inspect the archive."
    else
        ok "firewall denies by default with $IP_RULE_COUNT allowed IP range(s)"
    fi
else
    warn "firewall default action is $FIREWALL_DEFAULT - the account is reachable from any network"
fi

echo
echo "Containers and retention"
echo "------------------------"

CONTAINERS=$(az storage container list \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --query '[].name' --output tsv 2>/dev/null || true)

if [[ -z "$CONTAINERS" ]]; then
    if [[ "$FIREWALL_DEFAULT" == "Deny" && "$IP_RULE_COUNT" -eq 0 ]]; then
        bad "cannot list containers: the storage firewall denies by default and has no IP rules, so this machine is blocked. Add your address to allowedIpRanges and redeploy. This is not a permissions problem."
    else
        bad "no containers found, or the caller cannot list them (needs Storage Blob Data Reader or higher on the account, which Contributor does not include)"
    fi
else
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue

        POLICY=$(az storage container immutability-policy show \
            --account-name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --container-name "$container" \
            --output json 2>/dev/null || echo '{}')

        PERIOD=$(jq -r '.immutabilityPeriodSinceCreationInDays // empty' <<<"$POLICY")
        STATE=$(jq -r '.state // empty' <<<"$POLICY")
        APPENDS=$(jq -r '.allowProtectedAppendWrites // false' <<<"$POLICY")

        if [[ -z "$PERIOD" ]]; then
            # An unprotected am-* container means export created it before the
            # template did, and everything already written to it is unprotected.
            if [[ "$container" == am-* ]]; then
                bad "$container has NO retention policy - export created it before the template did"
            else
                warn "$container has no retention policy"
            fi
            continue
        fi

        if [[ "$APPENDS" == "true" ]]; then
            ok "$container protected for $PERIOD days, state $STATE, protected appends allowed"
        else
            bad "$container protected for $PERIOD days but protected appends are disabled, which stops export writing to it"
        fi
    done <<<"$CONTAINERS"
fi

echo
echo "Blobs"
echo "-----"

for container in $CONTAINERS; do
    [[ "$container" == am-* ]] || continue

    COUNT=$(az storage blob list \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$container" \
        --auth-mode login \
        --num-results 100 \
        --query 'length(@)' --output tsv 2>/dev/null || echo 0)

    if [[ "$COUNT" -gt 0 ]]; then
        ok "$container holds $COUNT blob(s)"
    else
        warn "$container is empty - expected for the first ~30 minutes while export provisions, or if nothing has been generated yet"
    fi
done

if [[ -n "$WORKSPACE_GUID" ]]; then
    echo
    echo "Workspace"
    echo "---------"

    # sum(ItemCount) rather than count(). If sampling is ever enabled, each
    # retained row stands for ItemCount originals and a plain count() silently
    # under-reports. The app disables sampling, so with a correct deployment the
    # two agree - a disagreement here means sampling got turned back on.
    EVENTS=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_GUID" \
        --analytics-query "AppEvents | where TimeGenerated > ago(24h) | summarize Events = sum(ItemCount) by Name | order by Events desc" \
        --output json 2>/dev/null || echo '[]')

    EVENT_ROWS=$(jq 'length' <<<"$EVENTS")
    if [[ "$EVENT_ROWS" -gt 0 ]]; then
        ok "AppEvents has $EVENT_ROWS event type(s) in the last 24h"
        jq -r '.[] | "         \(.Name): \(.Events)"' <<<"$EVENTS"
    else
        warn "no AppEvents rows in the last 24h - generate some events, then allow 2-5 minutes for ingestion"
    fi

    HTTP_ROWS=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_GUID" \
        --analytics-query "AppServiceHTTPLogs | where TimeGenerated > ago(24h) | summarize Requests = count()" \
        --output json 2>/dev/null | jq -r '.[0].Requests // 0' || echo 0)

    if [[ "$HTTP_ROWS" -gt 0 ]]; then
        ok "AppServiceHTTPLogs has $HTTP_ROWS request(s) in the last 24h"
    else
        warn "no AppServiceHTTPLogs rows in the last 24h"
    fi
fi

if [[ "$TEST_IMMUTABILITY" == true ]]; then
    echo
    echo "Immutability enforcement"
    echo "------------------------"

    TARGET_CONTAINER=$(grep -m1 '^am-' <<<"$CONTAINERS" || true)
    if [[ -z "$TARGET_CONTAINER" ]]; then
        warn "no am-* container to test against"
    else
        TARGET_BLOB=$(az storage blob list \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$TARGET_CONTAINER" \
            --auth-mode login \
            --num-results 1 \
            --query '[0].name' --output tsv 2>/dev/null || true)

        if [[ -z "$TARGET_BLOB" || "$TARGET_BLOB" == "None" ]]; then
            warn "no blob in $TARGET_CONTAINER to test against yet"
        else
            set +e
            run_with_timeout 20 az storage blob delete \
                --account-name "$STORAGE_ACCOUNT" \
                --container-name "$TARGET_CONTAINER" \
                --name "$TARGET_BLOB" \
                --auth-mode login
            RESULT=$?
            set -e

            case "$RESULT" in
            0) bad "a blob in $TARGET_CONTAINER was DELETED - retention is not being enforced" ;;
            124) ok "delete of $TARGET_BLOB did not succeed (timed out against the policy)" ;;
            *) ok "delete of $TARGET_BLOB was rejected, as it should be" ;;
            esac
        fi
    fi
fi

echo
echo "------------------------------------------------------------"
printf '  %d passed, %d warnings, %d failures\n' "$PASS" "$WARN" "$FAIL"
echo "------------------------------------------------------------"
echo

[[ "$FAIL" -eq 0 ]]
