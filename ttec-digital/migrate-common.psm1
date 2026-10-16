#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Common functions for migrating Dataverse ALM repositories.

.DESCRIPTION
    This module provides shared functions for migrating legacy Dataverse ALM repositories
    to the new ALM4Dataverse format. It includes:
    - Helper functions for building configuration sections
    - Configuration file migration logic
#>

#==============================================================================
# Helper Functions
#==============================================================================

function Build-SolutionsSection {
    param([array]$Solutions)
    
    if (-not $Solutions -or $Solutions.Count -eq 0) {
        return "`n"
    }
    
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine()
    
    foreach ($solution in $Solutions) {
        [void]$sb.AppendLine('        @{')
        [void]$sb.AppendLine("            name = '$($solution.name)'")
        
        if ($solution.ContainsKey('deployUnmanaged')) {
            $deployUnmanagedValue = if ($solution.deployUnmanaged) { '$true' } else { '$false' }
            [void]$sb.AppendLine("            deployUnmanaged = $deployUnmanagedValue")
        }
        
        if ($solution.ContainsKey('serviceAccountUpnConfigKey')) {
            [void]$sb.AppendLine("            serviceAccountUpnConfigKey = '$($solution.serviceAccountUpnConfigKey)'")
        }
        
        [void]$sb.AppendLine('        }')
    }
    
    [void]$sb.Append('    ')
    return $sb.ToString()
}

function Build-AssetsSection {
    param([array]$Assets)
    
    if (-not $Assets -or $Assets.Count -eq 0) {
        return "`n"
    }
    
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine()
    
    foreach ($asset in $Assets) {
        [void]$sb.AppendLine("        '$asset'")
    }
    
    [void]$sb.Append('    ')
    return $sb.ToString()
}

function Build-HooksSection {
    param([hashtable]$Hooks)
    
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine()
    
    # Build each hook section
    $hookNames = @('preExport', 'postExport', 'preDeploy', 'postDeploy', 'preBuild', 'postBuild', 'dataMigrations')
    $hookComments = @{
        'preExport'      = '# Called by `pipelines/scripts/export.ps1` before exporting solutions.'
        'postExport'     = '# Called by `pipelines/scripts/export.ps1` after exporting/unpacking/version bump logic.'
        'preDeploy'      = '# Called by `pipelines/scripts/deploy.ps1` before staging/importing solutions.'
        'postDeploy'     = '# Called by `pipelines/scripts/deploy.ps1` after publish customizations.'
        'preBuild'       = '# Called by `pipelines/scripts/build.ps1` before packing solutions.'
        'postBuild'      = '# Called by `pipelines/scripts/build.ps1` after packing solutions/copying assets.'
        'dataMigrations' = '# Called by `pipelines/scripts/deploy.ps1` after solutions are staged but before upgrades.
        # Use this for data migration scripts (e.g., moving data from one column to another before they disappear).'
    }
    
    foreach ($hookName in $hookNames) {
        [void]$sb.AppendLine("        $($hookComments[$hookName])")
        
        $padding = ' ' * (15 - $hookName.Length)
        [void]$sb.Append("        $hookName$padding = @(")
        
        if ($Hooks.ContainsKey($hookName) -and $Hooks[$hookName] -and $Hooks[$hookName].Count -gt 0) {
            [void]$sb.AppendLine()
            foreach ($script in $Hooks[$hookName]) {
                [void]$sb.AppendLine("            '$script'")
            }
            [void]$sb.Append('        ')
        }
        
        [void]$sb.AppendLine(')')
        
        if ($hookName -ne 'dataMigrations') {
            [void]$sb.AppendLine()
        }
    }
    
    [void]$sb.Append('    ')
    return $sb.ToString()
}

function Build-ScriptDependenciesSection {
    param([hashtable]$ScriptDependencies)
    
    if (-not $ScriptDependencies -or $ScriptDependencies.Count -eq 0) {
        return "`n"
    }
    
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine()
    
    foreach ($key in $ScriptDependencies.Keys) {
        [void]$sb.AppendLine("        '$key' = '$($ScriptDependencies[$key])'")
    }
    
    [void]$sb.Append('    ')
    return $sb.ToString()
}

