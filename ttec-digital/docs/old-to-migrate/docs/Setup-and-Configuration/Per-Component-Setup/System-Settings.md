System settings are the per environment settings you can see in the admin centre. These cover optional features and configurable global behaviour.

## Setup and making changes

```powershell   
    OrgSettings                     =
    @{
        "isexternalsearchindexenabled" = $true;
        "maxuploadfilesize"            = 128122880;
        "orgdborgsettings"             = "<OrgSettings><ClientUEIPDisabled>true</ClientUEIPDisabled></OrgSettings>";
    };   
```

Organization (system) settings are configured in the `almsetup.ps1` file in source control. 

Each key is the name of a column in the `organization` Dataverse table. The [Microsoft documentation lists the available columns](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/reference/entities/organization).

Additionally, the `orgdborgsettings` is a special XML formatted value that can contain many other settings. [Org DB settings are listed in this MS support article](https://support.microsoft.com/en-us/topic/orgdborgsettings-tool-for-microsoft-dynamics-crm-20a10f46-2a24-a156-7144-365d49b842ba)

Values must use PowerShell types:
- String: `"string"`
- Boolean: `$true` or `$false`
- Optionset/choice: `1234` (use the numeric value)
- Number: `12.34`



## Deployment

When deployment runs, the named org settings only will be applied to the target environment.