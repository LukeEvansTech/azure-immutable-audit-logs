#!/usr/bin/env bash
#
# Check the archive from inside the virtual network.
#
# With the storage account's public endpoint disabled, verify.sh cannot reach
# the blobs: there is no route from a laptop to a private endpoint. This runs
# the same data-plane checks from a throwaway container placed in the verifier
# subnet, then prints what it saw and deletes itself.
#
# It also answers the question that actually matters after a hardening change:
# whether Data Export is still writing. If blobs are arriving at a private-only
# account, the trusted-services path survived; if they stopped, it did not.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --resource-group <name> --storage-account <name> --subnet <id> [options]

Required:
    --resource-group <name>     Resource group to create the container in.
    --storage-account <name>    Storage account to check.
    --subnet <resource-id>      Verifier subnet. Must be delegated to
                                Microsoft.ContainerInstance/containerGroups.
                                main.bicep outputs this as verifierSubnetResourceId.

Options:
    --container <name>          Container to look in. Default: am-appevents.
    --location <region>         Region for the container instance.
                                Default: the resource group's region.
    --keep                      Leave the container group and identity in place
                                for debugging instead of removing them.
    -h, --help                  Show this message.
EOF
    exit "${1:-1}"
}

RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
SUBNET_ID=""
BLOB_CONTAINER="am-appevents"
LOCATION=""
KEEP=false

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
    --subnet)
        SUBNET_ID="${2:-}"
        shift 2
        ;;
    --container)
        BLOB_CONTAINER="${2:-}"
        shift 2
        ;;
    --location)
        LOCATION="${2:-}"
        shift 2
        ;;
    --keep)
        KEEP=true
        shift
        ;;
    -h | --help) usage 0 ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        ;;
    esac
done

[[ -n "$RESOURCE_GROUP" && -n "$STORAGE_ACCOUNT" && -n "$SUBNET_ID" ]] || usage

command -v az >/dev/null 2>&1 || {
    echo "Error: az is required but not installed." >&2
    exit 1
}

[[ -n "$LOCATION" ]] || LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location --output tsv)

SUFFIX=$(date -u +%H%M%S)
IDENTITY_NAME="id-verify-${STORAGE_ACCOUNT}"
GROUP_NAME="ci-verify-${STORAGE_ACCOUNT}-${SUFFIX}"

cleanup() {
    if [[ "$KEEP" == true ]]; then
        echo "==> --keep set, leaving $GROUP_NAME and $IDENTITY_NAME in place"
        return
    fi
    echo "==> Removing the verification container"
    az container delete --resource-group "$RESOURCE_GROUP" --name "$GROUP_NAME" --yes --output none 2>/dev/null || true
    az identity delete --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --output none 2>/dev/null || true
}
trap cleanup EXIT

STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id --output tsv)

# Derive the blob host from the account rather than assuming
# blob.core.windows.net, so this still works in a sovereign cloud where the
# suffix differs. The Bicep derives its DNS zone the same way.
BLOB_HOST=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" \
    --query primaryEndpoints.blob --output tsv | sed -e 's|^https://||' -e 's|/$||')

# A user-assigned identity, created and granted its role BEFORE the container
# exists. A system-assigned identity would only come into being with the
# container group, leaving no moment to grant it anything before it runs.
echo "==> Preparing the verifier identity"
az identity create --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --location "$LOCATION" --output none
IDENTITY_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query id --output tsv)
IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query clientId --output tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query principalId --output tsv)

echo "==> Granting Storage Blob Data Reader"
az role assignment create \
    --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Reader" \
    --scope "$STORAGE_ID" \
    --output none 2>/dev/null || echo "    assignment already present"

