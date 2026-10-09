param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

& $PSScriptRoot/common/load-dataverse-sdk.ps1
import-module $PSScriptRoot/common/alm.psm1

$config = $context.Config


[Hashtable] $portalconfig = @{}
[Hashtable] $generalconfig = @{
    ServiceAccountUpn = $serviceaccountupn
}


deleteUnneededCallbackRegistrations

if ($config.ContainsKey("DefaultEnvVarValues")) {
    $environmentvariables = $config.DefaultEnvVarValues
}

get-item env:DATAVERSECONNREF_* | foreach-object {
    $connectionreferences[$_.Name -replace "DATAVERSECONNREF_", ""] = $_.Value
}

get-item env:DATAVERSEENVVAR_* | foreach-object {
    $environmentvariables[$_.Name -replace "DATAVERSEENVVAR_", ""] = $_.Value
}

get-item env:PORTALCONFIG_* | foreach-object {
    $portalconfig[$_.Name -replace "PORTALCONFIG_", ""] = $_.Value
}

get-item env:CONFIG_* | foreach-object {
    $generalconfig[$_.Name -replace "CONFIG_", ""] = $_.Value
}

if ($config.Contains("DependencySolutions")) {
    $dependencysolutionfiles += @($config.DependencySolutions) | where-object { $_ } 

    deploySolutionSet -solutionfiles $dependencysolutionfiles -description "dependency"
}


if ($config.Contains("DataSets")) {
    if ($config.DataSets -is [hashtable]) {
        $config.DataSets.GetEnumerator() | ForEach-Object {
            if ($_.Value.Contains("Stage") -and $_.Value.Stage -eq "BeforeTeams") {
                deployDataset -datapath "data/$($_.Key).zip"            
            }
        }
    } else {
        #Nothing
    }
}

if ($config.Contains("AadGroupTeams")) {    
    @($config.AadGroupTeams) | foreach-object {
        $aadGroupId = replaceConfigPlaceholders -template $_.AadGroupId -config $generalconfig
        ensureAadGroupTeam -businessunitname $_.BusinessUnitName -teamname $_.TeamName -teamid:$_.TeamId -aadgroupid $aadGroupId -rolenames $_.RoleNames
    }
}

if ($config.Contains("BuDefaultTeams")) {    
    @($config.BuDefaultTeams) | foreach-object {
        ensureBuDefaultTeam -businessunitname $_.BusinessUnitName -rolenames $_.RoleNames
    }
}

if ($config.Contains("OwnerTeams")) {    
    @($config.OwnerTeams) | foreach-object {
        ensureOwnerTeam -businessunitname $_.BusinessUnitName -teamid:$_.TeamId -teamname $_.TeamName -rolenames $_.RoleNames
    }
}

if ($config.Contains("AccessTeams")) {    
    @($config.AccessTeams) | foreach-object {
        ensureAccessTeam -businessunitname $_.BusinessUnitName -teamid:$_.TeamId -teamname $_.TeamName
    }
}

if ($config.Contains("ApplicationUsers")) {    
    @($config.ApplicationUsers) | foreach-object {
        $applicationid = replaceConfigPlaceholders -template $_.ApplicationId -config $generalconfig
        ensureAppUser -applicationid $applicationid -businessunitname $_.BusinessUnitName -rolenames $_.RoleNames
    }
}

if ($config.Contains("PluginSteps")) {
    @($config.PluginSteps) | foreach-object {
        $secureconfigvalue = (replaceConfigPlaceholders -template $_.SecureConfig -config $generalconfig)
        setPluginStepSecureConfig -stepid $_.PluginStepId -value:$secureconfigvalue
    }
}

if ($config.Contains("CanvasAppSharing")) {
    @($config.CanvasAppSharing) | foreach-object {
        if ($env:DATAVERSEUSERADMINPOWERAPPMODULE) {
            ensureAdminPowerAppsConnection
        }
        $groupids = @($_.AadGroupIds | foreach-object { replaceConfigPlaceholders -template $_ -config $generalconfig })
        shareCanvasApp `
            -uniquename $_.UniqueName `
            -aadgroupids $groupids `
            -serviceaccountupn:$serviceaccountupn `
            -serviceaccountpassword:$serviceaccountpassword `
            -serviceaccounttotpsecret:$serviceaccounttotpsecret 
    }  
}

if ($config.Contains("FlowSharing")) {
    @($config.FlowSharing) | foreach-object {
        ensureAdminPowerAppsConnection
        $groupids = @($_.AadGroupIds | foreach-object { replaceConfigPlaceholders -template $_ -config $generalconfig })
        shareFlow -workflowid $_.WorkflowId -aadgroupids $groupids
    }  
}

if ($config.Contains("DataSets")) {

    if ($config.DataSets -is [hashtable]) {
        $config.DataSets.GetEnumerator() | ForEach-Object {
            if ((-not $_.Value.Contains("Stage")) -or $_.Value.Stage -ne "BeforeTeams") {
                deployDataset -datapath "data/$($_.Key).zip"            
            }
        }
    } else {
        @($config.DataSets) | foreach-object {
            deployDataset -datapath "data/$_.zip"  
        }
    }
}

if ($config.Contains("Portals")) {
    $config.Portals.Keys | foreach-object {
        deployPortal -path "portals/$_/cfg" -config $portalconfig
    }
}

if ($config.Contains("PostDependencySolutions")) {
    $postdepsolutionfiles = @($config.PostDependencySolutions | where-object { $_ } )

    deploySolutionSet -solutionfiles $postdepsolutionfiles -description "post-dependency"
}

synapse_deploy -config $config