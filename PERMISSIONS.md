# Required Permissions for OIDC Deployment

## Overview
The OIDC deployment template requires elevated permissions to create Azure AD applications and assign RBAC roles. These permissions cannot be granted automatically through the template and must be assigned manually.

## Required Roles

### 1. User Access Administrator (Subscription Level)
**Role ID:** `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`
**Scope:** Subscription
**Purpose:** Required to assign Contributor role to the created service principal

### 2. Application Administrator (Azure AD Tenant Level)  
**Role ID:** `9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3`
**Scope:** Azure AD Tenant
**Purpose:** Required to create Azure AD applications and service principals

## How to Assign Permissions

### Option 1: Azure Portal
1. Navigate to Subscriptions → Your Subscription → Access control (IAM)
2. Add role assignment: User Access Administrator
3. Navigate to Azure Active Directory → Roles and administrators
4. Search for "Application Administrator" and assign to the user/service principal

### Option 2: Azure CLI
```bash
# Get the deployment identity principal ID
PRINCIPAL_ID=$(az identity show --name "deployment-identity" --resource-group "your-resource-group" --query principalId -o tsv)

# Assign User Access Administrator at subscription level
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "User Access Administrator" \
  --scope "/subscriptions/$(az account show --query id -o tsv)"

# Assign Application Administrator in Azure AD
az rest \
  --method POST \
  --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" \
  --body "{\"principalId\":\"$PRINCIPAL_ID\",\"roleDefinitionId\":\"9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3\",\"directoryScopeId\":\"/\"}"
```

## Alternative: Manual OIDC Setup

If you cannot assign the required permissions, you can set up OIDC manually:

1. **Create Azure AD Application:**
   ```bash
   az ad app create --display-name "GitHub-OIDC-YourApp"
   ```

2. **Create Service Principal:**
   ```bash
   az ad sp create --id <app-id>
   ```

3. **Add Federated Identity Credential:**
   ```bash
   az rest --method POST \
     --uri "https://graph.microsoft.com/v1.0/applications/<app-object-id>/federatedIdentityCredentials" \
     --body '{
       "name": "github-oidc",
       "issuer": "https://token.actions.githubusercontent.com", 
       "subject": "repo:owner/repo:ref:refs/heads/main",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```

4. **Assign Contributor Role:**
   ```bash
   az role assignment create \
     --assignee <app-id> \
     --role "Contributor" \
     --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>"
   ```

5. **Add GitHub Secrets:**
   - `AZURE_CLIENT_ID`: Application ID
   - `AZURE_TENANT_ID`: Tenant ID  
   - `AZURE_SUBSCRIPTION_ID`: Subscription ID

## Deployment Behavior

- **With Permissions:** Full automated OIDC setup
- **Without Permissions:** Deployment will fail with authorization errors
- **Partial Permissions:** May partially succeed but OIDC won't work

## Security Considerations

- User Access Administrator is a highly privileged role
- Application Administrator can create/modify AD applications
- Consider using Privileged Identity Management (PIM) for just-in-time access
- Remove elevated permissions after deployment if not needed long-term