# The container retries rather than assuming the role is live. Role assignments
# take minutes to propagate, and a single attempt would report a permissions
# failure that looks exactly like a network failure.
read -r -d '' PROBE <<PROBE_EOF || true
set -u
echo "--- resolving the blob endpoint ---"
# Python rather than getent or nslookup: the azure-cli image is built on it, so
# it is the one lookup tool guaranteed to be present whichever base the image
# is currently using.
python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" ${BLOB_HOST} 2>/dev/null \
    || echo "resolution failed"
echo
echo "--- signing in with the managed identity ---"
# --client-id is the current flag for a user-assigned managed identity.
# --username still exists but now means a user or service principal, so passing
# the identity's client ID to it fails in a way that reads like the identity is
# simply not ready yet. --username is kept only as a fallback for older CLIs.
for i in \$(seq 1 20); do
    if az login --identity --client-id ${IDENTITY_CLIENT_ID} --output none 2>/dev/null \
        || az login --identity --username ${IDENTITY_CLIENT_ID} --output none 2>/dev/null; then
        echo "signed in on attempt \$i"
        break
    fi
    echo "attempt \$i: identity not ready, waiting"
    sleep 15
done
echo "identity in use: \$(az account show --query user.assignedIdentityInfo -o tsv 2>/dev/null || echo none)"
echo
echo "--- listing containers ---"
for i in \$(seq 1 20); do
    if OUT=\$(az storage container list --account-name ${STORAGE_ACCOUNT} --auth-mode login --query '[].name' --output tsv 2>&1); then
        echo "\$OUT"
        break
    fi
    echo "attempt \$i: \$(echo "\$OUT" | tail -1)"
    sleep 15
done
echo
echo "--- blobs in ${BLOB_CONTAINER} ---"
az storage blob list --account-name ${STORAGE_ACCOUNT} --container-name ${BLOB_CONTAINER} \
    --auth-mode login --num-results 5 --query '[].name' --output tsv 2>&1 | head -20
echo
echo "--- blob count ---"
az storage blob list --account-name ${STORAGE_ACCOUNT} --container-name ${BLOB_CONTAINER} \
    --auth-mode login --num-results 1000 --query 'length(@)' --output tsv 2>&1
echo "--- probe complete ---"
PROBE_EOF

echo "==> Running the probe inside the network"

# The probe is passed base64-encoded rather than inlined. It contains quotes,
# newlines and dollar signs, all of which get mangled going through
# --command-line as a quoted string; encoding it means the container receives
# exactly what was written here.
PROBE_B64=$(printf '%s' "$PROBE" | base64 | tr -d '\n')

az container create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$GROUP_NAME" \
    --image mcr.microsoft.com/azure-cli:latest \
    --location "$LOCATION" \
    --subnet "$SUBNET_ID" \
    --assign-identity "$IDENTITY_ID" \
    --restart-policy Never \
    `# --os-type is normally inferred, but not when --subnet is supplied: the` \
    `# create then fails with InvalidOsType and a null container group name.` \
    --os-type Linux \
    --cpu 1 --memory 1.5 \
    --command-line "/bin/sh -c 'echo $PROBE_B64 | base64 -d | /bin/sh'" \
    --output none

echo "==> Waiting for the probe to finish"
for _ in $(seq 1 60); do
    STATE=$(az container show --resource-group "$RESOURCE_GROUP" --name "$GROUP_NAME" \
        --query 'instanceView.state' --output tsv 2>/dev/null || echo "")
    [[ "$STATE" == "Succeeded" || "$STATE" == "Failed" || "$STATE" == "Terminated" ]] && break
    sleep 10
done

echo
echo "------------------------------------------------------------"
echo "  Probe output (from inside the virtual network)"
echo "------------------------------------------------------------"
az container logs --resource-group "$RESOURCE_GROUP" --name "$GROUP_NAME" 2>/dev/null || {
    echo "  no logs available; container state was ${STATE:-unknown}"
}
echo "------------------------------------------------------------"
echo
echo "A private address in the resolution line means DNS is going through the"
echo "endpoint. Blobs listed means export is still writing to a private-only"
echo "account, which is the thing worth confirming after any network change."
