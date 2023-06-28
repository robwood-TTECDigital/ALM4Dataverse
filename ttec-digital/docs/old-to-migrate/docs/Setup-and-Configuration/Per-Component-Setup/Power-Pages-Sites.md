## Setup

If the site is new, create the Pages site in the DEV environment.

Get the ID of the `adx_website` record from the Portal admin app.

In the `almsetup.ps1` file add the site to the list using a unique name and the ID of the website record. In the example below `customerportal` is the name and `47b...` is the ID.

```powershell
    Portals=@{
        "customerportal"="47b06199-4916-ee11-9cbe-000d3a0b7a98"
    };
```

The first time the export process is executed, an additional file `deployment-profile-template.yml` will be generated. This file is in the [standard Power Apps CLI format for Portal deployment profile](https://learn.microsoft.com/en-us/power-pages/configure/power-platform-cli-tutorial#upload-the-changes-using-deployment-profile) but can contain `$(name)` placeholder values to indicate where an environment specific value should be substituted in. A single file is used across all environments. These values should be specified in the deployment variable group using `PORTALCONFIG_name` key where `name` is the value used in the placeholder.

## Making Changes

Make changes in the DEV-branchname environment.

When the EXPORT pipeline is run, changes made to the Pages site config will be exported to source control in the `portal\<name>` folder.

## Deployment

When deployment is run, the Pages site configuration will be uploaded to the target environment. 

The deployment profile template will be used to generate a deployment profile for the target environment (see above). Any missing config values for the target environment will cause an error to be generated.

Additionally, a deletion step is executed to delete any records that are present in the target environment but which are not found in the latest version being deployed.