function Build-LegacySection {
    param(
        [hashtable]$Config,
        [array]$UnsupportedOptions
    )
    
    $sb = New-Object System.Text.StringBuilder
    
    # Write other migrated keys
    $otherKeys = $Config.Keys | Where-Object { $_ -notin @('solutions', 'assets', 'hooks', 'scriptDependencies') }
    
    if ($otherKeys.Count -gt 0) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('    # Legacy configuration keys (migrated from almconfig.ps1)')
        [void]$sb.AppendLine('    # These may not be used by the new ALM framework')
        [void]$sb.AppendLine()
        
        foreach ($key in $otherKeys) {
            $value = $Config[$key]
            $valueString = ConvertTo-PowerShellLiteral -Value $value -IndentLevel 1
            [void]$sb.AppendLine("    $key = $valueString")
            [void]$sb.AppendLine()
        }
    }
    
    # Add unsupported options as comments
    if ($UnsupportedOptions -and $UnsupportedOptions.Count -gt 0) {
        [void]$sb.AppendLine('    # Unsupported options from original configuration (for reference only)')
        [void]$sb.AppendLine('    # The following options were present in the original almconfig.ps1 but are not')
        [void]$sb.AppendLine('    # currently supported in the new alm-config.psd1 format:')
        [void]$sb.AppendLine('    <#')
        foreach ($option in $UnsupportedOptions) {
            [void]$sb.AppendLine("    # Solution: $($option.Solution)")
            [void]$sb.AppendLine("    # Option: $($option.Option)")
            [void]$sb.AppendLine("    # Value: $($option.Value)")
            [void]$sb.AppendLine("    # Note: $($option.Comment)")
            [void]$sb.AppendLine("    #")
        }
        [void]$sb.AppendLine('    #>')
    }
    
    return $sb.ToString()
}

function ConvertTo-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        $Value,
        
        [Parameter(Mandatory = $false)]
        [int]$IndentLevel = 0
    )
    
    $indent = '    ' * $IndentLevel
    $nextIndent = '    ' * ($IndentLevel + 1)
    
    if ($null -eq $Value) {
        return '$null'
    }
    elseif ($Value -is [bool]) {
        if ($Value) { return '$true' } else { return '$false' }
    }
    elseif ($Value -is [string]) {
        # Escape single quotes
        $escaped = $Value -replace "'", "''"
        return "'$escaped'"
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }
    elseif ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return '@()'
        }
            
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('@(')
            
        foreach ($item in $Value) {
            $itemLiteral = ConvertTo-PowerShellLiteral -Value $item -IndentLevel ($IndentLevel + 1)
            [void]$sb.AppendLine("$nextIndent$itemLiteral")
        }
            
        [void]$sb.Append("$indent)")
        return $sb.ToString()
    }
    elseif ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Value.Count -eq 0) {
            return '@{}'
        }
            
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('@{')
            
        foreach ($key in $Value.Keys) {
            if ($key -is [string]) {
                $keyLiteral = "'$($key -replace "'", "''")'"
            } else {
                $keyLiteral = $key.ToString()
            }
            $valueLiteral = ConvertTo-PowerShellLiteral -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
                    
                # Handle multi-line values
                if ($valueLiteral -like "*`n*") {
                    $valueLiteral = $valueLiteral.TrimEnd()
                    [void]$sb.AppendLine("$nextIndent$keyLiteral = $valueLiteral")
                }
                else {
                    [void]$sb.AppendLine("$nextIndent$keyLiteral = $valueLiteral")
                }
        }
            
        [void]$sb.Append("$indent}")
        return $sb.ToString()
    }
    elseif ($Value -is [PSCustomObject]) {
        # Convert PSCustomObject to hashtable
        $ht = @{}
        $Value.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
        return ConvertTo-PowerShellLiteral -Value $ht -IndentLevel $IndentLevel
    }
    elseif ($Value -is [scriptblock]) {
        return "{ $($Value.ToString()) }"
    }
    else {
        # Fallback to string representation
        $strValue = $Value.ToString() -replace "'", "''"
        return "'$strValue'"
    }
}

#==============================================================================
# Main Migration Function
#==============================================================================

