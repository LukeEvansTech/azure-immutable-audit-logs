#!/usr/bin/env bash
#
# Deploy the self-contained demo: infrastructure, then the app, then optionally
# Entra ID authentication in front of it.
#
# Retention policies are created unlocked. Locking them is a separate, deliberate
# and irreversible step - see scripts/lock-retention.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 --resource-group <name> [options]

Required:
  --resource-group <name>   Resource group to deploy into. Created if absent.

Options:
  --location <region>       Azure region. Default: uksouth.
  --subscription <id|name>  Subscription to deploy into. Default: current.
  --parameters <file>       Bicep parameters file.
                            Default: infra/main.bicepparam if it exists.
  --enable-auth             Put Entra ID sign-in in front of the app. Requires
                            permission to create app registrations in the tenant.
  --skip-app                Deploy infrastructure only, do not publish the app.
  -h, --help                Show this message.
EOF
    exit "${1:-1}"
}

RESOURCE_GROUP=""
LOCATION="uksouth"
SUBSCRIPTION=""
PARAM_FILE=""
ENABLE_AUTH=false
SKIP_APP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
        --location)       LOCATION="${2:-}"; shift 2 ;;
        --subscription)   SUBSCRIPTION="${2:-}"; shift 2 ;;
        --parameters)     PARAM_FILE="${2:-}"; shift 2 ;;
        --enable-auth)    ENABLE_AUTH=true; shift ;;
        --skip-app)       SKIP_APP=true; shift ;;
        -h|--help)        usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$RESOURCE_GROUP" ]] || { echo "Error: --resource-group is required." >&2; usage; }

for tool in az jq zip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is required but not installed." >&2; exit 1; }
done

if [[ "$SKIP_APP" == false ]]; then
    command -v dotnet >/dev/null 2>&1 || {
        echo "Error: the .NET SDK is required to publish the app. Use --skip-app to deploy infrastructure only." >&2
        exit 1
    }
fi

if [[ -n "$SUBSCRIPTION" ]]; then
    echo "==> Selecting subscription $SUBSCRIPTION"
    az account set --subscription "$SUBSCRIPTION"
fi

# Default to the operator's own parameters file when they have made one, so that
# a plain ./scripts/deploy.sh picks it up rather than silently ignoring it.
if [[ -z "$PARAM_FILE" && -f "$REPO_ROOT/infra/main.bicepparam" ]]; then
    PARAM_FILE="$REPO_ROOT/infra/main.bicepparam"
fi

echo "==> Ensuring resource group $RESOURCE_GROUP exists in $LOCATION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo "==> Deploying infrastructure"
DEPLOY_ARGS=(
    --resource-group "$RESOURCE_GROUP"
    --template-file "$REPO_ROOT/infra/main.bicep"
    --name "immutable-audit-logs-$(date -u +%Y%m%d%H%M%S)"
)
if [[ -n "$PARAM_FILE" ]]; then
    echo "    using parameters from $PARAM_FILE"
    DEPLOY_ARGS+=(--parameters "$PARAM_FILE")
fi

OUTPUTS=$(az deployment group create "${DEPLOY_ARGS[@]}" --query 'properties.outputs' --output json)

WORKSPACE_NAME=$(jq -r '.workspaceName.value' <<<"$OUTPUTS")
WORKSPACE_GUID=$(jq -r '.workspaceCustomerId.value' <<<"$OUTPUTS")
STORAGE_ACCOUNT=$(jq -r '.storageAccountName.value' <<<"$OUTPUTS")
APP_SERVICE_NAME=$(jq -r '.appServiceName.value' <<<"$OUTPUTS")
APP_URL=$(jq -r '.appServiceHostName.value' <<<"$OUTPUTS")
APP_INSIGHTS_NAME=$(jq -r '.appInsightsName.value' <<<"$OUTPUTS")
RETENTION_DAYS=$(jq -r '.retentionDays.value' <<<"$OUTPUTS")
SHARED_KEY=$(jq -r '.sharedKeyAccessAllowed.value' <<<"$OUTPUTS")

echo "==> Infrastructure deployed"

if [[ "$SKIP_APP" == false ]]; then
    echo "==> Publishing the app"
    BUILD_DIR=$(mktemp -d)
    trap 'rm -rf "$BUILD_DIR"' EXIT

    dotnet publish "$REPO_ROOT/app/AuditLogDemo.csproj" \
        --configuration Release \
        --output "$BUILD_DIR/publish" \
        --nologo \
        --verbosity quiet

    (cd "$BUILD_DIR/publish" && zip -qr "$BUILD_DIR/app.zip" .)

    az webapp deploy \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_SERVICE_NAME" \
        --src-path "$BUILD_DIR/app.zip" \
        --type zip \
        --output none

    rm -rf "$BUILD_DIR"
    trap - EXIT
    echo "==> App published"
fi

