param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

& $PSScriptRoot/common/load-dataverse-sdk.ps1
import-module $PSScriptRoot/common/alm.psm1

$config = $context.Config

if ($config.Contains("OrgSettings")) {
    deployOrgSettings -settings $config.OrgSettings
}