#!/usr/bin/env bash
#
# Lock the retention policies. THIS CANNOT BE UNDONE.
#
# A locked policy cannot be removed, shortened or unlocked by anyone - not a
# subscription owner, not Microsoft support. The retention period can only be
# extended. Neither the storage account nor its resource group can be deleted
# until every blob's retention has expired, which for the six-year default means
# six years after the last write to each blob.
#
# This is deliberately a separate script rather than a deployment flag. Locking
# is a governance decision about a specific set of records, taken once the
# pipeline has been seen to work, not a property of a template.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --resource-group <name> --storage-account <name> [options]

Required:
  --resource-group <name>    Resource group holding the storage account.
  --storage-account <name>   Storage account whose policies should be locked.

Options:
  --container <name>         Lock only this container. Repeatable.
                             Default: every am-* container with a policy.
  --yes                      Skip the confirmation prompt. For automation that
                             has already made this decision deliberately.
  -h, --help                 Show this message.
EOF
    exit "${1:-1}"
}

RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
ASSUME_YES=false
CONTAINERS=()

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
    --container)
        CONTAINERS+=("${2:-}")
        shift 2
        ;;
    --yes)
        ASSUME_YES=true
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
command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required but not installed." >&2
    exit 1
}

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && CONTAINERS+=("$name")
    done < <(az storage container list \
        --account-name "$STORAGE_ACCOUNT" \
        --auth-mode login \
        --query "[?starts_with(name, 'am-')].name" --output tsv 2>/dev/null || true)
fi

[[ ${#CONTAINERS[@]} -gt 0 ]] || {
    echo "Error: no containers to lock." >&2
    exit 1
}

echo
echo "About to LOCK retention on:"
for container in "${CONTAINERS[@]}"; do
    PERIOD=$(az storage container immutability-policy show \
        --account-name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --container-name "$container" \
        --query 'immutabilityPeriodSinceCreationInDays' --output tsv 2>/dev/null || echo "")
    STATE=$(az storage container immutability-policy show \
        --account-name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --container-name "$container" \
        --query 'state' --output tsv 2>/dev/null || echo "")

    if [[ -z "$PERIOD" ]]; then
        echo "  $container - no policy, will be SKIPPED"
    elif [[ "$STATE" == "Locked" ]]; then
        echo "  $container - already locked ($PERIOD days)"
    else
        echo "  $container - $PERIOD days, currently $STATE"
    fi
done

cat <<EOF

Once locked:
  - the retention period can be extended, never reduced
  - no one can remove the policy, including subscription owners
  - the storage account and resource group cannot be deleted until every
    blob's retention has expired

EOF

if [[ "$ASSUME_YES" != true ]]; then
    printf 'Type LOCK to continue: '
    read -r CONFIRMATION
    [[ "$CONFIRMATION" == "LOCK" ]] || {
        echo "Aborted."
        exit 1
    }
fi

for container in "${CONTAINERS[@]}"; do
    POLICY=$(az storage container immutability-policy show \
        --account-name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --container-name "$container" \
        --output json 2>/dev/null || echo '{}')

    ETAG=$(jq -r '.etag // empty' <<<"$POLICY")
    STATE=$(jq -r '.state // empty' <<<"$POLICY")

    if [[ -z "$ETAG" ]]; then
        echo "  skipped $container (no policy)"
        continue
    fi

    if [[ "$STATE" == "Locked" ]]; then
        echo "  skipped $container (already locked)"
        continue
    fi

    # The lock has to quote the policy's current ETag. That is what stops it
    # happening by accident, and what makes it fail safely if the policy has
    # changed since it was read a moment ago.
    az storage container immutability-policy lock \
        --account-name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --container-name "$container" \
        --if-match "$ETAG" \
        --output none

    echo "  LOCKED $container"
done

echo
echo "Done. Verify with:"
echo "  ./scripts/verify.sh --resource-group $RESOURCE_GROUP --storage-account $STORAGE_ACCOUNT"
