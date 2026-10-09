#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates a legacy GitHub Dataverse ALM repository to the current ALM4Dataverse GitHub setup.

.DESCRIPTION
    This script migrates a legacy Dataverse-ALM repository to the current ALM4Dataverse format for GitHub repositories.
    It migrates:
    - almconfig.ps1 to alm-config.psd1
    - GitHub workflow files to the upstream composite-action structure under .github/workflows/
    After successful migration, the original almconfig.ps1 file is renamed to almconfig.ps1.migrated.

.PARAMETER WorkspacePath
    Path to the repository workspace root containing the old configuration.
    Should contain almconfig.ps1.

.PARAMETER TemplateDirectory
    Optional path to the directory containing the template (alm-config.psd1). 
    Defaults to copy-to-your-repo in the script's directory.

.EXAMPLE
    .\migrate-github-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project

.EXAMPLE
    .\migrate-github-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project -TemplateDirectory c:\templates
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspacePath,

    [Parameter(Mandatory = $false)]
    [string]$TemplateDirectory
)

$ErrorActionPreference = 'Stop'

# Import common migration functions
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModule = Join-Path $scriptRoot 'migrate-common.psm1'
if (-not (Test-Path $commonModule)) {
    throw "Required module not found: $commonModule"
}
Import-Module $commonModule -Force

#==============================================================================
# Main Script
#==============================================================================

# Resolve paths
$WorkspacePath = Resolve-Path $WorkspacePath -ErrorAction Stop

if (-not $TemplateDirectory) {
    $TemplateDirectory = Join-Path $scriptRoot '..' 'copy-to-your-repo'
}

# Determine almconfig.ps1 path
$AlmConfigPath = Join-Path $WorkspacePath 'almconfig.ps1'
$AlmConfigMigratedPath = "$AlmConfigPath.migrated"
$OutputPath = Join-Path $WorkspacePath 'alm-config.psd1'

# Check migration status
$configAlreadyMigrated = $false
if (-not (Test-Path $AlmConfigPath)) {
    # Check if migration was already done
    if (Test-Path $AlmConfigMigratedPath) {
        Write-Host "Configuration already migrated (almconfig.ps1.migrated found)" -ForegroundColor Gray
        $AlmConfigPath = $null
        $configAlreadyMigrated = $true
    }
    elseif (Test-Path $OutputPath) {
        Write-Host "Configuration file already exists (alm-config.psd1 found)" -ForegroundColor Gray
        $AlmConfigPath = $null
        $configAlreadyMigrated = $true
    }
    else {
        Write-Warning "almconfig.ps1 not found at: $(Join-Path $WorkspacePath 'almconfig.ps1')"
        Write-Warning "This may not be a legacy Dataverse ALM repository, or it may already be migrated."
        $AlmConfigPath = $null
        $configAlreadyMigrated = $true
    }
}

Write-Host "" 
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Migrating GitHub Dataverse ALM repository to ALM4Dataverse format" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspacePath" -ForegroundColor Cyan
Write-Host ""

# Migrate configuration using common module (only if not already migrated)
if (-not $configAlreadyMigrated) {
    $migrationResult = Invoke-ConfigMigration `
        -WorkspacePath $WorkspacePath `
        -TemplateDirectory $TemplateDirectory `
        -AlmConfigPath $AlmConfigPath `
        -OutputPath $OutputPath

    if (-not $migrationResult.Migrated) {
        Write-Host ""
        Write-Host "Configuration migration was not performed" -ForegroundColor Yellow
    }
}
else {
    $migrationResult = @{
        Migrated = $false
        Warnings = @()
        AlreadyMigrated = $true
    }
}

# Migrate GitHub workflow files
$workflowMigrationResult = Invoke-WorkflowMigration -WorkspacePath $WorkspacePath -TemplateDirectory $TemplateDirectory

if ($workflowMigrationResult.FilesMigrated.Count -gt 0) {
    Write-Host ""
    Write-Host "Workflow files migrated: $($workflowMigrationResult.FilesMigrated.Count)" -ForegroundColor Green
}

#==============================================================================
# Migration Complete - Next Steps
#==============================================================================

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "GitHub Repository Migration Complete" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""

if ($migrationResult.Migrated) {
    Write-Host "✓ Configuration file migrated successfully" -ForegroundColor Green
    Write-Host "  - almconfig.ps1 → alm-config.psd1" -ForegroundColor Gray
    Write-Host "  - Original backed up as: almconfig.ps1.migrated" -ForegroundColor Gray
}

if ($workflowMigrationResult.FilesMigrated.Count -gt 0) {
    Write-Host "✓ Workflow files migrated successfully" -ForegroundColor Green
    foreach ($file in $workflowMigrationResult.FilesMigrated) {
        Write-Host "  - $file (backup: $file.migrated)" -ForegroundColor Gray
    }
    Write-Host "  - Replaced with upstream composite-action workflow stubs under .github/workflows/" -ForegroundColor Gray
}

Write-Host ""
Write-Host "NEXT STEPS FOR GITHUB WORKFLOWS:" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Review the migrated configuration:" -ForegroundColor Yellow
Write-Host "   - Open alm-config.psd1 and verify all settings" -ForegroundColor Gray
Write-Host "   - Check that solutions, hooks, and assets are correct" -ForegroundColor Gray
Write-Host ""

Write-Host "2. Commit and push the changes:" -ForegroundColor Yellow
Write-Host "   git add alm-config.psd1 almconfig.ps1.migrated" -ForegroundColor Gray
Write-Host "   git commit -m 'Migrate to ALM4Dataverse configuration format'" -ForegroundColor Gray
Write-Host "   git push" -ForegroundColor Gray
Write-Host ""


Write-Host "3. Test the migration:" -ForegroundColor Yellow
Write-Host "   - Review .github/workflows/DEPLOY-main.yml and replace the example environments" -ForegroundColor Gray
Write-Host "   - Review docs/setup/github-setup.md and docs/setup/github-variables.md" -ForegroundColor Gray
Write-Host "   - Commit and push the changes to a feature branch" -ForegroundColor Gray
Write-Host "   - Verify workflows run successfully with the new configuration" -ForegroundColor Gray
Write-Host "   - Test EXPORT, BUILD, and DEPLOY workflows" -ForegroundColor Gray
Write-Host ""

Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""

# Show any warnings
$allWarnings = @()
if ($migrationResult.Warnings) { $allWarnings += $migrationResult.Warnings }
if ($workflowMigrationResult.Warnings) { $allWarnings += $workflowMigrationResult.Warnings }

if ($allWarnings.Count -gt 0) {
    Write-Host "WARNINGS:" -ForegroundColor Yellow
    Write-Host "=========" -ForegroundColor Yellow
    foreach ($warning in $allWarnings) {
        Write-Warning $warning
    }
    Write-Host ""
}

