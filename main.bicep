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

resource setGhToken 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'setupGithubToken'
  location: location
  kind: 'AzureCLI'
  dependsOn: [
    webApp
    keyVaultAccessPolicy
    nsaSearchKeySecret
    nsaDetailKeySecret
  ]
  properties: {
    azCliVersion: '2.53.0'
    environmentVariables: [
      { name: 'WEBAPP_NAME', value: webAppName }
      { name: 'RG_NAME', value: resourceGroup().name }
      { name: 'GITHUB_PAT', secureValue: gitHubPat }
      { name: 'REPO_URL', value: repositoryUrl }
      { name: 'BRANCH', value: repositoryBranch }
    ]
    scriptContent: '''
      az webapp deployment source update-token --git-token $GITHUB_PAT
      az webapp deployment source config --name $WEBAPP_NAME --resource-group $RG_NAME \
        --repo-url $REPO_URL --branch $BRANCH --manual-integration false
    '''
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
  }
}

output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output webAppName string = webApp.name
output resourceGroupName string = resourceGroup().name