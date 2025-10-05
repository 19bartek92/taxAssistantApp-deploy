@description('Name of the App Service Plan')
param appServicePlanName string = 'taxassistant-plan'

@description('Name of the Web App')
param webAppName string = 'taxassistant-${uniqueString(resourceGroup().id)}'

@description('Location for all resources')
param location string = 'West Europe'

@description('SKU for App Service Plan')
@allowed([
  'F1'
  'B1'
  'B2'
  'S1'
  'S2'
  'P1v3'
  'P2v3'
])
param sku string = 'S1'


@description('NSA Search API Key')
@secure()
param nsaSearchApiKey string = ''

@description('NSA Detail API Key')
@secure()
param nsaDetailApiKey string = ''


@description('Key Vault Name')
param keyVaultName string = 'kv-${uniqueString(resourceGroup().id)}'

@description('Enable Key Vault recovery (for existing deleted vaults)')
param enableKeyVaultRecovery bool = false

@description('Force application redeployment (change this value to trigger update)')
param forceRedeploy string = utcNow('yyyyMMddHHmmss')

@description('GitHub repository in format owner/repo')
param gitHubRepo string = '19bartek92/taxAssistantApp'

@description('GitHub branch for OIDC federation')
param gitHubBranch string = 'main'

@description('GitHub PAT token for automatic secret creation (optional)')
@secure()
param gitHubPat string = ''

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: sku
    tier: sku == 'F1' ? 'Free' : sku == 'B1' ? 'Basic' : sku == 'B2' ? 'Basic' : sku == 'S1' ? 'Standard' : sku == 'S2' ? 'Standard' : 'PremiumV3'
  }
  kind: 'app'
  properties: {
    reserved: false
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: false
    accessPolicies: []
    createMode: enableKeyVaultRecovery ? 'recover' : 'default'
  }
}

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      metadata: [
        {
          name: 'CURRENT_STACK'
          value: 'dotnet'
        }
      ]
      appSettings: [
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        {
          name: 'KeyVaultUri'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'DEPLOYMENT_TIMESTAMP'
          value: forceRedeploy
        }
        {
          name: 'WEBSITE_WEBDEPLOY_USE_SCM'
          value: 'true'
        }
      ]
      alwaysOn: sku != 'F1' && sku != 'B1'
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      detailedErrorLoggingEnabled: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      use32BitWorkerProcess: sku == 'F1'
      webSocketsEnabled: true
    }
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: keyVault
  name: 'add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: webApp.identity.principalId
        permissions: {
          secrets: ['get', 'list']
        }
      }
    ]
  }
}

resource nsaSearchKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'nsa-search-key'
  properties: {
    value: nsaSearchApiKey
  }
}

resource nsaDetailKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'nsa-detail-key'
  properties: {
    value: nsaDetailApiKey
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'deployment-identity'
  location: location
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    managedIdentity
  ]
}

resource websiteContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, 'de139f84-1756-47ae-9be6-808fbbe84772')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772') // Website Contributor
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    managedIdentity
  ]
}