if [[ "$ENABLE_AUTH" == true ]]; then
    echo "==> Enabling Entra ID sign-in"
    TENANT_ID=$(az account show --query tenantId --output tsv)
    SUBSCRIPTION_ID=$(az account show --query id --output tsv)

    # App Services are created with v1 auth config, which rejects every v2
    # command. Upgrading is a no-op once it has been done.
    AUTH_VERSION=$(az webapp auth-classic show \
        --name "$APP_SERVICE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query 'configVersion' --output tsv 2>/dev/null || echo "")
    if [[ "$AUTH_VERSION" == "v1" ]]; then
        echo "    upgrading auth config v1 -> v2"
        az webapp auth config-version upgrade \
            --name "$APP_SERVICE_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --output none
    fi

    EXISTING_CLIENT_ID=$(az webapp auth show \
        --name "$APP_SERVICE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query 'properties.identityProviders.azureActiveDirectory.registration.clientId' \
        --output tsv 2>/dev/null || echo "")

    if [[ -z "$EXISTING_CLIENT_ID" || "$EXISTING_CLIENT_ID" == "None" ]]; then
        echo "    creating app registration"
        # enable-id-token-issuance is required: Easy Auth uses the hybrid flow
        # (response_type=code+id_token) and the sign-in fails without it.
        CLIENT_ID=$(az ad app create \
            --display-name "$APP_SERVICE_NAME" \
            --web-redirect-uris "$APP_URL/.auth/login/aad/callback" \
            --sign-in-audience AzureADMyOrg \
            --enable-id-token-issuance true \
            --query appId --output tsv)
        CLIENT_SECRET=$(az ad app credential reset --id "$CLIENT_ID" --query password --output tsv)
        echo "    app registration created ($CLIENT_ID)"
    else
        CLIENT_ID="$EXISTING_CLIENT_ID"
        echo "    reusing app registration ($CLIENT_ID)"
    fi

    # The secret goes in through a 0600 temp file rather than as a command-line
    # argument. argv is readable by any local user via ps and is captured
    # verbatim by most CI log collectors; a file is neither.
    if [[ -n "${CLIENT_SECRET:-}" ]]; then
        SETTINGS_FILE=$(mktemp)
        chmod 600 "$SETTINGS_FILE"
        trap 'rm -f "$SETTINGS_FILE"' EXIT
        jq -n --arg v "$CLIENT_SECRET" \
            '[{name: "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET", value: $v, slotSetting: false}]' \
            > "$SETTINGS_FILE"
        az webapp config appsettings set \
            --name "$APP_SERVICE_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --settings @"$SETTINGS_FILE" \
            --output none
        rm -f "$SETTINGS_FILE"
        trap - EXIT
    fi

    az webapp auth microsoft update \
        --name "$APP_SERVICE_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --client-id "$CLIENT_ID" \
        --client-secret-setting-name MICROSOFT_PROVIDER_AUTHENTICATION_SECRET \
        --issuer "https://login.microsoftonline.com/$TENANT_ID/v2.0" \
        --yes \
        --output none

    # redirectToProvider has no CLI equivalent. Without it an unauthenticated
    # browser lands on a provider-selection page rather than the sign-in page.
    AUTH_BODY=$(jq -n \
        --arg clientId "$CLIENT_ID" \
        --arg issuer "https://login.microsoftonline.com/$TENANT_ID/v2.0" \
        '{
            properties: {
                platform: { enabled: true },
                globalValidation: {
                    requireAuthentication: true,
                    unauthenticatedClientAction: "RedirectToLoginPage",
                    redirectToProvider: "azureActiveDirectory"
                },
                identityProviders: {
                    azureActiveDirectory: {
                        enabled: true,
                        registration: {
                            clientId: $clientId,
                            clientSecretSettingName: "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET",
                            openIdIssuer: $issuer
                        }
                    }
                },
                login: { tokenStore: { enabled: true } }
            }
        }')

    az rest --method PUT \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_SERVICE_NAME}/config/authsettingsV2?api-version=2022-09-01" \
        --body "$AUTH_BODY" \
        --output none

    echo "    sign-in enabled for tenant $TENANT_ID"
fi

cat <<EOF

------------------------------------------------------------
  Deployed
------------------------------------------------------------
  Resource group   $RESOURCE_GROUP
  Workspace        $WORKSPACE_NAME
  Workspace GUID   $WORKSPACE_GUID
  Storage account  $STORAGE_ACCOUNT
  App Service      $APP_SERVICE_NAME
  App URL          $APP_URL
  App Insights     $APP_INSIGHTS_NAME
  Blob retention   $RETENTION_DAYS days (UNLOCKED)
  Shared key auth  $SHARED_KEY
------------------------------------------------------------

Export takes around 30 minutes to start writing. Events generated before then
may never reach storage. This is normal and is not worth investigating until
the 30 minutes have passed.

Next:
  1. Open $APP_URL and generate some events.
  2. Wait, then check they landed:
       ./scripts/verify.sh --resource-group $RESOURCE_GROUP \\
         --storage-account $STORAGE_ACCOUNT --workspace-guid $WORKSPACE_GUID
  3. Only once you are satisfied, lock retention (IRREVERSIBLE):
       ./scripts/lock-retention.sh --resource-group $RESOURCE_GROUP \\
         --storage-account $STORAGE_ACCOUNT
EOF
