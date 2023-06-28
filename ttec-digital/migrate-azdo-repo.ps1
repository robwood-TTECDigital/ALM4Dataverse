#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates a legacy Dataverse-ALM repository to the new ALM4Dataverse format.

.DESCRIPTION
    This script migrates a legacy Dataverse ALM repository to the new ALM4Dataverse format.
    It migrates:
    - almconfig.ps1 to alm-config.psd1
    - Pipeline files from alm-pipelines/ to pipelines/
    After successful migration, the original files/folders are renamed to .migrated.

.PARAMETER WorkspacePath
    Path to the repository workspace root containing the old configuration.
    Should contain almconfig.ps1 and alm-pipelines/ folder.

.PARAMETER TemplateDirectory
    Optional path to the directory containing the templates (alm-config.psd1 and pipelines/). 
    Defaults to copy-to-your-repo in the script's directory.

.PARAMETER NoAzDoConnection
    Switch to skip migration of Azure DevOps pipeline definitions, service connections, and variable groups.
    By default, the script will attempt to migrate these Azure DevOps resources if it detects an Azure DevOps origin remote.

.PARAMETER AzDoOrganization
    Azure DevOps organization name (e.g., 'myorg' from dev.azure.com/myorg).
    If not specified, will be auto-detected from git origin remote.

.PARAMETER AzDoProject
    Azure DevOps project name.
    If not specified, will be auto-detected from git origin remote.

.PARAMETER AzDoRepository
    Azure DevOps repository name.
    If not specified, will be auto-detected from git origin remote.

.PARAMETER PersonalAccessToken
    Azure DevOps Personal Access Token (PAT) for authentication.
    If not specified, will attempt browser-based authentication and prompt for PAT if that fails.

.EXAMPLE
    .\migrate-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project

.EXAMPLE
    .\migrate-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project -NoAzDoConnection

.EXAMPLE
    .\migrate-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project -PersonalAccessToken "your-pat-here"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspacePath,

    [Parameter(Mandatory = $false)]
    [string]$TemplateDirectory,

    [Parameter(Mandatory = $false)]
    [switch]$NoAzDoConnection,

    [Parameter(Mandatory = $false)]
    [string]$AzDoOrganization,

    [Parameter(Mandatory = $false)]
    [string]$AzDoProject,

    [Parameter(Mandatory = $false)]
    [string]$AzDoRepository,

    [Parameter(Mandatory = $false)]
    [string]$PersonalAccessToken
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
# Helper Functions (Azure DevOps specific)
#==============================================================================

