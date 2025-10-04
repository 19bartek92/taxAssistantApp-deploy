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

@description('Git repository URL')
param repositoryUrl string = 'https://github.com/19bartek92/taxAssistantApp.git'

@description('Git repository branch')
param repositoryBranch string = 'main'

@description('NSA Search API Key')
@secure()
param nsaSearchApiKey string = ''

@description('NSA Detail API Key')
@secure()
param nsaDetailApiKey string = ''

@description('GitHub PAT used to configure Deployment Center')
@secure()
param gitHubPat string

@description('Key Vault Name')
param keyVaultName string = 'kv-${uniqueString(resourceGroup().id)}'

@description('Enable Key Vault recovery (for existing deleted vaults)')
param enableKeyVaultRecovery bool = false

@description('Force application redeployment (change this value to trigger update)')
param forceRedeploy string = utcNow('yyyyMMddHHmmss')

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
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'KeyVaultUri'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'DEPLOYMENT_TIMESTAMP'
          value: forceRedeploy
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
}

// Additional role for Website Contributor to manage deployment sources
resource websiteContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, 'de139f84-1756-47ae-9be6-808fbbe84772')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772') // Website Contributor
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource setGitHubDeployment 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'setupGitHubDeployment'
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
    azCliVersion: '2.53.0'
    environmentVariables: [
      { name: 'WEBAPP_NAME', value: webApp.name }
      { name: 'RG_NAME', value: resourceGroup().name }
      { name: 'GITHUB_PAT', secureValue: gitHubPat }
      { name: 'REPO_URL', value: repositoryUrl }
      { name: 'BRANCH', value: repositoryBranch }
    ]
    scriptContent: '''
      set -e
      echo "Configuring GitHub deployment using Azure CLI..."
      echo "WEBAPP_NAME: $WEBAPP_NAME"
      echo "RG_NAME: $RG_NAME"
      echo "REPO_URL: $REPO_URL"
      echo "BRANCH: $BRANCH"
      
      # Step 1: Save PAT token in App Service
      echo "Setting GitHub PAT token..."
      az webapp deployment source update-token \
        --name $WEBAPP_NAME \
        --resource-group $RG_NAME \
        --git-token $GITHUB_PAT || echo "update-token FAILED: $?"
      
      # Step 2: Configure source control (without manual-integration flag)
      echo "Configuring source control..."
      az webapp deployment source config \
        --name $WEBAPP_NAME \
        --resource-group $RG_NAME \
        --repo-url $REPO_URL \
        --branch $BRANCH \
        --repository-type github || echo "config FAILED: $?"
      
      # Step 3: Trigger initial deployment
      echo "Triggering initial deployment..."
      az webapp deployment source sync \
        --name $WEBAPP_NAME \
        --resource-group $RG_NAME || echo "sync FAILED: $?"
      
      echo "GitHub deployment configured and initial sync completed!"
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