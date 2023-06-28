# Azure Synapse Integration

The Azure Synapse integration feature enables management and deployment of Azure Synapse assets (pipelines, datasets, scripts, triggers, and linked services) alongside Dataverse solutions within the ALM pipeline.

## Overview

This feature allows you to:
- Export Synapse assets from a separate Azure DevOps repository
- Include them in your build artifacts
- Deploy them to Azure Synapse workspaces across different environments
- Maintain version control and automated deployments for your data integration pipelines

## How It Works

The Azure Synapse integration operates in three phases:

### 1. Export Phase

During the EXPORT pipeline, Synapse assets are cloned from a dedicated Synapse Development repository and filtered by folder name:

- Clones from the repository specified in `SynapseRepositoryUrl` configuration
- Filters assets by the `folder` property in Synapse definitions
- Organizes assets into local folders: `datasets/`, `pipelines/`, `scripts/`, `triggers/`, and `linked-services/`
- Extracts SQL script content from JSON definitions into `.sql` files for better source control
- Commits the filtered assets to your repository

### 2. Build Phase

During the BUILD pipeline, Synapse assets are packaged into build artifacts:

- Copies the Synapse asset folders (`datasets/`, `pipelines/`, `scripts/`, `triggers/`, `linked-services/`) to the build output directory

### 3. Deploy Phase

During the DEPLOY pipeline, Synapse assets are deployed to the target Azure Synapse workspace:

- **Managed Private Endpoints**: Creates or updates managed private endpoints
- **Linked Services**: Creates or updates linked services with credentials sourced from environment variables
- **Datasets**: Creates or updates datasets, replacing workspace-specific names
- **SQL Scripts**: Creates SQL scripts and executes them, replacing environment-specific database names
- **Pipelines**: Creates pipelines with environment-specific replacements
- **Triggers**: Creates triggers
- **Cleanup**: Deletes assets that exist in the workspace but are no longer in the source

## Configuration

### Enable Synapse Integration

In your `alm-config.psd1` file, add the Synapse configuration:

```powershell
@{
    solutions = @(...)
    
    # Azure Synapse configuration
    SynapseRepositoryUrl = 'https://user@dev.azure.com/org/project/_git/SynapseRepo'
    SynapseFolders = @(
        'DataverseIntegration',
        'Reporting'
    )
}
```

**Required Configuration:**
- **`SynapseRepositoryUrl`** (required when using Synapse): The full git clone URL for your Synapse Development repository. This should include authentication if needed (e.g., `https://username@dev.azure.com/org/project/_git/repo`). The pipeline will use `SYSTEM_ACCESSTOKEN` for authentication in Azure DevOps pipelines.
- **`SynapseFolders`** (required): Array of folder names to export and deploy. Only Synapse assets with their folder property matching these names will be included.

**Example URLs:**
- Azure DevOps: `https://myorg@dev.azure.com/myorg/MyProject/_git/Synapse-Development`
- GitHub: `https://github.com/myorg/synapse-repo.git`

This configuration tells the pipeline to export and deploy all Synapse assets that have their folder property set to either `DataverseIntegration` or `Reporting`.

### Linked Service Configuration

#### Include/Exclude Filters

Control which linked services are exported and deployed:

```powershell
@{
    SynapseFolders = @('DataverseIntegration')
    
    # Optional: Include only specific linked services (wildcard patterns)
    SynapseLinkedServicesInclude = @(
        'ls-dataverse-*',
        'ls-sharepoint-*'
    )
    
    # Optional: Exclude specific linked services (wildcard patterns)
    # Default excludes WorkspaceDefault linked services
    SynapseLinkedServicesExclude = @(
        '*WorkspaceDefault*',
        'ls-legacy-*'
    )
}
```

#### Linked Service Credentials

During deployment, linked service credentials are read from environment variables. The naming pattern is:

```
SYNAPSELINKSVC_<LinkedServiceName>_<PropertyName>
```

Where spaces in the linked service name are replaced with underscores.

**Example:**

For a linked service named "Dataverse Production" with properties `servicePrincipalId`, `tenant`, and `servicePrincipalCredential`:

```
SYNAPSELINKSVC_Dataverse_Production_servicePrincipalId
SYNAPSELINKSVC_Dataverse_Production_tenant
SYNAPSELINKSVC_Dataverse_Production_servicePrincipalCredential
```