function Get-AuthToken {
    param(
        [Parameter(Mandatory)][string]$ResourceUrl,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2'  # Azure PowerShell
    )

    # Ensure the Rnwood module is loaded (it contains MSAL)
    $module = Get-Module -Name "Rnwood.Dataverse.Data.PowerShell"
    if (-not $module) {
        Write-Host "Loading Rnwood.Dataverse.Data.PowerShell module for MSAL support..." -ForegroundColor Yellow
        Import-Module "Rnwood.Dataverse.Data.PowerShell" -ErrorAction Stop
        $module = Get-Module -Name "Rnwood.Dataverse.Data.PowerShell"
    }

    # First try to load from Rnwood module directly
    Write-Host "Loading MSAL from Rnwood module..." -ForegroundColor Yellow
    $base = $module.ModuleBase
    $dllPath = $null
    $dllLoaded = $false
    
    # Determine the correct path based on PowerShell edition and available folders
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell Core - try multiple .NET versions
        $possiblePaths = @(
            (Join-Path $base "cmdlets\net8.0\Microsoft.Identity.Client.dll")
        )
    }
    else {
        # PowerShell Desktop
        $possiblePaths = @(
            (Join-Path $base "cmdlets\net462\Microsoft.Identity.Client.dll")
        )
    }
    
    # Try each possible path
    foreach ($tryPath in $possiblePaths) {
        if (Test-Path $tryPath) {
            $dllPath = $tryPath
            try {
                Write-Host "Loading MSAL from: $tryPath" -ForegroundColor DarkGray
                Add-Type -Path $tryPath -ErrorAction Stop
                $dllLoaded = $true
                break
            }
            catch {
                Write-Host "Failed to load from $tryPath : $($_.Exception.Message)" -ForegroundColor DarkGray
            }
        }
    }
    
    # If standard paths failed, try recursive search
    if (-not $dllLoaded) {
        Write-Host "Standard paths not found, searching recursively..." -ForegroundColor DarkGray
        $allDlls = Get-ChildItem $base -Recurse -Filter "Microsoft.Identity.Client.dll" -ErrorAction SilentlyContinue
        $found = $null
        
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Prefer newer .NET versions
            $found = $allDlls | Where-Object { $_.FullName -match 'net8|net7|net6|netcore|netstandard' } | Sort-Object -Property FullName -Descending | Select-Object -First 1
        }
        else {
            $found = $allDlls | Where-Object { $_.FullName -match 'net4' } | Sort-Object -Property FullName -Descending | Select-Object -First 1
        }
        
        if ($found) {
            $dllPath = $found.FullName
            try {
                Write-Host "DLL found recursively at: $($found.FullName)" -ForegroundColor DarkGray
                Add-Type -Path $found.FullName -ErrorAction Stop
                $dllLoaded = $true
            }
            catch {
                Write-Host "Failed to load from recursive path: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    
    # If still not loaded, try LoadWithPartialName as last resort
    if (-not $dllLoaded) {
        Write-Host "Attempting to load via LoadWithPartialName..." -ForegroundColor DarkGray
        try {
            [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Identity.Client")
            $dllLoaded = $true
        }
        catch {
            Write-Host "LoadWithPartialName failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Verify that the type is actually available
    if (-not $dllLoaded) {
        try {
            [void][Microsoft.Identity.Client.PublicClientApplicationBuilder]
            $dllLoaded = $true
        }
        catch {
            throw "Failed to load Microsoft.Identity.Client: The assembly could not be loaded and the type is not available. Please ensure Rnwood.Dataverse.Data.PowerShell module is properly installed."
        }
    }

    $ResourceUrl = $ResourceUrl.TrimEnd('/')
    $scopes = [string[]]@("$ResourceUrl/.default")

    $authority = if ($TenantId) {
        "https://login.microsoftonline.com/$TenantId"
    }
    else {
        "https://login.microsoftonline.com/common"
    }

    # Run authentication in a background job so it can be cancelled
    Write-Host "Starting interactive authentication..." -ForegroundColor Yellow
    Write-Host "A browser window should open. If it doesn't, press Ctrl+C to cancel." -ForegroundColor Gray
    Write-Host ""
    
    $job = Start-Job -ScriptBlock {
        param($ClientId, $Authority, $Scopes, $DllPath)
        
        # Load MSAL in the job
        if ($DllPath -and (Test-Path $DllPath)) {
            try {
                Add-Type -Path $DllPath -ErrorAction Stop
            }
            catch {
                throw "Failed to load MSAL DLL in background job: $_"
            }
        }
        else {
            # Try LoadWithPartialName if path not provided
            try {
                [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Identity.Client")
            }
            catch {
                throw "MSAL DLL path not provided and LoadWithPartialName failed: $_"
            }
        }
        
        # Verify the type is available
        try {
            $app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)
        }
        catch {
            throw "Microsoft.Identity.Client.PublicClientApplicationBuilder type not available after loading DLL: $_"
        }
        
        try {
            $app = $app.WithAuthority($Authority)
            $app = $app.WithRedirectUri("http://localhost")
            $pca = $app.Build()
            
            # Convert scopes to proper format
            if ($Scopes -is [string]) {
                $Scopes = @($Scopes)
            }
            
            $result = $pca.AcquireTokenInteractive([string[]]$Scopes).ExecuteAsync().GetAwaiter().GetResult()
            return $result
        }
        catch {
            throw "Authentication failed: $_"
        }
    } -ArgumentList $ClientId, $authority, $scopes, $dllPath
    
    # Wait for the job with user-cancellable loop
    $timeout = 120 # 2 minutes in seconds
    $elapsed = 0
    $checkInterval = 1 # Check every second
    $userCancelled = $false
    
    Write-Host "Waiting for authentication (timeout: $timeout seconds)..." -ForegroundColor Yellow
    Write-Host "Type 'cancel' and press Enter to skip browser auth and use PAT instead" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        while ($job.State -eq 'Running' -and $elapsed -lt $timeout) {
            # Use timeout on Read-Host to allow user to type 'cancel'
            if ($elapsed % 5 -eq 0) {
                # Every 5 seconds, show a prompt they can respond to
                $userInput = Read-Host -Prompt "Still waiting (type 'cancel' to skip, or press Enter to continue)" -TimeoutSec 5
                if ($userInput -eq 'cancel') {
                    Write-Host ""
                    Write-Host "Browser authentication skipped. Will use PAT instead." -ForegroundColor Yellow
                    $userCancelled = $true
                    break
                }
            }
            else {
                Start-Sleep -Seconds 1
            }
            
            $elapsed += $checkInterval
        }
        
        if ($userCancelled) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -ErrorAction SilentlyContinue
            return $null
        }
        
        if ($job.State -eq 'Completed') {
            $result = Receive-Job -Job $job
            Remove-Job -Job $job
            
            if ($result -and $result.AccessToken) {
                Write-Host "  ✓ Authentication successful" -ForegroundColor Green
                return $result
            }
            else {
                throw "Authentication completed but no access token was returned"
            }
        }
        elseif ($job.State -eq 'Failed') {
            $jobError = Receive-Job -Job $job 2>&1
            Remove-Job -Job $job
            throw "Authentication failed: $jobError"
        }
        else {
            # Timeout
            Write-Host ""
            Write-Host "Authentication timed out after $timeout seconds" -ForegroundColor Yellow
            Stop-Job -Job $job
            Remove-Job -Job $job
            throw "Authentication timed out"
        }
    }
    catch {
        # Clean up job if still running
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -ErrorAction SilentlyContinue
        }
        # Re-throw actual errors (not user cancellation)
        throw
    }
}

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

if (-not (Test-Path $AlmConfigPath)) {
    # Check if migration was already done
    if (Test-Path $AlmConfigMigratedPath) {
        $AlmConfigPath = $null
    }
    else {
        throw "almconfig.ps1 not found at: $AlmConfigPath"
    }
}

# Determine alm-pipelines path
$OldPipelinesPath = Join-Path $WorkspacePath 'alm-pipelines'
$OldPipelinesMigratedPath = "$OldPipelinesPath.migrated"

if (-not (Test-Path $OldPipelinesPath)) {
    # Check if migration was already done
    if (Test-Path $OldPipelinesMigratedPath) {
        Write-Host "alm-pipelines has already been migrated (found $OldPipelinesMigratedPath)" -ForegroundColor Green
        Write-Host "Skipping pipeline file migration" -ForegroundColor Yellow
        $OldPipelinesPath = $null
    }
    else {
        Write-Warning "alm-pipelines folder not found at: $OldPipelinesPath - skipping pipeline migration"
        $OldPipelinesPath = $null
    }
}

$OutputPath = Join-Path $WorkspacePath 'alm-config.psd1'
$NewPipelinesPath = Join-Path $WorkspacePath 'pipelines'

# Track migrated environments for later use in renaming service connections and variable groups
$script:migratedEnvironments = @()
$script:environmentServiceConnections = @{}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Migrating Dataverse ALM repository to ALM4Dataverse format" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspacePath" -ForegroundColor Cyan
Write-Host ""

# Migrate configuration using common module
$OutputPath = Join-Path $WorkspacePath 'alm-config.psd1'

$migrationResult = Invoke-ConfigMigration `
    -WorkspacePath $WorkspacePath `
    -TemplateDirectory $TemplateDirectory `
    -AlmConfigPath $AlmConfigPath `
    -OutputPath $OutputPath

if ($migrationResult.AlreadyMigrated) {
    Write-Host ""
    Write-Host "Configuration migration skipped (already completed)" -ForegroundColor Green
}
elseif (-not $migrationResult.Migrated) {
    Write-Host ""
    Write-Host "Configuration migration was not performed" -ForegroundColor Yellow
}

#==============================================================================
# Detect Azure DevOps Configuration
#==============================================================================

# Try to detect Azure DevOps details from git origin remote (needed for pipeline file migration)
Write-Host ""
Write-Host "Detecting Azure DevOps configuration from git origin remote..." -ForegroundColor Yellow

Push-Location $WorkspacePath
try {
    $gitRemote = & git remote get-url origin 2>$null
    
    if ($gitRemote) {
        Write-Host "  Git origin: $gitRemote" -ForegroundColor Gray
        
        # Parse Azure DevOps URL patterns:
        # https://dev.azure.com/{organization}/{project}/_git/{repository}
        # https://{organization}.visualstudio.com/{project}/_git/{repository}
        # {organization}@vs-ssh.visualstudio.com:v3/{organization}/{project}/{repository}
        
        if ($gitRemote -match 'dev\.azure\.com[/:]([^/]+)/([^/]+)/_git/([^/\s]+?)(?:\.git)?$') {
            if (-not $AzDoOrganization) { $AzDoOrganization = $matches[1] }
            if (-not $AzDoProject) { $AzDoProject = $matches[2] }
            if (-not $AzDoRepository) { $AzDoRepository = $matches[3] }
        }
        elseif ($gitRemote -match '([^@]+)\.visualstudio\.com[/:]([^/]+)/_git/([^/\s]+?)(?:\.git)?$') {
            if (-not $AzDoOrganization) { $AzDoOrganization = $matches[1] }
            if (-not $AzDoProject) { $AzDoProject = $matches[2] }
            if (-not $AzDoRepository) { $AzDoRepository = $matches[3] }
        }
        elseif ($gitRemote -match '@vs-ssh\.visualstudio\.com:v3/([^/]+)/([^/]+)/([^/\s]+?)(?:\.git)?$') {
            if (-not $AzDoOrganization) { $AzDoOrganization = $matches[1] }
            if (-not $AzDoProject) { $AzDoProject = $matches[2] }
            if (-not $AzDoRepository) { $AzDoRepository = $matches[3] }
        }
        
        if ($AzDoRepository) {
            Write-Host "  ✓ Detected Azure DevOps configuration:" -ForegroundColor Green
            Write-Host "    Organization: $AzDoOrganization" -ForegroundColor Gray
            Write-Host "    Project: $AzDoProject" -ForegroundColor Gray
            Write-Host "    Repository: $AzDoRepository" -ForegroundColor Gray
        }
        else {
            throw "Git origin does not appear to be an Azure DevOps repository. This script requires an Azure DevOps repository."
        }
    }
    else {
        throw "No git origin remote configured. This script requires a git repository with an Azure DevOps origin."
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    Pop-Location
}

#==============================================================================
# Migrate Pipeline Files
#==============================================================================

if ($OldPipelinesPath) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Migrating Pipeline Files" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    
    # Create new pipelines directory if it doesn't exist
    if (-not (Test-Path $NewPipelinesPath)) {
        Write-Host "Creating pipelines directory..." -ForegroundColor Yellow
        New-Item -Path $NewPipelinesPath -ItemType Directory -Force | Out-Null
    }
    
    # Template pipeline paths
    $templatePipelinesPath = Join-Path $TemplateDirectory 'pipelines'
    
    # Migrate BUILD.yml
    $oldBuildPath = Join-Path $OldPipelinesPath 'build.yml'
    $newBuildPath = Join-Path $NewPipelinesPath 'BUILD.yml'
    
    if (Test-Path $oldBuildPath) {
        Write-Host "Migrating build.yml to BUILD.yml..." -ForegroundColor Yellow
        $templateBuild = Join-Path $templatePipelinesPath 'BUILD.yml'
        
        if (Test-Path $templateBuild) {
            Copy-Item -Path $templateBuild -Destination $newBuildPath -Force
            
            # Replace repository name in the copied file
            $buildContent = Get-Content -Path $newBuildPath -Raw
            $buildContent = $buildContent -replace '(\s+)name: ALM4Dataverse', '$1name: Dataverse-ALM'
            $buildContent | Out-File -FilePath $newBuildPath -Encoding UTF8 -NoNewline
            
            Write-Host "  Created BUILD.yml from template" -ForegroundColor Green
        }
        else {
            throw "Template BUILD.yml not found at $templateBuild"
        }
    }
    
    # Migrate EXPORT.yml
    $oldExportPath = Join-Path $OldPipelinesPath 'export.yml'
    $newExportPath = Join-Path $NewPipelinesPath 'EXPORT.yml'
    
    if (Test-Path $oldExportPath) {
        Write-Host "Migrating export.yml to EXPORT.yml..." -ForegroundColor Yellow
        $templateExport = Join-Path $templatePipelinesPath 'EXPORT.yml'
        
        if (Test-Path $templateExport) {
            Copy-Item -Path $templateExport -Destination $newExportPath -Force
            
            # Replace repository name in the copied file
            $exportContent = Get-Content -Path $newExportPath -Raw
            $exportContent = $exportContent -replace '(\s+)name: ALM4Dataverse', '$1name: Dataverse-ALM'
            $exportContent | Out-File -FilePath $newExportPath -Encoding UTF8 -NoNewline
            
            Write-Host "  Created EXPORT.yml from template" -ForegroundColor Green
        }
        else {
            throw "Template EXPORT.yml not found at $templateExport"
        }
    }
    
    # Migrate IMPORT.yml
    $oldImportPath = Join-Path $OldPipelinesPath 'import.yml'
    $newImportPath = Join-Path $NewPipelinesPath 'IMPORT.yml'
    
    if (Test-Path $oldImportPath) {
        Write-Host "Migrating import.yml to IMPORT.yml..." -ForegroundColor Yellow
        $templateImport = Join-Path $templatePipelinesPath 'IMPORT.yml'
        
        if (Test-Path $templateImport) {
            Copy-Item -Path $templateImport -Destination $newImportPath -Force
            
            # Replace repository name in the copied file
            $importContent = Get-Content -Path $newImportPath -Raw
            $importContent = $importContent -replace '(\s+)name: ALM4Dataverse', '$1name: Dataverse-ALM'
            $importContent | Out-File -FilePath $newImportPath -Encoding UTF8 -NoNewline
            
            Write-Host "  Created IMPORT.yml from template" -ForegroundColor Green
        }
        else {
            throw "Template IMPORT.yml not found at $templateImport"
        }
    }
    
    # Migrate DEPLOY.yml with environment stages
    $oldDeployPath = Join-Path $OldPipelinesPath 'deploy.yml'
    
    if (Test-Path $oldDeployPath) {
        Write-Host "Migrating deploy.yml to DEPLOY-main.yml..." -ForegroundColor Yellow
        
        # Parse the old deploy.yml to extract environment stages
        $envStages = @()
        $lines = Get-Content -Path $oldDeployPath
        
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            
            if ($line -match '^\s*-\s*template:\s*stage-templates/deploy-env\.yml@') {
                # Found a deploy-env stage, extract parameters
                $envName = $null
                $serviceConnection = $null
                $retentionDays = $null
                
                # Look ahead for parameters
                $j = $i + 1
                while ($j -lt $lines.Count -and $lines[$j] -match '^\s+(parameters:|environment:|dataverseserviceconnectionname:|buildRetentionDaysOnSuccess:)') {
                    $paramLine = $lines[$j]
                    
                    if ($paramLine -match 'environment:\s*[\''"]([^\''"]*)[\''"]|environment:\s*([^\s]+)') {
                        $envName = if ($matches[1]) { $matches[1].Trim() } else { $matches[2].Trim() }
                    }
                    elseif ($paramLine -match 'dataverseserviceconnectionname:\s*[\''"]([^\''"]*)[\''"]|dataverseserviceconnectionname:\s*([^\s]+)') {
                        $serviceConnection = if ($matches[1]) { $matches[1].Trim() } else { $matches[2].Trim() }
                    }
                    elseif ($paramLine -match 'buildRetentionDaysOnSuccess:\s*(\d+)') {
                        $retentionDays = $matches[1]
                    }
                    
                    $j++
                }
                
                if ($envName) {
                    $envStages += @{
                        EnvironmentName   = $envName
                        ServiceConnection = $serviceConnection
                        RetentionDays     = $retentionDays
                    }
                }
            }
        }
        
        # Load template and customize
        $templateDeploy = Join-Path $templatePipelinesPath 'DEPLOY-main.yml'
        
        if (Test-Path $templateDeploy) {
            $deployContent = Get-Content -Path $templateDeploy -Raw
            
            # Build the stages section
            $stagesSection = New-Object System.Text.StringBuilder
            
            if ($envStages.Count -gt 0) {
                [void]$stagesSection.AppendLine()
                [void]$stagesSection.AppendLine('  # Migrated environment stages from legacy deploy.yml')
                
                foreach ($stage in $envStages) {
                    [void]$stagesSection.AppendLine()
                    [void]$stagesSection.AppendLine('  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse')
                    [void]$stagesSection.AppendLine('    parameters:')
                    [void]$stagesSection.AppendLine("      environmentName: '$($stage.EnvironmentName)'")
                    
                    if ($stage.ServiceConnection) {
                        [void]$stagesSection.AppendLine("      # NOTE: The new format uses convention-based naming.")
                        [void]$stagesSection.AppendLine("      # - Environment: $($stage.EnvironmentName)")
                        [void]$stagesSection.AppendLine("      # - Variable Group: Environment-$($stage.EnvironmentName)")
                        [void]$stagesSection.AppendLine("      # - Service Connection: $($stage.EnvironmentName)")
                    }
                    
                    if ($stage.RetentionDays) {
                        [void]$stagesSection.AppendLine("      # Legacy buildRetentionDaysOnSuccess: $($stage.RetentionDays)")
                        [void]$stagesSection.AppendLine("      # NOTE: Build retention is not currently supported in the new format")
                    }
                }
            }
            
            # Replace the example stage with actual stages
            # Pattern matches from "stages:" through the commented example lines
            $deployContent = $deployContent -replace '(?s)(stages:).*?(#\s*-\s*template:.*?environmentName:.*?)$', "`$1$($stagesSection.ToString())"
            
            # Update the pipeline trigger source to include the repository folder
            $newSource = "\$AzDoRepository\BUILD"
            $deployContent = $deployContent -replace "source:\s*'BUILD'", "source: '$newSource'"
            
            # Replace repository name (but not the repository identifier)
            $deployContent = $deployContent -replace '(\s+)name: ALM4Dataverse', '$1name: Dataverse-ALM'
            
            $newDeployPath = Join-Path $NewPipelinesPath 'DEPLOY-main.yml'
            $deployContent | Out-File -FilePath $newDeployPath -Encoding UTF8
            
            Write-Host "  Created DEPLOY-main.yml with $($envStages.Count) environment stage(s)" -ForegroundColor Green
        }
        else {
            throw "Template DEPLOY-main.yml not found at $templateDeploy"
        }
        
        if ($envStages.Count -gt 0) {
            Write-Host ""
            Write-Host "  Migrated environments:" -ForegroundColor Cyan
            foreach ($stage in $envStages) {
                Write-Host "    - $($stage.EnvironmentName)" -ForegroundColor Gray
                if ($stage.ServiceConnection) {
                    Write-Host "    Service connection '$($stage.ServiceConnection)' needs to be renamed to '$($stage.EnvironmentName)'"
                }
            }
            
            # Save to script-level variable for use in service connection renaming
            $script:migratedEnvironments = $envStages
        }
    }
    
    # Rename old pipelines directory
    $migratedPipelinesPath = "$OldPipelinesPath.migrated"
    Write-Host ""
    Write-Host "Renaming alm-pipelines to: $migratedPipelinesPath" -ForegroundColor Yellow
    Rename-Item -Path $OldPipelinesPath -NewName "$OldPipelinesPath.migrated" -Force
}
else {
    Write-Host ""
    Write-Host "Pipeline file migration skipped (already completed or not found)" -ForegroundColor Green
    
    # Parse environment stages from the already migrated deploy.yml
    # This is needed for service connection and variable group migration
    if (Test-Path $OldPipelinesMigratedPath) {
        Write-Host "Parsing environment stages from migrated pipelines..." -ForegroundColor Yellow
        
        $oldDeployPath = Join-Path $OldPipelinesMigratedPath 'deploy.yml'
        
        if (Test-Path $oldDeployPath) {
            # Parse the old deploy.yml to extract environment stages
            $envStages = @()
            $lines = Get-Content -Path $oldDeployPath
            
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                
                if ($line -match '^\s*-\s*template:\s*stage-templates/deploy-env\.yml@') {
                    # Found a deploy-env stage, extract parameters
                    $envName = $null
                    $serviceConnection = $null
                    $retentionDays = $null
                    
                    # Look ahead for parameters
                    $j = $i + 1
                    while ($j -lt $lines.Count -and $lines[$j] -match '^\s+(parameters:|environment:|dataverseserviceconnectionname:|buildRetentionDaysOnSuccess:)') {
                        $paramLine = $lines[$j]
                        
                        if ($paramLine -match 'environment:\s*[\''"]([^\''"]*)[\''"]|environment:\s*([^\s]+)') {
                            $envName = if ($matches[1]) { $matches[1].Trim() } else { $matches[2].Trim() }
                        }
                        elseif ($paramLine -match 'dataverseserviceconnectionname:\s*[\''"]([^\''"]*)[\''"]|dataverseserviceconnectionname:\s*([^\s]+)') {
                            $serviceConnection = if ($matches[1]) { $matches[1].Trim() } else { $matches[2].Trim() }
                        }
                        elseif ($paramLine -match 'buildRetentionDaysOnSuccess:\s*(\d+)') {
                            $retentionDays = $matches[1]
                        }
                        
                        $j++
                    }
                    
                    if ($envName) {
                        $envStages += @{
                            EnvironmentName   = $envName
                            ServiceConnection = $serviceConnection
                            RetentionDays     = $retentionDays
                        }
                    }
                }
            }
            
            if ($envStages.Count -gt 0) {
                Write-Host "  Found $($envStages.Count) environment stage(s):" -ForegroundColor Green
                foreach ($stage in $envStages) {
                    Write-Host "    - $($stage.EnvironmentName)" -ForegroundColor Gray
                }
                
                # Save to script-level variable for use in service connection renaming
                $script:migratedEnvironments = $envStages
            }
            else {
                Write-Warning "No environment stages found in $oldDeployPath"
            }
        }
        else {
            Write-Warning "deploy.yml not found in migrated pipelines folder: $oldDeployPath"
            Write-Warning "Service connection and variable group migration may be incomplete"
        }
    }
    else {
        Write-Warning "Migrated pipelines folder not found: $OldPipelinesMigratedPath"
        Write-Warning "Service connection and variable group migration may be incomplete"
    }
}