function Invoke-ConfigMigration {
    <#
    .SYNOPSIS
        Migrates almconfig.ps1 to alm-config.psd1 format.
    
    .PARAMETER WorkspacePath
        Path to the repository workspace root.
    
    .PARAMETER TemplateDirectory
        Path to the directory containing the alm-config.psd1 template.
    
    .PARAMETER AlmConfigPath
        Path to the almconfig.ps1 file (if null, migration is skipped).
    
    .PARAMETER OutputPath
        Path where the new alm-config.psd1 should be written.
    
    .OUTPUTS
        Returns a hashtable with migration results including warnings and whether migration occurred.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'WorkspacePath', Justification = 'Retained in the exported migration API for caller compatibility; path resolution is handled by the explicit path parameters.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        
        [Parameter(Mandatory = $true)]
        [string]$TemplateDirectory,
        
        [Parameter(Mandatory = $false)]
        [string]$AlmConfigPath,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )
    
    $result = @{
        Migrated = $false
        Warnings = @()
        AlreadyMigrated = $false
    }
    
    # Check if migration already completed
    $AlmConfigMigratedPath = "$AlmConfigPath.migrated"
    
    if (-not $AlmConfigPath -or -not (Test-Path $AlmConfigPath)) {
        if (Test-Path $AlmConfigMigratedPath) {
            Write-Host "almconfig.ps1 has already been migrated (found $AlmConfigMigratedPath)" -ForegroundColor Green
            Write-Host "Skipping configuration migration" -ForegroundColor Yellow
            $result.AlreadyMigrated = $true
            return $result
        }
        else {
            throw "almconfig.ps1 not found at: $AlmConfigPath"
        }
    }
    
    $templatePath = Join-Path $TemplateDirectory 'alm-config.psd1'
    
    if (-not (Test-Path $templatePath)) {
        throw "Template file not found at: $templatePath"
    }
    
    Write-Host "Loading old configuration..." -ForegroundColor Yellow
    $oldConfig = & $AlmConfigPath

    if (-not $oldConfig) {
        throw "Failed to load configuration from $AlmConfigPath"
    }

    # Load or create new configuration based on template
    if (Test-Path $OutputPath) {
        Write-Host "Loading existing alm-config.psd1..." -ForegroundColor Yellow
        $newConfig = Import-PowerShellDataFile -Path $OutputPath
    }
    else {
        Write-Host "Creating new alm-config.psd1 from template..." -ForegroundColor Yellow
        $newConfig = Import-PowerShellDataFile -Path $templatePath
    }

    # Track unsupported options
    $unsupportedOptions = @()

    # Migrate Solutions and SolutionOptions
    Write-Host "Migrating solutions..." -ForegroundColor Yellow
    if ($oldConfig.Solutions) {
        $migratedSolutions = @()
    
        foreach ($solutionName in $oldConfig.Solutions) {
            $solutionEntry = @{
                name = $solutionName
            }
        
            # Check for solution-specific options
            if ($oldConfig.SolutionOptions -and $oldConfig.SolutionOptions.ContainsKey($solutionName)) {
                $options = $oldConfig.SolutionOptions[$solutionName]
            
                # Map DeployUnmanaged
                if ($options.ContainsKey('DeployUnmanaged')) {
                    $solutionEntry.deployUnmanaged = $options.DeployUnmanaged
                }
            
                # Check for unsupported options
                foreach ($key in $options.Keys) {
                    if ($key -eq 'SkipDeployment') {
                        $unsupportedOptions += @{
                            Solution = $solutionName
                            Option   = $key
                            Value    = $options[$key]
                            Comment  = "SkipDeployment is not currently supported in alm-config.psd1"
                        }
                        $result.Warnings += "Solution '$solutionName': SkipDeployment option is not currently supported and will be ignored"
                    }
                    elseif ($key -eq 'NoOverwriteUnmanagedCustomisations') {
                        $unsupportedOptions += @{
                            Solution = $solutionName
                            Option   = $key
                            Value    = $options[$key]
                            Comment  = "NoOverwriteUnmanagedCustomisations is not currently supported in alm-config.psd1"
                        }
                        $result.Warnings += "Solution '$solutionName': NoOverwriteUnmanagedCustomisations option is not currently supported and will be ignored"
                    }
                    elseif ($key -ne 'DeployUnmanaged') {
                        $unsupportedOptions += @{
                            Solution = $solutionName
                            Option   = $key
                            Value    = $options[$key]
                            Comment  = "This option is not currently supported in alm-config.psd1"
                        }
                        $result.Warnings += "Solution '$solutionName': Option '$key' is not currently supported and will be ignored"
                    }
                }
            }
        
            $migratedSolutions += $solutionEntry
        }
    
        $newConfig['solutions'] = $migratedSolutions
    }

    # Migrate hook scripts
    Write-Host "Migrating hook scripts..." -ForegroundColor Yellow

    # Ensure hooks hashtable exists
    if (-not $newConfig.ContainsKey('hooks')) {
        $newConfig['hooks'] = @{}
    }

    if ($oldConfig.PostExportScript -and $oldConfig.PostExportScript -ne '') {
        if (-not $newConfig['hooks'].ContainsKey('postExport')) {
            $newConfig['hooks']['postExport'] = @()
        }
        if ($newConfig['hooks']['postExport'] -notcontains $oldConfig.PostExportScript) {
            $newConfig['hooks']['postExport'] += $oldConfig.PostExportScript
        }
    }

    if ($oldConfig.PreDeployScript -and $oldConfig.PreDeployScript -ne '') {
        if (-not $newConfig['hooks'].ContainsKey('preDeploy')) {
            $newConfig['hooks']['preDeploy'] = @()
        }
        if ($newConfig['hooks']['preDeploy'] -notcontains $oldConfig.PreDeployScript) {
            $newConfig['hooks']['preDeploy'] += $oldConfig.PreDeployScript
        }
    }

    if ($oldConfig.PostDeployScript -and $oldConfig.PostDeployScript -ne '') {
        if (-not $newConfig['hooks'].ContainsKey('postDeploy')) {
            $newConfig['hooks']['postDeploy'] = @()
        }
        if ($newConfig['hooks']['postDeploy'] -notcontains $oldConfig.PostDeployScript) {
            $newConfig['hooks']['postDeploy'] += $oldConfig.PostDeployScript
        }
    }

    if ($oldConfig.PostBuildScript -and $oldConfig.PostBuildScript -ne '') {
        if (-not $newConfig['hooks'].ContainsKey('postBuild')) {
            $newConfig['hooks']['postBuild'] = @()
        }
        if ($newConfig['hooks']['postBuild'] -notcontains $oldConfig.PostBuildScript) {
            $newConfig['hooks']['postBuild'] += $oldConfig.PostBuildScript
        }
    }

    # Migrate other top-level keys (preserve keys not handled by migration)
    Write-Host "Migrating other configuration values..." -ForegroundColor Yellow

    $keysToSkip = @('Solutions', 'SolutionOptions', 'PostExportScript', 'PreDeployScript', 'PostDeployScript', 'PostBuildScript')
    $keysHandledByNewFormat = @('solutions', 'assets', 'hooks', 'scriptDependencies')

    foreach ($key in $oldConfig.Keys) {
        if ($keysToSkip -notcontains $key -and $keysHandledByNewFormat -notcontains $key) {
            $newConfig[$key] = $oldConfig[$key]
            Write-Host "  Copied: $key" -ForegroundColor Gray
        }
    }

    # Generate the new configuration file content
    Write-Host "Generating new configuration file..." -ForegroundColor Yellow

    # Start with the template and customize it
    $templateContent = Get-Content -Path $templatePath -Raw

    # Build customized sections
    $solutionsSection = Build-SolutionsSection -Solutions $newConfig['solutions']
    $assetsSection = Build-AssetsSection -Assets $newConfig['assets']
    $hooksSection = Build-HooksSection -Hooks $newConfig['hooks']
    $scriptDependenciesSection = Build-ScriptDependenciesSection -ScriptDependencies $newConfig['scriptDependencies']
    $legacySection = Build-LegacySection -Config $newConfig -UnsupportedOptions $unsupportedOptions

    # Replace the template sections with customized content
    $output = $templateContent

    # Replace solutions section
    $output = $output -replace '(?s)(solutions = @\()[^)]*(\))', "`$1$solutionsSection`$2"

    # Replace assets section
    $output = $output -replace '(?s)(assets = @\()[^)]*(\))', "`$1$assetsSection`$2"

    # Replace hooks section
    $output = $output -replace '(?s)(hooks = @\{)[^}]*(    \})', "`$1$hooksSection`$2"

    # Replace scriptDependencies section
    $output = $output -replace '(?s)(scriptDependencies = @\{)[^}]*(\})', "`$1$scriptDependenciesSection`$2"

    # Add legacy section before the closing brace
    if ($legacySection) {
        $output = $output -replace '(\r?\n)(\})$', "`$1$legacySection`$1`$2"
    }

    # Write the output file
    Write-Host "Writing new configuration to: $OutputPath" -ForegroundColor Yellow
    $output | Out-File -FilePath $OutputPath -Encoding UTF8

    Write-Host "Successfully created alm-config.psd1" -ForegroundColor Green

    # Display warnings
    if ($result.Warnings.Count -gt 0) {
        Write-Host ""
        Write-Warning "The following options are not currently supported and have been documented in comments:"
        foreach ($warning in $result.Warnings) {
            Write-Warning "  $warning"
        }
    }

    # Rename original almconfig file
    Write-Host ""
    Write-Host "Renaming almconfig.ps1 to: $AlmConfigMigratedPath" -ForegroundColor Yellow
    Rename-Item -Path $AlmConfigPath -NewName "$AlmConfigPath.migrated" -Force
    
    $result.Migrated = $true
    return $result
}

