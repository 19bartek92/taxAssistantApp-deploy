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
param sku string = 'F1'


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

resource emailPublishProfile 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'emailPublishProfile'
  location: location
  kind: 'AzureCLI'
  dependsOn: [
    webApp
    keyVaultAccessPolicy
    nsaSearchKeySecret
    nsaDetailKeySecret
    managedIdentity
    roleAssignment
  ]
  properties: {
    azCliVersion: '2.76.0'
    environmentVariables: [
      { name: 'WEBAPP_NAME', value: webApp.name }
      { name: 'RG_NAME', value: resourceGroup().name }
      { name: 'EMAIL_TO', value: '19bartek92@gmail.com' }
      { name: 'GITHUB_PAT', secureValue: gitHubPat }
      { name: 'GITHUB_REPO', value: '19bartek92/taxAssistantApp' }
    ]
    scriptContent: '''
      set -e
      echo "Getting publish profile for webapp: $WEBAPP_NAME"
      
      # Install GitHub CLI if GitHub PAT is provided
      if [ -n "$GITHUB_PAT" ] && [ "$GITHUB_PAT" != "" ]; then
        echo "Installing GitHub CLI for automatic secret creation..."
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt update
        apt install gh -y
        echo "GitHub CLI installed successfully"
      fi
      
      # Get publish profile
      echo "Downloading publish profile..."
      PUBLISH_PROFILE=$(az webapp deployment list-publishing-profiles --name $WEBAPP_NAME --resource-group $RG_NAME --xml)
      
      if [ -z "$PUBLISH_PROFILE" ]; then
        echo "ERROR: Failed to get publish profile"
        exit 1
      fi
      
      echo "Publish profile retrieved successfully"
      
      # Save to file
      echo "$PUBLISH_PROFILE" > /tmp/publish-profile.xml
      
      # Get webapp URL
      WEBAPP_URL=$(az webapp show --name $WEBAPP_NAME --resource-group $RG_NAME --query "defaultHostName" -o tsv)
      
      # Create email content
      cat > /tmp/email-content.txt << EOF
Subject: TaxAssistant App Deployment Profile - $WEBAPP_NAME

Your TaxAssistant application has been successfully deployed to Azure!

App Service Name: $WEBAPP_NAME
Resource Group: $RG_NAME
URL: https://$WEBAPP_URL

Publish Profile is attached.

To deploy your application:
1. Use the attached publish profile with Visual Studio or VS Code
2. Or use GitHub Actions with the publish profile as a secret

Next steps:
- Configure GitHub Actions for automated deployment
- Update application code and deploy using the profile

Generated automatically by Azure deployment script.
EOF

      echo "Email content prepared"
      echo "Webapp URL: https://$WEBAPP_URL"
      echo "Publish profile saved to /tmp/publish-profile.xml"
      echo "Email would be sent to: $EMAIL_TO"
      
      # Log the profile for debugging
      echo "=== PUBLISH PROFILE START ==="
      cat /tmp/publish-profile.xml
      echo "=== PUBLISH PROFILE END ==="
      
      # Send email using EmailJS public API (no auth required for basic usage)
      echo "Sending email with publish profile..."
      
      # Encode publish profile for JSON
      PUBLISH_PROFILE_ENCODED=$(cat /tmp/publish-profile.xml | base64 -w 0)
      
      # Create JSON payload for email
      cat > /tmp/email-payload.json << EOF
{
  "service_id": "default_service",
  "template_id": "template_deployment",
  "user_id": "public",
  "template_params": {
    "to_email": "$EMAIL_TO",
    "subject": "TaxAssistant App Deployment Profile - $WEBAPP_NAME",
    "message": "Your TaxAssistant application has been successfully deployed to Azure!\n\nApp Service Name: $WEBAPP_NAME\nResource Group: $RG_NAME\nURL: https://$WEBAPP_URL\n\nPublish Profile (base64 encoded):\n$PUBLISH_PROFILE_ENCODED\n\nTo use the profile:\n1. Decode the base64 content\n2. Save as .pubxml file\n3. Use with Visual Studio or GitHub Actions\n\nGenerated automatically by Azure deployment."
  }
}
EOF

      # Try to send email via simple SMTP relay service
      echo "Attempting to send email..."
      
      # Method 1: Try sending via SMTP using curl (if available)
      echo "Method 1: Attempting SMTP email..."
      
      # Create email body
      cat > /tmp/email-body.txt << 'EMAILEOF'
Subject: TaxAssistant Deployment Profile
To: 19bartek92@gmail.com
From: azure-deploy@noreply.com
Content-Type: text/plain

Your TaxAssistant application has been successfully deployed to Azure!

App Service Name: ${WEBAPP_NAME}
Resource Group: ${RG_NAME}  
URL: https://${WEBAPP_URL}

Publish Profile (base64 encoded - decode and save as .pubxml):
${PUBLISH_PROFILE_ENCODED}

To use the profile:
1. Copy the base64 content above
2. Decode it: echo "BASE64_CONTENT" | base64 -d > profile.pubxml
3. Use with Visual Studio or add as GitHub secret

Generated automatically by Azure deployment script.
EMAILEOF

      # Replace variables in email
      sed -i "s/\${WEBAPP_NAME}/$WEBAPP_NAME/g" /tmp/email-body.txt
      sed -i "s/\${RG_NAME}/$RG_NAME/g" /tmp/email-body.txt  
      sed -i "s/\${WEBAPP_URL}/$WEBAPP_URL/g" /tmp/email-body.txt
      sed -i "s/\${PUBLISH_PROFILE_ENCODED}/$PUBLISH_PROFILE_ENCODED/g" /tmp/email-body.txt
      
      # Email sending disabled for now - publish profile is logged above
      echo "Email sending temporarily disabled"
      echo "Publish profile is available in the logs above"
      
      # GitHub Secret Setup (automatic if PAT provided, manual otherwise)
      if [ -n "$GITHUB_PAT" ] && [ "$GITHUB_PAT" != "" ]; then
        echo "=== AUTOMATIC GITHUB SECRET SETUP ==="
        echo "GitHub PAT provided, attempting automatic secret creation..."
        
        # Test GitHub API access
        TEST_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_PAT" \
          "https://api.github.com/repos/$GITHUB_REPO")
        
        if echo "$TEST_RESPONSE" | grep -q '"name"'; then
          echo "GitHub API access successful"
          
          # Create GitHub secret with publish profile using GitHub CLI
          echo "Creating GitHub secret AZURE_WEBAPP_PUBLISH_PROFILE..."
          
          # Set up GitHub CLI authentication
          echo "$GITHUB_PAT" | gh auth login --with-token
          
          # Create the secret using GitHub CLI (handles encryption automatically)
          if echo "$PUBLISH_PROFILE" | gh secret set AZURE_WEBAPP_PUBLISH_PROFILE --repo "$GITHUB_REPO"; then
            echo "✅ SUCCESS: GitHub secret AZURE_WEBAPP_PUBLISH_PROFILE created!"
            echo "Secret is ready for use in GitHub Actions"
            
            # Verify the secret was created
            if gh secret list --repo "$GITHUB_REPO" | grep -q "AZURE_WEBAPP_PUBLISH_PROFILE"; then
              echo "✅ VERIFIED: Secret appears in repository secrets list"
            fi
          else
            echo "❌ FAILED to create GitHub secret using GitHub CLI"
            echo "Falling back to manual setup..."
          fi
        else
          echo "GitHub API access failed: $TEST_RESPONSE"
          echo "Falling back to manual setup..."
        fi
      else
        echo "=== MANUAL GITHUB SECRET SETUP ==="
        echo "No GitHub PAT provided - manual setup required"
      fi
      
      echo ""
      echo "=== GITHUB SECRET SETUP INSTRUCTIONS ==="
      echo "Repository: $GITHUB_REPO"
      echo ""
      echo "1. Go to: https://github.com/$GITHUB_REPO/settings/secrets/actions"
      echo "2. Click 'New repository secret'"  
      echo "3. Name: AZURE_WEBAPP_PUBLISH_PROFILE"
      echo "4. Value: Copy the publish profile XML from === PUBLISH PROFILE START === section above"
      echo "5. Click 'Add secret'"
      echo ""
      echo "GitHub Actions usage:"
      echo "- uses: azure/webapps-deploy@v2"
      echo "  with:"
      echo "    app-name: '$WEBAPP_NAME'"
      echo "    publish-profile: \${{ secrets.AZURE_WEBAPP_PUBLISH_PROFILE }}"
      echo ""
      echo "Webapp URL: https://$WEBAPP_URL"
      echo "============================================"
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