#==============================================================================
# Migrate Azure DevOps Pipeline Definitions
#==============================================================================

# Since AzDO detection is now mandatory, we only skip if explicitly requested
$shouldMigrateAzDo = -not $NoAzDoConnection

if ($shouldMigrateAzDo) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Migrating Azure DevOps Pipeline Definitions" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    
    # Install and import VSTeam module
    Write-Host "Checking for VSTeam PowerShell module..." -ForegroundColor Yellow
    
    $vsTeamModule = Get-Module -Name VSTeam -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    
    if (-not $vsTeamModule) {
        Write-Host "  Installing VSTeam module..." -ForegroundColor Yellow
        Install-Module -Name VSTeam -Scope CurrentUser -Force -AllowClobber
        $vsTeamModule = Get-Module -Name VSTeam -ListAvailable | Select-Object -First 1
    }
    
    Write-Host "  Importing VSTeam module version $($vsTeamModule.Version)..." -ForegroundColor Yellow
    Import-Module -Name VSTeam -RequiredVersion $vsTeamModule.Version -Force
    
    # Authenticate to Azure DevOps
    Write-Host "Authenticating to Azure DevOps..." -ForegroundColor Yellow
    Write-Host "  Organization: $AzDoOrganization" -ForegroundColor Gray
    Write-Host "  Project: $AzDoProject" -ForegroundColor Gray
    Write-Host ""
    
    $authSuccess = $false
    
    # Try using provided PAT first
    if ($PersonalAccessToken) {
        Write-Host "Using provided Personal Access Token..." -ForegroundColor Yellow
        try {
            $secureToken = ConvertTo-SecureString -String $PersonalAccessToken -AsPlainText -Force
            Set-VSTeamAccount -Account $AzDoOrganization -SecurePersonalAccessToken $secureToken -Force
            Write-Host "  ✓ Connected to Azure DevOps successfully with PAT" -ForegroundColor Green
            $authSuccess = $true
        }
        catch {
            throw "Failed to authenticate with provided PAT: $($_.Exception.Message)"
        }
    }
    
    # Try browser-based authentication if no PAT or PAT failed
    if (-not $authSuccess) {
        Write-Host "Attempting browser-based authentication..." -ForegroundColor Yellow
        Write-Host "A browser window will open for authentication..." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Note: If authentication hangs or fails, you can:" -ForegroundColor Cyan
        Write-Host "      1. Press Ctrl+C to cancel and be prompted for a PAT" -ForegroundColor Cyan
        Write-Host "      2. Type 'skip' below to skip browser auth and enter a PAT directly" -ForegroundColor Cyan
        Write-Host ""
        $response = Read-Host "Press Enter to try browser auth, or type 'skip' to enter a PAT"
        
        if ($response -eq 'skip') {
            Write-Host "Skipping browser authentication" -ForegroundColor Yellow
        }
        else {
            # Azure DevOps resource for AAD token acquisition
            $adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'
            
            try {
                Write-Host ""
                Write-Host "Opening browser for authentication..." -ForegroundColor Yellow
                Write-Host "If no browser opens, or you prefer to skip this, type 'cancel' at the prompt" -ForegroundColor Gray
                Write-Host ""
                
                $adoAuthResult = Get-AuthToken -ResourceUrl $adoResourceUrl
                
                if ($adoAuthResult -and $adoAuthResult.AccessToken) {
                    $secureToken = ConvertTo-SecureString -String $adoAuthResult.AccessToken -AsPlainText -Force
                    Set-VSTeamAccount -Account $AzDoOrganization -SecurePersonalAccessToken $secureToken -UseBearerToken -Force
                    Write-Host "  ✓ Connected to Azure DevOps successfully with browser auth" -ForegroundColor Green
                    $authSuccess = $true
                }
                elseif ($null -eq $adoAuthResult) {
                    # User cancelled - will fall back to PAT entry below
                    Write-Host "Browser authentication cancelled. Proceeding to PAT entry." -ForegroundColor Yellow
                }
                else {
                    throw "Failed to acquire an Azure DevOps access token."
                }
            }
            catch [System.OperationCanceledException] {
                Write-Host ""
                Write-Host "Browser authentication was cancelled" -ForegroundColor Yellow
            }
            catch {
                Write-Host ""
                Write-Warning "Browser-based authentication failed: $($_.Exception.Message)"
            }
        }
    }
    
    # If both methods failed, prompt for PAT
    if (-not $authSuccess) {
        Write-Host ""
        Write-Host "Both authentication methods failed. Please provide a Personal Access Token." -ForegroundColor Yellow
        Write-Host "You can create a PAT at: https://dev.azure.com/$AzDoOrganization/_usersSettings/tokens" -ForegroundColor Cyan
        Write-Host "Required scopes: Build (Read & Execute), Code (Read), Variable Groups (Read & Manage)" -ForegroundColor Cyan
        Write-Host ""
        
        $pat = Read-Host "Enter your Personal Access Token (PAT)" -AsSecureString
        $patPlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pat)
        )
        
        try {
            $secureToken = ConvertTo-SecureString -String $patPlainText -AsPlainText -Force
            Set-VSTeamAccount -Account $AzDoOrganization -SecurePersonalAccessToken $secureToken -Force
            Write-Host "  ✓ Connected to Azure DevOps successfully with manually entered PAT" -ForegroundColor Green
            $authSuccess = $true
        }
        catch {
            Write-Host ""
            Write-Host "ERROR: Failed to authenticate to Azure DevOps: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }
    
    # Set the default project
    Set-VSTeamDefaultProject -Project $AzDoProject
    
    # Get all pipelines in the project
    Write-Host "Retrieving pipeline definitions..." -ForegroundColor Yellow
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $AzDoProject
    
    # Define the migration mapping
    $pathMappings = @{
        'alm-pipelines/build.yml'  = 'pipelines/BUILD.yml'
        'alm-pipelines/export.yml' = 'pipelines/EXPORT.yml'
        'alm-pipelines/import.yml' = 'pipelines/IMPORT.yml'
        'alm-pipelines/deploy.yml' = 'pipelines/DEPLOY-main.yml'
    }
    
    $updatedPipelines = @()
    
    foreach ($pipeline in $allPipelines) {
        # Get full pipeline definition
        $fullPipeline = Get-VSTeamBuildDefinition -ProjectName $AzDoProject -Id $pipeline.id
        
        # Check if this pipeline uses YAML and points to our repository
        if ($fullPipeline.process -and $fullPipeline.process.type -eq 2) {
            $yamlPath = $fullPipeline.process.yamlFilename
            $repoName = $fullPipeline.repository.name
            
            # Only process if it's our target repository
            if ($repoName -eq $AzDoRepository) {
                # Check if the YAML path needs migration
                $normalizedPath = $yamlPath -replace '\\', '/'
                
                if ($pathMappings.ContainsKey($normalizedPath.TrimStart('/'))) {
                    $newPath = $pathMappings[$normalizedPath.TrimStart('/')]
                    
                    Write-Host ""
                    Write-Host "Found pipeline to migrate:" -ForegroundColor Cyan
                    Write-Host "  Pipeline: $($pipeline.name)" -ForegroundColor White
                    Write-Host "  Old path: $yamlPath" -ForegroundColor Yellow
                    Write-Host "  New path: $newPath" -ForegroundColor Green
                    
                    # Calculate the new folder path based on repository name
                    $oldFolder = $fullPipeline.path
                    $newFolder = "\$AzDoRepository"
                    
                    # Update the pipeline
                    $fullPipeline.process.yamlFilename = $newPath
                    $fullPipeline.path = $newFolder
                    
                    Write-Host "  Old folder: $oldFolder" -ForegroundColor Yellow
                    Write-Host "  New folder: $newFolder" -ForegroundColor Green
                    
                    # Use Invoke-VSTeamRequest to update the pipeline
                    $resource = "build/definitions/$($pipeline.id)"
                    $body = $fullPipeline | ConvertTo-Json -Depth 50
                    
                    try {
                        [void](Invoke-VSTeamRequest -Method PUT -Resource $resource -Body $body -ContentType 'application/json' -Version '7.1')
                        Write-Host "  ✓ Updated successfully" -ForegroundColor Green
                        
                        $updatedPipelines += @{
                            Name      = $pipeline.name
                            OldPath   = $yamlPath
                            NewPath   = $newPath
                            OldFolder = $oldFolder
                            NewFolder = $newFolder
                        }
                    }
                    catch {
                        throw "  Failed to update pipeline: $($_.Exception.Message)"
                    }
                }
            }
        }
    }
    
    if ($updatedPipelines.Count -eq 0) {
        Write-Host ""
        Write-Host "No pipelines found that need migration." -ForegroundColor Yellow
    }
    else {
        Write-Host ""
        Write-Host "==================================================================" -ForegroundColor Green
        Write-Host "Azure DevOps Pipeline Migration Summary" -ForegroundColor Green
        Write-Host "==================================================================" -ForegroundColor Green
        Write-Host "Updated $($updatedPipelines.Count) pipeline(s):" -ForegroundColor White
        foreach ($p in $updatedPipelines) {
            Write-Host "  - $($p.Name)" -ForegroundColor Gray
            Write-Host "    YAML path: $($p.OldPath) → $($p.NewPath)" -ForegroundColor Gray
            Write-Host "    Folder: $($p.OldFolder) → $($p.NewFolder)" -ForegroundColor Gray
        }
    }
    
    #==============================================================================
    # Migrate Service Connections and Variable Groups
    #==============================================================================
    
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Migrating Service Connections and Variable Groups" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
    
    # Get all variable groups
    Write-Host "Retrieving variable groups..." -ForegroundColor Yellow
    
    if ($script:migratedEnvironments.Count -eq 0) {
        Write-Host "  No environments were migrated, skipping variable group check" -ForegroundColor Gray
    }
    else {
        try {
            $variableGroups = Invoke-VSTeamRequest -Resource "distributedtask/variablegroups" -Version '7.1-preview.2' -ProjectName $AzDoProject
            
            $renamedVarGroups = @()
            
            # Build a map of environment names to their service connections from variable groups
            $script:environmentServiceConnections = @{}
            
            foreach ($env in $script:migratedEnvironments) {
                $targetEnvName = $env.EnvironmentName
                $expectedNewName = "Environment-$targetEnvName"
                
                # First check if variable group already has the correct name
                $vgTarget = $variableGroups.value | Where-Object { $_.name -eq $expectedNewName }
                
                if ($vgTarget) {
                    Write-Host "  ✓ Variable group '$expectedNewName' already has correct name (migration already completed)" -ForegroundColor Green
                    # Still extract service connection name if available
                    if ($vgTarget.variables -and $vgTarget.variables.PSObject.Properties['DataverseServiceConnectionName']) {
                        $serviceConnectionName = $vgTarget.variables.DataverseServiceConnectionName.value
                        $script:environmentServiceConnections[$targetEnvName] = $serviceConnectionName
                        Write-Host "    Found service connection '$serviceConnectionName' for environment '$targetEnvName'" -ForegroundColor Gray
                    }
                    continue
                }
                
                # Try to find the variable group for this environment
                # It might be named after the environment or already follow the new convention
                $vg = $variableGroups.value | Where-Object { 
                    $_.name -eq $targetEnvName -or 
                    $_.name -eq "Environment $targetEnvName" -or
                    $_.name -like "*$targetEnvName*"
                } | Select-Object -First 1
                
                if (-not $vg) {
                    # Check if it might have already been migrated to the target name
                    if ($vgTarget) {
                        Write-Host "  ℹ Variable group has already been renamed to '$expectedNewName' (no action needed)" -ForegroundColor Gray
                    }
                    else {
                        Write-Error "ERROR: Variable group for environment '$targetEnvName' not found. Expected to find a group named '$targetEnvName' or similar, or already named '$expectedNewName'. Please create or rename the variable group manually." -ErrorAction Continue
                    }
                    continue
                }
                
                $oldName = $vg.name
                
                # Extract service connection name from the variable group
                if ($vg.variables -and $vg.variables.PSObject.Properties['DataverseServiceConnectionName']) {
                    $serviceConnectionName = $vg.variables.DataverseServiceConnectionName.value
                    $script:environmentServiceConnections[$targetEnvName] = $serviceConnectionName
                    Write-Host "  Found service connection '$serviceConnectionName' for environment '$targetEnvName'" -ForegroundColor Gray
                }
                
                Write-Host ""
                Write-Host "Renaming variable group:" -ForegroundColor Cyan
                Write-Host "  Old name: $oldName" -ForegroundColor Yellow
                Write-Host "  New name: $expectedNewName" -ForegroundColor Green
                Write-Host "  Environment: $targetEnvName" -ForegroundColor Gray
                
                try {
                    # Get the full variable group details with project references
                    $vgFull = Invoke-VSTeamRequest -Resource "distributedtask/variablegroups/$($vg.id)" -Version '7.1-preview.2' -ProjectName $AzDoProject
                    
                    # Update the name in the full object
                    $vgFull.name = $expectedNewName
                    
                    # Update the project reference names to match
                    if ($vgFull.variableGroupProjectReferences -and $vgFull.variableGroupProjectReferences.Count -gt 0) {
                        foreach ($ref in $vgFull.variableGroupProjectReferences) {
                            $ref.name = $expectedNewName
                        }
                    }
                    
                    # Add note variable for deprecated DataverseServiceConnectionName
                    if (-not $vgFull.variables) {
                        $vgFull.variables = @{}
                    }
                    $vgFull.variables | Add-Member -MemberType NoteProperty -Name 'DataverseServiceConnectionName_NOTE' -Value @{ value = 'No longer used - kept for reference' } -Force
                    
                    $body = $vgFull | ConvertTo-Json -Depth 50 -Compress
                    
                    [void](Invoke-VSTeamRequest -Method PUT -Resource "distributedtask/variablegroups/$($vg.id)" -Body $body -ContentType 'application/json' -Version '7.1-preview.2' -ProjectName $AzDoProject)
                    Write-Host "  ✓ Renamed successfully" -ForegroundColor Green
                    
                    $renamedVarGroups += @{
                        OldName     = $oldName
                        NewName     = $expectedNewName
                        Environment = $targetEnvName
                    }
                }
                catch {
                    throw "Failed to rename variable group '$oldName' to '$expectedNewName': $($_.Exception.Message)"
                }
            }
            
            if ($renamedVarGroups.Count -gt 0) {
                Write-Host ""
                Write-Host "Successfully renamed $($renamedVarGroups.Count) variable group(s)" -ForegroundColor Green
            }
            elseif ($script:migratedEnvironments.Count -gt 0) {
                Write-Host ""
                Write-Host "  ✓ All variable groups are correctly named" -ForegroundColor Green
            }
        }
        catch {
            throw "Failed to retrieve or update variable groups: $($_.Exception.Message)"
        }
    }
    
    # Get all service connections and rename based on migrated environments
    Write-Host ""
    Write-Host "Checking service connections..." -ForegroundColor Yellow
    
    if ($script:migratedEnvironments.Count -eq 0) {
        Write-Host "  No environments were migrated, skipping service connection check" -ForegroundColor Gray
    }
    else {
        $serviceConnections = Invoke-VSTeamRequest -Resource "serviceendpoint/endpoints" -Version '7.1-preview.4' -ProjectName $AzDoProject
            
        $renamedConnections = @()
            
        foreach ($env in $script:migratedEnvironments) {
            $targetEnvName = $env.EnvironmentName
                
            # Try to get service connection name from variable group first
            $oldServiceConnectionName = $null
            if ($script:environmentServiceConnections -and $script:environmentServiceConnections.ContainsKey($targetEnvName)) {
                $oldServiceConnectionName = $script:environmentServiceConnections[$targetEnvName]
                Write-Host "  Using service connection '$oldServiceConnectionName' from variable group for environment '$targetEnvName'" -ForegroundColor Gray
            }
            # Fallback to service connection from deploy.yml if not found in variable group
            elseif ($env.ServiceConnection) {
                $oldServiceConnectionName = $env.ServiceConnection
                Write-Host "  Using service connection '$oldServiceConnectionName' from deploy.yml for environment '$targetEnvName'" -ForegroundColor Gray
            }
                
            if (-not $oldServiceConnectionName) {
                Write-Warning "No service connection name found for environment '$targetEnvName'"
                continue
            }
                
            # First check if service connection already has the correct name (target name)
            $scTarget = $serviceConnections.value | Where-Object { $_.name -eq $targetEnvName }
            
            if ($scTarget) {
                Write-Host "  ✓ Service connection '$targetEnvName' already has correct name (migration already completed)" -ForegroundColor Green
                continue
            }
            
            # Find the service connection by old name
            $sc = $serviceConnections.value | Where-Object { $_.name -eq $oldServiceConnectionName }
            
            if (-not $sc) {
                # Check if the target name exists (migration may have been done manually)
                if ($scTarget) {
                    Write-Host "  ℹ Service connection has already been renamed to '$targetEnvName' (no action needed)" -ForegroundColor Gray
                    continue
                }
                else {
                    Write-Error "ERROR: Service connection '$oldServiceConnectionName' not found and target name '$targetEnvName' does not exist for environment '$targetEnvName'. Please create or rename the service connection manually." -ErrorAction Continue
                    continue
                }
            }
                
            Write-Host ""
            Write-Host "Renaming service connection:" -ForegroundColor Cyan
            Write-Host "  Old name: $oldServiceConnectionName" -ForegroundColor Yellow
            Write-Host "  New name: $targetEnvName" -ForegroundColor Green
            Write-Host "  Environment: $targetEnvName" -ForegroundColor Gray
                
            try {
                # Get the full service connection details
                $scFull = Invoke-VSTeamRequest -Resource "serviceendpoint/endpoints/$($sc.id)" -Version '7.1-preview.4' -ProjectName $AzDoProject
                    
                # Update BOTH the top-level name and the project reference name
                # Both need to match for the API to accept it
                $scFull.name = $targetEnvName
                    
                if ($scFull.serviceEndpointProjectReferences -and $scFull.serviceEndpointProjectReferences.Count -gt 0) {
                    foreach ($ref in $scFull.serviceEndpointProjectReferences) {
                        $ref.name = $targetEnvName
                    }
                }
                    
                $bodyJson = $scFull | ConvertTo-Json -Depth 50 -Compress
                    
                # Use PUT to update the service connection
                [void](Invoke-VSTeamRequest -Method PUT -Resource "serviceendpoint/endpoints/$($sc.id)" -Body $bodyJson -ContentType 'application/json' -Version '7.1-preview.4' -ProjectName $AzDoProject)
                Write-Host "  ✓ Renamed successfully" -ForegroundColor Green
                    
                $renamedConnections += @{
                    OldName     = $oldServiceConnectionName
                    NewName     = $targetEnvName
                    Environment = $targetEnvName
                }
            }
            catch {
                throw "Failed to rename service connection '$oldServiceConnectionName' to '$targetEnvName': $($_.Exception.Message)"
            }
        }
            
        if ($renamedConnections.Count -gt 0) {
            Write-Host ""
            Write-Host "Successfully renamed $($renamedConnections.Count) service connection(s)" -ForegroundColor Green
        }
        elseif ($script:migratedEnvironments.Count -gt 0) {
            Write-Host "  ✓ All service connections are correctly named" -ForegroundColor Green
        }
       
    }
    
    #==============================================================================
    # Handle DEV - main variable group and its service connection
    #==============================================================================
    
    Write-Host ""
    Write-Host "Checking for 'DEV - main' variable group..." -ForegroundColor Yellow
    
    try {
        $variableGroups = Invoke-VSTeamRequest -Resource "distributedtask/variablegroups" -Version '7.1-preview.2' -ProjectName $AzDoProject

        # Check if Environment-DEV-main already exists
        $buildVgTarget = $variableGroups.value | Where-Object { $_.name -eq 'Environment-DEV-main' }
        
        if ($buildVgTarget) {
            Write-Host "  Variable group 'Environment-DEV-main' already exists with correct name" -ForegroundColor Gray
        }
        else {
            # Look for "DEV - main" variable group
            $devMainVg = $variableGroups.value | Where-Object { $_.name -eq 'DEV - main' }
            
            if ($devMainVg) {
                $oldName = 'DEV - main'
                $newName = 'Environment-DEV-main'
                
                # Extract service connection name from the variable group
                $devMainServiceConnection = $null
                if ($devMainVg.variables -and $devMainVg.variables.PSObject.Properties['DataverseServiceConnectionName']) {
                    $devMainServiceConnection = $devMainVg.variables.DataverseServiceConnectionName.value
                    Write-Host "  Found service connection '$devMainServiceConnection' in 'DEV - main' variable group" -ForegroundColor Gray
                }
                
                Write-Host ""
                Write-Host "Renaming variable group:" -ForegroundColor Cyan
                Write-Host "  Old name: $oldName" -ForegroundColor Yellow
                Write-Host "  New name: $newName" -ForegroundColor Green
                
                try {
                    # Get the full variable group details with project references
                    $devMainVgFull = Invoke-VSTeamRequest -Resource "distributedtask/variablegroups/$($devMainVg.id)" -Version '7.1-preview.2' -ProjectName $AzDoProject
                    
                    # Update the name in the full object
                    $devMainVgFull.name = $newName
                    
                    # Update the project reference names to match
                    if ($devMainVgFull.variableGroupProjectReferences -and $devMainVgFull.variableGroupProjectReferences.Count -gt 0) {
                        foreach ($ref in $devMainVgFull.variableGroupProjectReferences) {
                            $ref.name = $newName
                        }
                    }
                    
                    # Add note variable for deprecated DataverseServiceConnectionName
                    if (-not $devMainVgFull.variables) {
                        $devMainVgFull.variables = @{}
                    }
                    $devMainVgFull.variables | Add-Member -MemberType NoteProperty -Name 'DataverseServiceConnectionName_NOTE' -Value @{ value = 'No longer used - kept for reference' } -Force
                    
                    $body = $devMainVgFull | ConvertTo-Json -Depth 50 -Compress
                    
                    [void](Invoke-VSTeamRequest -Method PUT -Resource "distributedtask/variablegroups/$($devMainVg.id)" -Body $body -ContentType 'application/json' -Version '7.1-preview.2' -ProjectName $AzDoProject)
                    Write-Host "  ✓ Renamed variable group successfully" -ForegroundColor Green
                }
                catch {
                    throw "Failed to rename variable group '$oldName' to '$newName': $($_.Exception.Message)"
                }
                
                # Now rename the associated service connection if found
                if ($devMainServiceConnection) {
                    Write-Host ""
                    Write-Host "Checking service connection '$devMainServiceConnection'..." -ForegroundColor Yellow
                    
                    $serviceConnections = Invoke-VSTeamRequest -Resource "serviceendpoint/endpoints" -Version '7.1-preview.4' -ProjectName $AzDoProject
                    
                    # Check if target service connection already exists
                    $scTarget = $serviceConnections.value | Where-Object { $_.name -eq 'DEV-main' }
                    
                    if ($scTarget) {
                        Write-Host "  ✓ Service connection 'DEV-main' already has correct name (migration already completed)" -ForegroundColor Green
                    }
                    else {
                        # Find the service connection by the name from variable group
                        $devMainSc = $serviceConnections.value | Where-Object { $_.name -eq $devMainServiceConnection }
                        
                        if ($devMainSc) {
                            $scOldName = $devMainServiceConnection
                            $scNewName = 'DEV-main'
                            
                            Write-Host ""
                            Write-Host "Renaming service connection:" -ForegroundColor Cyan
                            Write-Host "  Old name: $scOldName" -ForegroundColor Yellow
                            Write-Host "  New name: $scNewName" -ForegroundColor Green
                            
                            try {
                                # Get the full service connection details
                                $devMainScFull = Invoke-VSTeamRequest -Resource "serviceendpoint/endpoints/$($devMainSc.id)" -Version '7.1-preview.4' -ProjectName $AzDoProject
                                
                                # Update BOTH the top-level name and the project reference name
                                $devMainScFull.name = $scNewName
                                
                                if ($devMainScFull.serviceEndpointProjectReferences -and $devMainScFull.serviceEndpointProjectReferences.Count -gt 0) {
                                    foreach ($ref in $devMainScFull.serviceEndpointProjectReferences) {
                                        $ref.name = $scNewName
                                    }
                                }
                                
                                $bodyJson = $devMainScFull | ConvertTo-Json -Depth 50 -Compress
                                
                                # Use PUT to update the service connection
                                [void](Invoke-VSTeamRequest -Method PUT -Resource "serviceendpoint/endpoints/$($devMainSc.id)" -Body $bodyJson -ContentType 'application/json' -Version '7.1-preview.4' -ProjectName $AzDoProject)
                                Write-Host "  ✓ Renamed service connection successfully" -ForegroundColor Green
                            }
                            catch {
                                throw "Failed to rename service connection '$scOldName' to '$scNewName': $($_.Exception.Message)"
                            }
                        }
                        else {
                            # Check if the target name exists (migration may have been done manually)
                            if ($scTarget) {
                                Write-Host "  ℹ Service connection has already been renamed to 'DEV-main' (no action needed)" -ForegroundColor Gray
                            }
                            else {
                                Write-Error "ERROR: Service connection '$devMainServiceConnection' not found and target name 'DEV-main' does not exist. Please create or rename the service connection manually." -ErrorAction Continue
                            }
                        }
                    }
                }
            }
            else {
                Write-Host "  Variable group 'DEV - main' not found (may already be migrated or not exist)" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Warning "Failed to process 'DEV - main' variable group: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "Migration complete!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Review the generated alm-config.psd1 file" -ForegroundColor White
Write-Host "2. Review the generated pipeline files in the pipelines/ folder" -ForegroundColor White

if ($NoAzDoConnection) {
    Write-Host "3. Update Azure DevOps pipeline definitions manually to point to new paths" -ForegroundColor White
    Write-Host "   Or run this script again without -NoAzDoConnection to automatically update them" -ForegroundColor Gray
    Write-Host "4. Update service connections to match the new naming convention" -ForegroundColor White
    Write-Host "5. Update variable groups to match the new naming convention (Environment-{EnvironmentName})" -ForegroundColor White
}
else {
    Write-Host "3. Review renamed service connections and variable groups" -ForegroundColor White
    Write-Host "   (Automatic renaming was attempted where patterns were detected)" -ForegroundColor Gray
}

Write-Host "6. Commit and push the migrated files to your repository" -ForegroundColor White
Write-Host "7. Test the migration by running the pipelines" -ForegroundColor White
Write-Host ""