resource githubOidcSetup 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'githubOidcSetup'
  location: location
  kind: 'AzureCLI'
  dependsOn: [
    webApp
    keyVaultAccessPolicy
    nsaSearchKeySecret
    nsaDetailKeySecret
    managedIdentity
    roleAssignment
    websiteContributorRole
  ]
  properties: {
    azCliVersion: '2.76.0'
    environmentVariables: [
      { name: 'RG_NAME', value: resourceGroup().name }
      { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
      { name: 'TENANT_ID', value: subscription().tenantId }
      { name: 'GITHUB_PAT', secureValue: gitHubPat }
      { name: 'GITHUB_REPO', value: gitHubRepo }
      { name: 'GITHUB_BRANCH', value: gitHubBranch }
      { name: 'WEBAPP_NAME', value: webApp.name }
    ]
    scriptContent: '''
      set -e
      echo "Setting up GitHub OIDC authentication for Azure deployment"
      
      # Create Entra Application for GitHub OIDC
      echo "Creating Entra Application for GitHub OIDC..."
      APP_NAME="GitHub-OIDC-${WEBAPP_NAME}"
      
      # Create Azure AD application
      APP_RESPONSE=$(az ad app create \
        --display-name "$APP_NAME" \
        --sign-in-audience AzureADMyOrg)
      
      if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create Azure AD application"
        exit 1
      fi
      
      CLIENT_ID=$(echo "$APP_RESPONSE" | jq -r '.appId')
      APP_OBJECT_ID=$(echo "$APP_RESPONSE" | jq -r '.id')
      
      echo "✅ Created Azure AD Application: $CLIENT_ID"
      
      # Create service principal
      echo "Creating service principal..."
      SP_RESPONSE=$(az ad sp create --id "$CLIENT_ID")
      SP_OBJECT_ID=$(echo "$SP_RESPONSE" | jq -r '.id')
      
      echo "✅ Created Service Principal: $SP_OBJECT_ID"
      
      # Add federated identity credential
      echo "Adding federated identity credential for GitHub Actions..."
      CREDENTIAL_BODY=$(cat << EOF
{
  "name": "github-oidc",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:ref:refs/heads/${GITHUB_BRANCH}",
  "description": "OIDC login from GitHub Actions",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
)
      
      CREDENTIAL_RESPONSE=$(az rest \
        --method POST \
        --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID/federatedIdentityCredentials" \
        --headers "Content-Type=application/json" \
        --body "$CREDENTIAL_BODY")
      
      if [ $? -eq 0 ]; then
        echo "✅ Added federated identity credential"
      else
        echo "⚠️ Warning: Could not add federated credential (may already exist)"
      fi
      
      # Assign Contributor role to service principal on resource group
      echo "Assigning Contributor role to service principal..."
      az role assignment create \
        --assignee "$CLIENT_ID" \
        --role "Contributor" \
        --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"
      
      echo "✅ Assigned Contributor role"
      
      # Setup GitHub secrets (if PAT provided)
      if [ -n "$GITHUB_PAT" ] && [ "$GITHUB_PAT" != "" ]; then
        echo "=== AUTOMATIC GITHUB SECRETS SETUP ==="
        echo "GitHub PAT provided, setting up OIDC secrets..."
        
        # Install dependencies for encryption
        apt-get update
        apt-get install -y python3-pip
        pip3 install pynacl
        
        # Test GitHub API access
        TEST_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_PAT" \
          "https://api.github.com/repos/$GITHUB_REPO")
        
        if echo "$TEST_RESPONSE" | grep -q '"name"'; then
          echo "GitHub API access successful"
          
          # Get repository public key for encryption
          PUBLIC_KEY_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_PAT" \
            "https://api.github.com/repos/$GITHUB_REPO/actions/secrets/public-key")
          
          if echo "$PUBLIC_KEY_RESPONSE" | grep -q '"key"'; then
            PUBLIC_KEY=$(echo "$PUBLIC_KEY_RESPONSE" | jq -r '.key')
            KEY_ID=$(echo "$PUBLIC_KEY_RESPONSE" | jq -r '.key_id')
            
            # Create encryption script
            cat > /tmp/encrypt_secret.py << 'PYEOF'
import base64
import sys
from nacl import encoding, public
from nacl.public import SealedBox

def encrypt_secret(public_key_b64, secret_value):
    public_key = public.PublicKey(public_key_b64.encode("utf-8"), encoder=encoding.Base64Encoder())
    sealed_box = SealedBox(public_key)
    encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
    return base64.b64encode(encrypted).decode("utf-8")

if __name__ == "__main__":
    public_key = sys.argv[1]
    secret = sys.argv[2]
    encrypted = encrypt_secret(public_key, secret)
    print(encrypted)
PYEOF
            
            # Create secrets
            echo "Creating GitHub secrets..."
            
            # AZURE_CLIENT_ID
            ENCRYPTED_CLIENT_ID=$(python3 /tmp/encrypt_secret.py "$PUBLIC_KEY" "$CLIENT_ID")
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_PAT" \
              -H "Content-Type: application/json" \
              -d "{\"encrypted_value\":\"$ENCRYPTED_CLIENT_ID\",\"key_id\":\"$KEY_ID\"}" \
              "https://api.github.com/repos/$GITHUB_REPO/actions/secrets/AZURE_CLIENT_ID"
            
            # AZURE_TENANT_ID  
            ENCRYPTED_TENANT_ID=$(python3 /tmp/encrypt_secret.py "$PUBLIC_KEY" "$TENANT_ID")
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_PAT" \
              -H "Content-Type: application/json" \
              -d "{\"encrypted_value\":\"$ENCRYPTED_TENANT_ID\",\"key_id\":\"$KEY_ID\"}" \
              "https://api.github.com/repos/$GITHUB_REPO/actions/secrets/AZURE_TENANT_ID"
            
            # AZURE_SUBSCRIPTION_ID
            ENCRYPTED_SUBSCRIPTION_ID=$(python3 /tmp/encrypt_secret.py "$PUBLIC_KEY" "$SUBSCRIPTION_ID")
            curl -s -X PUT \
              -H "Authorization: token $GITHUB_PAT" \
              -H "Content-Type: application/json" \
              -d "{\"encrypted_value\":\"$ENCRYPTED_SUBSCRIPTION_ID\",\"key_id\":\"$KEY_ID\"}" \
              "https://api.github.com/repos/$GITHUB_REPO/actions/secrets/AZURE_SUBSCRIPTION_ID"
            
            echo "✅ SUCCESS: GitHub OIDC secrets created!"
            echo "Secrets: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID"
          else
            echo "❌ Failed to get repository public key"
          fi
        else
          echo "❌ GitHub API access failed"
        fi
      else
        echo "=== MANUAL GITHUB SECRETS SETUP ==="
        echo "No GitHub PAT provided - manual setup required"
      fi
      
      echo ""
      echo "=== OIDC SETUP COMPLETE ==="
      echo "Client ID: $CLIENT_ID"
      echo "Tenant ID: $TENANT_ID"  
      echo "Subscription ID: $SUBSCRIPTION_ID"
      echo ""
      echo "GitHub Actions OIDC configuration:"
      echo "1. Go to: https://github.com/$GITHUB_REPO/settings/secrets/actions"
      echo "2. Add these secrets (if not done automatically):"
      echo "   - AZURE_CLIENT_ID: $CLIENT_ID"
      echo "   - AZURE_TENANT_ID: $TENANT_ID"
      echo "   - AZURE_SUBSCRIPTION_ID: $SUBSCRIPTION_ID"
      echo ""
      echo "GitHub Actions workflow example:"
      echo "- uses: azure/login@v2"
      echo "  with:"
      echo "    client-id: \${{ secrets.AZURE_CLIENT_ID }}"
      echo "    tenant-id: \${{ secrets.AZURE_TENANT_ID }}"
      echo "    subscription-id: \${{ secrets.AZURE_SUBSCRIPTION_ID }}"
      echo ""
      echo "App URL: https://$(az webapp show --name $WEBAPP_NAME --resource-group $RG_NAME --query defaultHostName -o tsv)"
    '''
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
}

output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output webAppName string = webApp.name
output resourceGroupName string = resourceGroup().name

// OIDC outputs for GitHub Actions
output clientId string = 'Will be created by deployment script'
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output gitHubRepo string = gitHubRepo
output gitHubBranch string = gitHubBranch