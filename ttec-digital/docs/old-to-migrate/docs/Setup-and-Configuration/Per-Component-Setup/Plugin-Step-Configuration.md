Plugin "secure" configuration values are a supported and encouraged place to put per-environment configuration for plugin steps. These values are not included in solutions and must be set after deployment.

It is not good practice to use the "unsecure" configuration on a per environment basis as this is a managed component, so these are not supported here.

## Setup and Making Changes

In `almsetup.ps1` add each step that needs an updated secure config to the list:
```powershell
    # SecureConfig to apply to plugin steps.
    # SecureConfig can contain $(Placeholders) to allow value to be env specific.
    PluginSteps = @(
        @{
            PluginStepId="3951c8cb-1c29-46ca-906f-17d10d48b597";
            SecureConfig='$(PluginXYZSecret)'
        }
    )

```
`PluginStepId` is the primary key of the `sdkmessageprocessingstep` record for the plugin step. You can see this in the Microsoft Plugin Registration Tool.

The `SecureConfig` value can contain `$(name)` placeholders to allow values to be environment specific (supplied during deployment).


## Deployment

When deployment is executed, the plugin step secure configs listed will have their values updated. 

If the config references any config values that are missing for the target environment an error will be generated.