#==============================================================================
# Workflow Migration Function
#==============================================================================

function Invoke-WorkflowMigration {
    <#
    .SYNOPSIS
        Migrates legacy fork GitHub workflow files to the upstream composite-action model.
    
    .DESCRIPTION
        Replaces legacy fork workflow stubs with the current workflow templates from
        copy-to-your-repo/.github/workflows.

        Existing workflow files are backed up with a .migrated suffix before replacement.
        The generated DEPLOY-main.yml is a starter template and may need environment-specific
        adjustments after migration.
    
    .PARAMETER WorkspacePath
        Path to the repository workspace root.
    
    .PARAMETER TemplateDirectory
        Path to the repository template root containing .github/workflows templates.

    .OUTPUTS
        Returns a hashtable with migration results including files migrated and warnings.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,

        [Parameter(Mandatory = $true)]
        [string]$TemplateDirectory
    )
    
    $result = @{
        FilesMigrated = @()
        Warnings = @()
        AlreadyMigrated = $true
    }
    
    $workflowsPath = Join-Path $WorkspacePath '.github' 'workflows'
    $templateWorkflowsPath = Join-Path $TemplateDirectory '.github' 'workflows'

    if (-not (Test-Path $templateWorkflowsPath)) {
        throw "Template workflows directory not found: $templateWorkflowsPath"
    }
    
    if (-not (Test-Path $workflowsPath)) {
        Write-Host ""
        Write-Host "No .github/workflows directory found - skipping workflow migration" -ForegroundColor Gray
        return $result
    }
    
    Write-Host "`nMigrating GitHub workflow files..." -ForegroundColor Cyan
    Write-Host "Workflows directory: $workflowsPath" -ForegroundColor Gray
    Write-Host ""

    $templateFiles = @('BUILD.yml', 'EXPORT.yml', 'IMPORT.yml', 'DEPLOY-main.yml')
    $legacyFiles = @('BUILD.yml', 'EXPORT.yml', 'IMPORT.yml', 'DEPLOY.yml', 'DEPLOY-main.yml')

    foreach ($fileName in $legacyFiles) {
        $existingPath = Join-Path $workflowsPath $fileName
        if (Test-Path $existingPath) {
            $backupPath = "$existingPath.migrated"
            Copy-Item -Path $existingPath -Destination $backupPath -Force
            Write-Host "  Backed up: $fileName -> $($fileName).migrated" -ForegroundColor Gray
        }
    }

    foreach ($fileName in $templateFiles) {
        $sourcePath = Join-Path $templateWorkflowsPath $fileName
        $destinationPath = Join-Path $workflowsPath $fileName

        if (-not (Test-Path $sourcePath)) {
            $result.Warnings += "Template workflow not found: $sourcePath"
            continue
        }

        Copy-Item -Path $sourcePath -Destination $destinationPath -Force
        $result.FilesMigrated += $fileName
        $result.AlreadyMigrated = $false

        Write-Host "  ✓ Replaced: $fileName" -ForegroundColor Green
    }

    $oldDeployPath = Join-Path $workflowsPath 'DEPLOY.yml'
    if ((Test-Path $oldDeployPath) -and -not (Test-Path "$oldDeployPath.migrated")) {
        $result.Warnings += 'Legacy DEPLOY.yml could not be backed up as expected.'
    }

    $result.Warnings += 'Review DEPLOY-main.yml and replace the example TEST-main/PROD stages with your real deployment environments.'
    
    return $result
}

Export-ModuleMember -Function @(
    'Build-SolutionsSection',
    'Build-AssetsSection',
    'Build-HooksSection',
    'Build-ScriptDependenciesSection',
    'Build-LegacySection',
    'ConvertTo-PowerShellLiteral',
    'Invoke-ConfigMigration',
    'Invoke-WorkflowMigration'
)