These environment variables should be configured in your Azure DevOps variable groups or GitHub environment variables.

**Supported authentication types:**
- Service Principal with Key (`servicePrincipalCredentialType: ServicePrincipalKey`)
- SQL Authentication (`authenticationType: SQL`)
- Service Principal (`authenticationType: ServicePrincipal`)

### Managed Private Endpoints

Configure managed private endpoints that should be created in the Synapse workspace:

```powershell
@{
    SynapseFolders = @('DataverseIntegration')
    
    SynapseManagedPrivateEndpoints = @(
        @{
            Name = 'endpoint-dataverse-$(EnvironmentName)'
            Definition = @'
{
    "type": "Microsoft.Synapse/workspaces/managedVirtualNetworks/managedPrivateEndpoints",
    "properties": {
        "privateLinkResourceId": "/subscriptions/$(SubscriptionId)/resourceGroups/$(ResourceGroup)/providers/Microsoft.PowerApps/environments/$(EnvironmentId)",
        "groupId": "dataverse"
    }
}
'@
        }
    )
}
```

The `Name` and `Definition` support environment variable placeholders that will be replaced during deployment.

## Environment Variables

The following environment variables must be set during deployment:

| Variable | Description | Required |
|----------|-------------|----------|
| `SYNAPSE_WORKSPACENAME` | Name of the Azure Synapse workspace | Yes |
| `SYSTEM_ACCESSTOKEN` | Azure DevOps access token for git clone (auto-provided in ADO pipelines) | No |
| `SYNAPSELINKSVC_*` | Linked service credentials (see above) | Yes (if using linked services) |

## Dynamic Replacements

During deployment, the following replacements are automatically applied:

### Datasets
- `*-WorkspaceDefault*` linked service references are updated to match the current workspace name

### SQL Scripts
- `dataverse_[a-z0-9_-]+` database names are replaced with the actual Dataverse database name in the Synapse workspace

### Pipelines
- `dataverse_[a-z0-9_]+` database names are replaced with the actual Dataverse database name
- `asw-.*-d365cs.*-ondemand` Synapse workspace URLs are replaced with the current workspace name

## Folder Structure

After export, your repository will contain:

```
datasets/
  DataverseIntegration/
    ds_Account.json
    ds_Contact.json
  Reporting/
    ds_SalesReport.json
pipelines/
  DataverseIntegration/
    pl_SyncAccounts.json
scripts/
  DataverseIntegration/
    CreateIntegrationViews.sql
    RefreshMaterializedView.sql
triggers/
  DataverseIntegration/
    tr_DailySync.json
linked-services/
  ls-dataverse-prod.json
  ls-sharepoint-docs.json
```

## Prerequisites

### Required PowerShell Modules

The following modules are automatically imported during deployment:
- `Az.Synapse`
- `SQLServer`

### Required Azure Permissions

The service principal or user running the deployment must have:
- **Synapse Administrator** role on the target Synapse workspace
- **Contributor** or **Reader** permissions on the resource group containing the workspace
- Access to read from the Synapse Development repository (for export)

### Azure CLI

The deployment process uses the Azure CLI (`az synapse` commands) for certain operations. Ensure Azure CLI is installed and available in the pipeline agent.

## Limitations

- Trigger management (start/stop) is not automated
- Only certain linked service authentication types are supported
- SQL script execution occurs in the `integration` database only

## Troubleshooting

### "SynapseRepositoryUrl must be configured in alm-config.psd1"
Ensure the `SynapseRepositoryUrl` parameter is set in your `alm-config.psd1` when using `SynapseFolders`. Example:
```powershell
SynapseRepositoryUrl = 'https://user@dev.azure.com/org/project/_git/repo'
```

### "SYNAPSE_WORKSPACENAME not found"
Ensure the `SYNAPSE_WORKSPACENAME` environment variable is set in your pipeline configuration.

### "SYNAPSELINKSVC_* not found"
Check that all required linked service credential environment variables are defined with the correct naming pattern.

### Git clone failures during export
Verify that the service principal has access to the Synapse Development repository and that `SYSTEM_ACCESSTOKEN` is available.

### Linked service creation failures
- Verify the environment variables contain correct values
- Check that the authentication type matches the credential properties being set
- Review Azure permissions on the Synapse workspace
