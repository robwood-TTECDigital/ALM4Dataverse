param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

import-module $PSScriptRoot/common/alm.psm1

$config = $context.Config

if ($config.Contains("OrgSettings")) {
    deployOrgSettings -settings $config.OrgSettings
}