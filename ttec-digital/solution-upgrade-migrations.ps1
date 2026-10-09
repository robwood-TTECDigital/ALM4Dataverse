param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

& $PSScriptRoot/common/load-dataverse-sdk.ps1
Import-Module $PSScriptRoot/common/alm.psm1

$config = $context.Config

$migrationpath = (join-path $context.BaseDirectory "migrations")

if (test-path $migrationpath) {
    write-host "Applying solution upgrade data migrations from '$migrationpath'"
    applyMigrations $migrationpath
}
else {
    write-host "No solution upgrade data migrations found at '$migrationpath'"
    return
}
