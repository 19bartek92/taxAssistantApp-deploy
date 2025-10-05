# Automated Workflow Trigger Approach

## Overview
This approach implements a fully automated deployment pipeline where:
1. Bicep creates Azure infrastructure and OIDC setup
2. Deployment script automatically triggers GitHub Actions workflow via API
3. GitHub Actions workflow uses OIDC to deploy the application

## How It Works

### 1. Infrastructure Deployment
- Creates App Service, Key Vault, and secrets
- Creates Entra Application with federated identity credentials
- Assigns Contributor role to service principal

### 2. Automatic Workflow Trigger
If GitHub PAT is provided, the deployment script:
- Calls GitHub Actions API: `/repos/{owner}/{repo}/actions/workflows/deploy.yml/dispatches`
- Passes OIDC parameters as workflow inputs
- Workflow starts automatically after infrastructure is ready

### 3. Application Deployment
The GitHub Actions workflow:
- Uses OIDC authentication (no secrets needed)
- Builds and publishes .NET application
- Deploys to Azure Web App using provided parameters

## Required Parameters

### GitHub PAT Requirements
For automatic workflow trigger, provide a GitHub PAT with:
- **Scope:** `workflow: write` (fine-grained token)
- **Repository:** Your application repository

### Manual Trigger Alternative
If no PAT is provided:
- Infrastructure will be created successfully
- Deployment script shows manual trigger instructions
- Go to GitHub Actions and trigger workflow manually

## Workflow Inputs
The workflow receives these inputs from the deployment script:
- `clientId`: Azure Client ID for OIDC
- `tenantId`: Azure Tenant ID
- `subscriptionId`: Azure Subscription ID
- `resourceGroup`: Resource group name
- `webAppName`: Web app name

## Benefits
- ✅ **No secrets in repository** - uses OIDC authentication
- ✅ **Fully automated** - single "Deploy to Azure" click
- ✅ **Secure** - federated identity credentials
- ✅ **Flexible** - supports both automatic and manual trigger
- ✅ **Transparent** - clear logging and status updates

## Prerequisites
- User Access Administrator role on subscription
- Application Administrator role in Azure AD tenant
- GitHub repository with deploy.yml workflow
- Optional: GitHub PAT for automatic trigger

## Usage
1. Click "Deploy to Azure" button
2. Provide required parameters including GitHub PAT (optional)
3. Infrastructure deploys automatically
4. GitHub Actions workflow starts automatically (if PAT provided)
5. Application is deployed and ready to use

## Troubleshooting

### Workflow Not Triggered
- Check GitHub PAT has `workflow: write` permission
- Verify repository and branch parameters are correct
- Check deployment script logs for API response

### OIDC Authentication Failed
- Verify federated identity credentials were created
- Check client ID matches in workflow inputs
- Ensure correct repository and branch in subject claim

### Permission Errors
- Check deployment identity has required Azure roles
- Verify User Access Administrator and Application Administrator roles