# Dataverse-ALM 
## TTEC Digital fork of ALM4Dataverse

This repo contains a TTEC Digital custom fork of the ALM4Dataverse OSS project.
See the main content from that project below for info on the bulk of what this does.

This fork adds:


- backwards compatibility with the previous Dataverse-ALM implementation and a migration process to assist with updating configuration.
- TTEC Digital proprietary extensions:
   - GitHub (Actions) support with optional Workflow Identity Federation (no secrets)
   - Solution validation rules
   - Azure Synapse component management
   - Schema migration tracking.


See the docs in `ttec-digital/docs` for further info on these features.


## Upgrading from v1

1) Clone your repo to a local workspace

2) Run either `ttec-digital/migrate-azdo-repo.ps1` or `ttec-digital/migrate-github-repo.ps1` with `-WorkspacePath pathto/workspace` pointing to the workspace folder.

3) Any custom pre/post X scripts may need to adapt slightly:
 - Scripts require `context` parameter instead of individual parameters. See the config docs.
 - Put PowerShell module requirements into `alm-config.psd1` and remove any commands to install and load them.

4) Commit and push the changes back up to the remote.

---

![ALM4Dataverse](logo.png)

This repo contains:
- an advanced and extendable application lifecycle management (ALM/CI-CD)
implementation for Dataverse.
- a set of process documentation and guidance on how to use and extend it.

Currently to be used with Azure DevOps, but may be extended to GitHub in future (which is straightforward due to the way it is implemented).


Features:


- Handles zero to many Dataverse solutions per repo.
- Correctly determines the install/upgrade/update method for each solution based on the state of the target environment
- Supports branches, PRs etc with minimal re-configuration
- Supports including config/system/lookup data
- Easy to extend using the extensive PowerShell ecosystem.

## Getting Started

1) [Run the automated setup process](docs/setup/automated-setup.md) to put in place the pipelines and other configuration needed.

   Alternatively, if you prefer manual configuration, see the [Manual Setup Guide](docs/setup/manual-setup.md).
    

## Documentation

### Initial Setup

- [Azure DevOps Organization Requirements](docs/setup/azdo-organisation-requirements.md)
- [Automated Setup](docs/setup/automated-setup.md)
- [Manual Setup](docs/setup/manual-setup.md)

#### Usage Instructions

- [Exporting changes](docs/usage/exporting-changes.md) - `EXPORT` pipeline
  Capturing changes from your dev environments into source control.
- [Building releases](docs/usage/building-releases.md) - `BUILD` pipeline
  Generating release assets for later deployment.
- [Deploying](docs/usage/deploying.md) -`DEPLOY-<branchname>` pipeline
  Deploying release assets to environments in a controlled sequence
- [Importing changes](docs/usage/importing-changes.md) - `IMPORT` pipeline
  Seeding or updating dev environment from source control.

### Configuration Reference

- [ALM Configuration](docs/config/alm-config.md) - `alm-config.psd1`
- [Environment Variable Group](docs/config/environment-variable-group.md)
- [Service Connection Configuration](docs/config/environment-service-connection.md)

#### Example 'Hook' Extensions

- [Data import and export](config/example-hooks/data-import-export.md) (for example config/system data)
- [Organization/environment settings](config/example-hooks/organization-settings.md) (for example enabling the 'PCF allowed' switch)
