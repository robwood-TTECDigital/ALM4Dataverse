# Dataverse-ALM

## TTEC Digital fork of ALM4Dataverse

This repo contains a TTEC Digital custom fork of the ALM4Dataverse OSS project.
See the main content from that project below for info on the bulk of what this does.

This fork adds:

- backwards compatibility with the previous Dataverse-ALM implementation and a migration process to assist with updating configuration.
- TTEC Digital proprietary extensions:
  - Solution validation rules
  - Azure Synapse component management
  - Schema migration tracking.

Upstream ALM4Dataverse now includes GitHub Actions support. The older fork-specific GitHub workflow model is deprecated.
See `ttec-digital/docs/github-actions-setup.md` for migration guidance if you previously adopted the fork GitHub setup.

See the docs in `ttec-digital/docs` for further info on these features.

## Upgrading from v1

1. Clone your repo to a local workspace.

2. Run `ttec-digital/migrate-azdo-repo.ps1` for Azure DevOps based repos. If you were using the older fork-specific GitHub Actions support, use `ttec-digital/migrate-github-repo.ps1` and then follow `ttec-digital/docs/github-actions-setup.md` to complete the move to the upstream GitHub workflow model.

3. Any custom pre/post X scripts may need to adapt slightly:

- Scripts require `context` parameter instead of individual parameters. See the config docs.
- Put PowerShell module requirements into `alm-config.psd1` and remove any commands to install and load them.

1. Commit and push the changes back up to the remote.

---
![ALM4Dataverse](logo.png)

This repo contains:
- an advanced and extendable application lifecycle management (ALM/CI-CD)
implementation for Dataverse.
- a set of process documentation and guidance on how to use and extend it.

Supports both **Azure DevOps** and **GitHub Actions** (PREVIEW).

Features:

- Handles zero to many Dataverse solutions per repo.
- Correctly determines the install/upgrade/update method for each solution based on the state of the target environment
- Supports branches, PRs etc with minimal re-configuration
- GitHub builds publish the existing deployment artifacts as separate GitHub Release assets
- GitHub deployments prefer Release assets and fall back to the BUILD artifact
- GitHub deployment and cleanup flows preserve branch/build identity for safe promotion and rollback
- Supports including config/system/lookup data
- Easy to extend using the extensive PowerShell ecosystem.


## Getting Started

### GitHub Actions

1) Run the automated setup script in Windows PowerShell:

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1 | iex
   ```

    The setup script automatically detects whether GitHub environment approvals are
    available for your repository and chooses the matching deployment strategy
    (`environment-approval` or `manual-gate-tag` with prefixed repo-level credentials and manual promotion from stage 1).

   Or follow the [GitHub Actions Setup Guide](docs/setup/github-setup.md) to configure manually.

### Azure DevOps

1) Run the automated setup script in Windows PowerShell:

   ```powershell
   iwr https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1 | iex
   ```

   Or follow the [Manual Setup Guide](docs/setup/azdo-manual-setup.md) if you prefer manual configuration.
   See the [Automated Setup Guide](docs/setup/azdo-automated-setup.md) for details.


## Documentation

- [Frequently Asked Questions](docs/faqs.md)

### Initial Setup

#### GitHub Actions
- [GitHub Actions Setup Guide](docs/setup/github-setup.md)
- [GitHub Variables & Secrets](docs/setup/github-variables.md)

#### Azure DevOps
- [Azure DevOps Organization Requirements](docs/setup/azdo-organisation-requirements.md)
- [Automated Setup](docs/setup/azdo-automated-setup.md)
- [Manual Setup](docs/setup/azdo-manual-setup.md)

#### Usage Instructions

- [Branching strategies](docs/usage/branching-strategies.md) - choosing between
  a simple `main`-only workflow and a `main`/`develop` workflow with PRs into `main`
- [Exporting changes](docs/usage/exporting-changes.md) - `EXPORT` pipeline/workflow
  Capturing changes from your dev environments into source control.
- [Building releases](docs/usage/building-releases.md) - `BUILD` pipeline/workflow
  Generating Actions artifacts and GitHub Releases for later deployment.
- [Deploying](docs/usage/deploying.md) - `DEPLOY-<branchname>` pipeline/workflow
  Deploying Release assets, with BUILD-artifact fallback, to environments in a controlled sequence
- [Cleaning up GitHub Releases](docs/usage/building-releases.md#github-release-cleanup) - branch-aware cleanup of build Releases
- [Importing changes](docs/usage/importing-changes.md) - `IMPORT` pipeline/workflow
  Seeding or updating dev environment from source control.

### Configuration Reference

- [ALM Configuration](docs/config/alm-config.md) - `alm-config.psd1`

#### GitHub Actions
- [GitHub Secrets & Variables](docs/config/github-secrets.md)

#### Azure DevOps
- [Environment Variable Group](docs/config/azdo-environment-variable-group.md)
- [Service Connection Configuration](docs/config/azdo-environment-service-connection.md)

#### Example 'Hook' Extensions

- [Data import and export](docs/config/example-hooks/data-import-export.md) (for example config/system data)
- [Organisation/environment settings](docs/config/example-hooks/organization-settings.md) (for example enabling the 'PCF allowed' switch)