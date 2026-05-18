# GitHub Actions Setup Guide

This guide describes how to set up ALM4Dataverse for use with GitHub Actions, using **Workload Identity Federation (WIF)** — the recommended, secretless authentication method.

> **Also supported**: Client secret authentication (see [Client Secret option](#client-secret-option)) for scenarios where WIF is not suitable.

## Overview

The GitHub Actions setup involves:

1. [Prerequisites](#1-prerequisites)
2. [App Registration in Entra ID](#2-app-registration-in-entra-id)
3. [Configure Federated Credentials](#3-configure-federated-credentials)
4. [Create Application User in Dataverse](#4-create-application-user-in-dataverse)
5. [GitHub Environments and Variables](#5-github-environments-and-variables)
6. [Workflow Files](#6-workflow-files)

---

## 1. Prerequisites

- Access to an Azure Entra ID (formerly Azure AD) tenant with permission to create App Registrations
- Access to your Dataverse environments with System Administrator role
- A GitHub repository containing your Dataverse solution source code and the workflow files from `copy-to-your-repo/.github/workflows/`
- The ALM4Dataverse repository accessible as a GitHub Actions action source (public or accessible to your runner)

---

## 2. App Registration in Entra ID

For each Dataverse environment, create a dedicated App Registration:

1. Navigate to the [Azure Portal](https://portal.azure.com)
2. Go to **Entra ID** > **App registrations**
3. Click **New registration**
4. Enter a name: `{ProjectName} - {EnvironmentName} - deployment` (e.g., `MyProject - PROD - deployment`)
5. Select **Accounts in this organizational directory only**
6. Click **Register**
7. Note the **Application (client) ID** and **Directory (tenant) ID** — you will need these later

> **Tip**: Create separate App Registrations per environment (e.g., separate for Dev, TEST, UAT, PROD) to minimise blast radius.

---

## 3. Configure Federated Credentials

Federated credentials allow GitHub Actions to authenticate as your App Registration without a client secret, using an OIDC token issued by GitHub.

### 3.1 Choose a Subject Pattern

The **subject** controls which GitHub Actions contexts can authenticate. Choose the pattern that best fits your security requirements:

| Option | Subject pattern | Use case |
|--------|----------------|----------|
| **Environment (recommended)** | `repo:{org}/{repo}:environment:{environment-name}` | Scoped to a named GitHub Environment |
| **Branch** | `repo:{org}/{repo}:ref:refs/heads/{branch}` | Scoped to a specific branch |
| **Pull Request** | `repo:{org}/{repo}:pull_request` | Scoped to PR events |

> **Recommendation**: Use environment-scoped subjects. This ties authentication to GitHub Environment protection rules, giving you approval gates that also enforce who can authenticate.

The environment names used by the workflows in this project follow the patterns:
- `DEV_{branch}` — export and import environments (e.g., `DEV_main`)
- Custom — deployment environments (e.g., `SAT_main`, `UAT_main`, `PROD`)

### 3.2 Add the Federated Credential

For each App Registration and its corresponding GitHub environment:

1. In the App Registration, go to **Certificates & secrets**
2. Select the **Federated credentials** tab
3. Click **Add credential**
4. Select **GitHub Actions deploying Azure resources**
5. Fill in the details:
	- **Organisation**: Your GitHub organisation or username
	- **Repository**: Your repository name (without the org prefix)
	- **Entity type**: Select based on your choice above (e.g., **Environment**)
	- **GitHub environment name** (if entity = Environment): e.g., `DEV_main`, `PROD`
	- **Name**: A descriptive name, e.g., `GitHub-{org}-{repo}-{environment}` (alphanumeric and hyphens only)
	- **Audience**: `api://AzureADTokenExchange` (default — do not change)
6. Click **Add**

#### Example: Environment-scoped (recommended)

| Field | Value |
|-------|-------|
| Organisation | `my-org` |
| Repository | `MyProject` |
| Entity type | Environment |
| Environment name | `PROD` |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:my-org/MyProject:environment:PROD` |

#### Example: Branch-scoped

| Field | Value |
|-------|-------|
| Organisation | `my-org` |
| Repository | `MyProject` |
| Entity type | Branch |
| Branch | `main` |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:my-org/MyProject:ref:refs/heads/main` |

📖 **References**:
- [Configure a federated identity credential for a GitHub deployment](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust?pivots=identity-wif-apps-methods-azcli#github-actions)
- [Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)

---

## 4. Create Application User in Dataverse

For each Dataverse environment, create an application user for the App Registration:

1. Navigate to [Power Platform Admin Center](https://admin.powerplatform.microsoft.com)
2. Select your environment
3. Go to **Settings** > **Users + permissions** > **Application users**
4. Click **New app user**
5. Click **Add an app** and search for your App Registration by name
6. Select the **Business Unit** (typically root)
7. Add the **System Administrator** security role
8. Click **Create**

📖 **Reference**: [Create an application user](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

---

## 5. GitHub Environments and Variables

### 5.1 Create GitHub Environments

The workflows use GitHub Environments to scope credentials and optionally enforce approval gates.

For each environment (e.g., `DEV_main`, `SAT_main`, `PROD`):

1. In your GitHub repository, go to **Settings** > **Environments**
2. Click **New environment**
3. Enter the environment name (must match the federated credential subject you configured)
4. Optionally add protection rules:
	- **Required reviewers** — for non-dev environments, add deployment approvers
	- **Deployment branches** — restrict to specific branches

### 5.2 Set Environment Variables

For each GitHub Environment, add the following variables:

| Variable name | Description | Example value |
|---------------|-------------|---------------|
| `dataverseurl` | Dataverse environment URL | `https://yourorg-dev.crm.dynamics.com` |
| `dataverseapplicationid` | App Registration (client) ID | `3004eb1e-7a00-45e0-a1dc-6703735eac18` |
| `dataversetenantid` | Entra ID tenant ID | `d0b7d94e-4e91-4a0e-854b-2e43c9e2a27f` |

> **Note**: Variable names are case-sensitive. Use lowercase as shown above.

To add variables to a GitHub Environment:

1. Go to **Settings** > **Environments** > *{EnvironmentName}*
2. Under **Environment variables**, click **Add variable**
3. Add each variable above

### 5.3 Connection References and Environment Variables

For Dataverse connection references and environment variable values set during deployment, add additional variables following the naming conventions in [environment-variable-group.md](../config/environment-variable-group.md) — the same `DataverseConnRef_*` and `DataverseEnvVar_*` prefixes apply; add them to the corresponding GitHub Environment.

### 5.4 Client Secret Option

If you are using **client secret** authentication instead of WIF:

1. Add a secret to the GitHub Environment (or repository secrets):

	| Secret name | Description |
	|-------------|-------------|
	| `dataverseclientsecret` | Client secret value from the App Registration |

2. In your workflow files, change `authtype: WorkloadIdentityFederation` to `authtype: ClientSecret`
3. Remove `id-token: write` from the workflow permissions (it is no longer needed)

---

## 6. Workflow Files

Copy the files from `copy-to-your-repo/.github/workflows/` into the `.github/workflows/` folder of your application repository.

### Required permissions

For WIF to work, each workflow that connects to Dataverse **must** include the `id-token: write` permission. This is already set in the example files:

```yaml
permissions:
  contents: write
  id-token: write  # Required for Workload Identity Federation
```

> **Important**: `id-token: write` must be set in the **calling workflow**, not just the composite action. Do not remove it.

### Workflow summary

| File | Trigger | Purpose |
|------|---------|---------|
| `BUILD.yml` | Push / `workflow_dispatch` | Pack solutions into release artifacts |
| `EXPORT.yml` | `workflow_dispatch` | Export solution changes from a Dev environment |
| `DEPLOY.yml` | After BUILD / `workflow_dispatch` | Deploy artifacts to each environment |
| `IMPORT.yml` | `workflow_dispatch` | Import solutions into a Dev environment |

### Customising DEPLOY.yml

Update the environment matrix in `DEPLOY.yml` to match your environments:

```yaml
matrix:
  environment: ["SAT_main", "UAT_main", "PROD"]
```

Each entry must match:
- A GitHub Environment name (configured in step 5.1)
- A federated credential subject in Entra ID (configured in step 3.2)
- An `alm-config.psd1` environment reference (if applicable)

---

## Troubleshooting

### `AADSTS70021: No matching federated identity record found`

The OIDC token subject from GitHub does not match any federated credential configured on the App Registration. Verify that:
- The GitHub Environment name in the workflow matches the subject in the federated credential exactly (case-sensitive)
- The repository org/name is correct
- The entity type (Environment vs Branch) matches what GitHub is presenting

### `AADSTS700016: Application not found`

The `dataverseapplicationid` variable does not match a registered application in Entra ID, or it is in the wrong tenant. Check the value in the GitHub Environment variable.

### `DefaultAzureCredential authentication failed`

If `azure/login` succeeds but Dataverse connection fails, verify that the application user was created in the Dataverse environment with the System Administrator role.

---

## See Also

- [Manual Setup Guide](../setup/manual-setup.md) — Azure DevOps setup
- [Environment Variable Group Configuration](../config/environment-variable-group.md)
- [Environment Service Connection Configuration](../config/environment-service-connection.md)