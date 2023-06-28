# Dependency solutions
Third party or external dependencies on which the solutions under development are dependent:

## Setup
1) Upload the solution zip file to `dependencies` folder. This should normally be a managed solution.

2) Edit `almconfig.ps` file and give the name of the solution file relative to the repo root:

    ```powershell
    DependencySolutions             = @(
        "dependencies/CreatorKitCore_managed.zip"
    );
    ```

    Multiple solutions can be listed and should be comma separated and in dependency order. The `"`s go around each separate value: e.g. `"value1", "value2"`

   `DependencySolutions` are solution on which the solution(s) under development depend. They will be deployed before the main solution(s).   Use `PostDependencySolutions` instead of the solution should be installed after the main solution(s) that are under development.

3) See information below about environment variables and connection references. If the dependent solution has any of these they must be set up.

## Making changes
You can simply overwrite the .zip file that is referenced by the above with a new version as/when required and commit it to the repo.

## Deployment
 The next build will include the new version of the dependency and it will be upgraded automatically in any target environments when deployment runs.

# Solutions under development

## Setup
1) Ensure the solution is present in the DEV-branchname environment:

   -  New solutions: If the solution doesn't yet exist in the development environment, create the solution via Power Apps Maker portal 
   - Existing solutions: import it if it's coming from an existing source.

2) Add the unique name of the solution to `almconfig.ps1`:
   ```powershell
    Solutions                       =
    @(
        "TestSolution1",
        "TestSolution2"
    );
   ```

    Multiple solutions can be listed and should be comma separated and in dependency order. Solutions will be deployed in the order listed.

   There are several options that override how the solution will be deployed. These can be listed separately in the `SolutionOptions` section of the same file:

```powershell
    SolutionOptions = @{
         "TestSolution1" = @{
             DeployUnmanaged=$false;
             SkipDeployment=$false;
         }
    }
```

   |Name|Description|
   |-|-|
   |`DeployUnmananged`|`$true` if when deployed, the unmanaged solution should be used. This is uncommon except for Data Flow solutions, which must be unmanaged due to a current platform limitation.<p>Default: `$false` meaning managed solution gets deployed.|
   |`SkipDeployment`|`$true` if the solution will not be deployed. This is uncommon, but allows these solution to be collected as build assets that are used manually.|

## Making changes

1) Edit and add new components in the solution in the DEV-branchname environment using the standard Power Apps Maker portal and other tools.

2) The next time `EXPORT` pipeline is run, the changes will be exported and included in the next build.

## Deployment

The system will install or upgrade solutions as needed depending on if the target environment already has them. All solutions are installed or staged for upgrade in one phase and then any pending upgrades are applied in a second phase. (This allows components to be moved between solutions without data loss.)

Any solution that is already installed with the same version number will be skipped.

Each environment need to have the following in the Pipelines Library Variable Group associated with it. [See general per env setup info](/Setup-and-Configuration/Per-Env-Setup)

|Name|Value|
|-|-|
`DATAVERSESERVICEACCOUNTUPN` |UPN of AAD account that will own connections and activate Power Automate Flows. |
|`DATAVERSESERVICEACCOUNTPASSWORD`|Password for AAD account above. Required if auto connection creation/mapping is configured.|
|`DATAVERSESERVICEACCOUNTTOTPSECRET`|MFA TOTP secret for AAD account above. Required if auto connection creation/mapping is configured and account requires MFA for login.|
|`DATAVERSECONNREF_<name>` |Connection IDs to use for each connection reference.<br/><br/>Connections must be created by logging in interactively and then shared with the Service Principal configured in the AzDO Service Connection for the environment that is used for deployment or configured to be created/mapped automatically - see below.<br/><br/>`<name>` must be either the logical name for the specific connection reference in the solution, or the logical name of the connector used by the connection reference.<br/><br/>The value should be the ID of the connection. You can find this in the URL for the connection details page in the Maker portal. For example `https://make.powerapps.com/environments/Default-b054d2e8-44fa-4b10-ab4d-577e6bd3177e/connections/shared_commondataserviceforapps/`**`afd3d0df657740019d359e487d86e8f5`**`/details`. The ID is the bold part and is always the entire value between the two final `/` s. Note that different connectors use different formats and it is not always as per this example.|
|`DATAVERSEENVVAR_<name>`|Value to use for each environment variable.|

### Auto Connection Reference Mapping

This feature is preview and has not yet been widely tested. To use it, the password and TOTP secret for the service account must be in the per env library.

# List of connection reference for which auto mapping/creation will be enabled.

In `almconfig.ps1` you can provide a list of connector names and connection ref name combinations for which auto mapping/creation will be used. Where this is matched and a connection ID has not been explicity provided, the system will log in as the `DATAVERSESERVICEACCOUNTUPN` account an get a list of existing connections of that the correct connector type. Where a connection is found it will be used. Otherwise a new connection will be created. 

The variable group for each env, must provide the credentials.

Where this is successful, the `DATAVERSECONNECT_<name>` does not need to be provided in the environment variable group.

The connector must be one that allow creation of a connection with only the step to specify AAD identity.

```powershell
    AutoConnectionMappings = @(
        # These will match any connection ref for the connector
        @{
            Connector="shared_commondataserviceforapps";
            ConnectionReference="*";
        },
        @{
            Connector="shared_commondataservice";
            ConnectionReference="*";
        },

        # This one will match any connection ref with this prefix
        # for the connector
        @{
            Connector="shared_sharepointonline";
            ConnectionReference="someprefix_*";
        },

        # This one will match only this specific connection ref
        # for the connector
        @{
            Connector="shared_sharepointonline";
            ConnectionReference="some_fullname";
        }
    )
```


