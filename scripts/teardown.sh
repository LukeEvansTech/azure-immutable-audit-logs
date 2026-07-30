#!/usr/bin/env bash
#
# Remove the deployment.
#
# Refuses to run if any retention policy is locked. That is not caution for its
# own sake: a locked policy makes the storage account undeletable until every
# blob's retention has expired, so the delete would fail part-way and leave the
# resource group in a half-removed state.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --resource-group <name> [options]

Required:
  --resource-group <name>    Resource group to delete.

Options:
  --storage-account <name>   Storage account to check for locked policies.
                             Default: discovered from the resource group.
  --purge-workspace          Also purge the soft-deleted Log Analytics
                             workspace, so the name is immediately reusable.
                             Without this it is recoverable for 14 days.
  --yes                      Skip the confirmation prompt.
  -h, --help                 Show this message.
EOF
    exit "${1:-1}"
}

RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
PURGE_WORKSPACE=false
ASSUME_YES=false

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
    --purge-workspace)
        PURGE_WORKSPACE=true
        shift
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

[[ -n "$RESOURCE_GROUP" ]] || usage

command -v az >/dev/null 2>&1 || {
    echo "Error: az is required but not installed." >&2
    exit 1
}

az group show --name "$RESOURCE_GROUP" --output none 2>/dev/null || {
    echo "Resource group $RESOURCE_GROUP does not exist. Nothing to do."
    exit 0
}

if [[ -z "$STORAGE_ACCOUNT" ]]; then
    STORAGE_ACCOUNT=$(az storage account list \
        --resource-group "$RESOURCE_GROUP" \
        --query '[0].name' --output tsv 2>/dev/null || true)
fi

if [[ -n "$STORAGE_ACCOUNT" && "$STORAGE_ACCOUNT" != "None" ]]; then
    echo "==> Checking retention policies on $STORAGE_ACCOUNT"

    LOCKED=()
    UNLOCKED=()
    while IFS= read -r container; do
        [[ -n "$container" ]] || continue
        STATE=$(az storage container immutability-policy show \
            --account-name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --container-name "$container" \
            --query 'state' --output tsv 2>/dev/null || echo "")
        case "$STATE" in
        Locked) LOCKED+=("$container") ;;
        Unlocked) UNLOCKED+=("$container") ;;
        esac
    done < <(az storage container list \
        --account-name "$STORAGE_ACCOUNT" \
        --auth-mode login \
        --query '[].name' --output tsv 2>/dev/null || true)

    if [[ ${#LOCKED[@]} -gt 0 ]]; then
        cat >&2 <<EOF

Refusing to delete: these containers have LOCKED retention policies.

$(printf '  %s\n' "${LOCKED[@]}")

A locked policy cannot be removed by anyone. The storage account, and therefore
the resource group, cannot be deleted until every blob in these containers has
passed its retention period. This is the protection working as intended, not a
fault.

If you need the rest of the resource group gone, delete those resources
individually and leave the storage account in place.
EOF
        exit 1
    fi

    # Unlocked policies need no special handling here. Most people expect the
    # opposite, so this is spelled out rather than left implicit.
    #
    # An unlocked policy protects the DATA: deleting a blob under an active
    # unlocked policy is rejected with BlobImmutableDueToPolicy, exactly as
    # under a locked one. It does not protect the ACCOUNT: deleting the storage
    # account itself succeeds, and takes the containers and blobs with it.
    #
    # Verified against a live deployment rather than inferred - blob delete
    # rejected, storage account delete accepted, on the same account with an
    # active (unexpired) unlocked policy and blobs present.
    #
    # So `az group delete` below is sufficient, and that asymmetry is the whole
    # practical difference between unlocked and locked: unlocked means you can
    # always get rid of it by deleting the account.
    if [[ ${#UNLOCKED[@]} -gt 0 ]]; then
        echo "    ${#UNLOCKED[@]} unlocked polic(ies) present - these do not block account deletion"
    fi
fi

WORKSPACE_NAME=""
if [[ "$PURGE_WORKSPACE" == true ]]; then
    WORKSPACE_NAME=$(az monitor log-analytics workspace list \
        --resource-group "$RESOURCE_GROUP" \
        --query '[0].name' --output tsv 2>/dev/null || true)
fi

if [[ "$ASSUME_YES" != true ]]; then
    echo
    echo "This will delete the resource group $RESOURCE_GROUP and everything in it."
    printf 'Type the resource group name to confirm: '
    read -r CONFIRMATION
    [[ "$CONFIRMATION" == "$RESOURCE_GROUP" ]] || {
        echo "Aborted."
        exit 1
    }
fi

echo "==> Deleting resource group $RESOURCE_GROUP"
az group delete --name "$RESOURCE_GROUP" --yes --output none

if [[ "$PURGE_WORKSPACE" == true && -n "$WORKSPACE_NAME" && "$WORKSPACE_NAME" != "None" ]]; then
    echo "==> Purging soft-deleted workspace $WORKSPACE_NAME"
    # Soft-deleted workspaces hold their name for 14 days, so redeploying with
    # the same parameters into the same resource group otherwise fails.
    az monitor log-analytics workspace delete \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$WORKSPACE_NAME" \
        --force true --yes --output none 2>/dev/null ||
        echo "    purge failed or was unnecessary - the workspace may already be gone"
fi

echo "==> Done"
