<#
.SYNOPSIS
    Exports Dataverse solutions from a specified environment and unpacks them into the source directory.
.DESCRIPTION
    This script exports the Dataverse solutions defined in alm-config.psd1 from the connected
    Dataverse environment. It exports both managed and unmanaged versions of each solution
    and saves them to the specified artifact staging directory.

    After exporting, it unpacks each solution into the source directory's solution folders.
    If any changes are detected in the unpacked solutions compared to the existing source,
    it increments the solution version in both the source and the environment.

    Hooks defined in alm-config.psd1 are invoked at various stages of the export process
    to allow for custom pre- and post-export actions.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory,
    
    [Parameter(Mandatory=$true)]
    [string]$ArtifactStagingDirectory,

    [string]$TempDirectory = "([IO.Path]::GetTempPath())\$([IO.Path]::GetTempFileName())",
    
    [Parameter(Mandatory=$false)]
    [string]$EnvironmentName = "Unknown",

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'parallel-export.ps1')

$exportClock = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "##[section]Exporting Solutions from $EnvironmentName"

# Read solutions configuration
$solutionsConfig = Get-AlmConfig -BaseDirectory $SourceDirectory -LogConfig:$false
$exportSettings = Get-AlmExportSettings -Config $solutionsConfig

Invoke-Hooks -HookType "preExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -LogContext:$false -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
}

$exportPipeline = $null
$exportValidationResults = @{}
$exportValidationSummaries = @{}
$exportLogDirectory = Join-Path $ArtifactStagingDirectory 'export-logs'
$exportStatus = 'Failed'
$exportOperationBudget = $null
$exportCancellationToken = [System.Threading.CancellationToken]::None
$validDependencyNames = @()
foreach ($key in @('ExternalDependencySolutionNames', 'DependencySolutions')) {
    if ($solutionsConfig.ContainsKey($key)) {
        $validDependencyNames += @($solutionsConfig[$key] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}
try {
if ($exportSettings.parallel) {
    $exportPipeline = Start-AlmExportPipeline -Config $solutionsConfig -TempDirectory $TempDirectory -MaxParallel $exportSettings.maxParallel
    $exportPipeline.LogDirectory = $exportLogDirectory
    $exportOperationBudget = $exportPipeline.OperationBudget
    $exportCancellationToken = $exportPipeline.Cancellation.Token
    Start-AlmQueuedExports -State $exportPipeline
} else {
    $exportOperationBudget = [System.Threading.SemaphoreSlim]::new($exportSettings.maxConcurrentOperations, $exportSettings.maxConcurrentOperations)
}
foreach ($solution in $solutionsConfig.solutions) {
    $solutionName = $solution.name
    $exportZipPath = $null
    if ($null -ne $exportPipeline) {
        $exportZipPath = Wait-AlmSolutionExports -State $exportPipeline -SolutionName $solutionName
    }
    
    Write-Host "[$solutionName][Unpack] Started (managed and unmanaged)"
    
    if (-not (Test-Path "$SourceDirectory/solutions")) {
        New-Item -ItemType Directory -Path "$SourceDirectory/solutions" | Out-Null
    } 

    if ((Test-Path $SourceDirectory/solutions/$solutionName)) {
        Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.old.zip" -Path "$SourceDirectory/solutions/$solutionName"
        Remove-Item -Recurse -Force "$SourceDirectory/solutions/$solutionName"
    }

    if ($null -ne $exportPipeline) {
        & { $ProgressPreference = 'SilentlyContinue'; Expand-AlmExportSolution -ZipPath $exportZipPath -OutputPath "$SourceDirectory/solutions/$solutionName" } *>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase Unpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
    } else {
        & { $ProgressPreference = 'SilentlyContinue'; Export-DataverseSolution -Verbose -SolutionName $solutionName -OutFolder "$SourceDirectory/solutions/$solutionName" -UnpackMsApp } *>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }; Format-AlmLogLine -SolutionName $solutionName -Phase ExportUnpack -Text ([string]$_) | ForEach-Object { Write-Host $_ } }
    }
    
    Write-Host "[$solutionName][Unpack] Completed"
   
    Write-Host "[$solutionName][Compare] Checking for changes"

    # This ensures that when we compare, the file is normalized compared to what we will generate
    # Indentation etc is different in the initial export.
    $solutionXmlPath = "$SourceDirectory/solutions/$solutionName/Other/Solution.xml"
    [xml]$solutionXml = Get-Content -Path $solutionXmlPath
    $solutionXml.Save($solutionXmlPath)

    # Test if anything changed and increment version if so
    $gitStatus = git -C "$SourceDirectory" status --porcelain solutions/$solutionName
    if ([string]::IsNullOrEmpty($gitStatus)) {
        Write-Host "##[debug][$solutionName][Compare] No changes"
    } else {
        Format-AlmLogLine -SolutionName $solutionName -Phase Compare -Text "##[debug]Changes detected`n$gitStatus" | ForEach-Object { Write-Host $_ }

        if ((Test-Path "$TempDirectory/$solutionName-managed.old.zip")) {       
            Compress-DataverseSolutionFile -PackageType Managed -OutputPath "$TempDirectory/$solutionName-managed.new.zip" -Path "$SourceDirectory/solutions/$solutionName"

            $changesareadditive = (Compare-DataverseSolutionComponents -FileToFile -SolutionFile "$TempDirectory/$solutionName-managed.new.zip" -TargetSolutionFile "$TempDirectory/$solutionName-managed.old.zip" -TestIfAdditive -Verbose)
            if ($changesareadditive) {
                Write-Host "##[debug][$solutionName][Compare] Changes are additive only."
            } else {
                Write-Host "##[debug][$solutionName][Compare] Changes include non-additive changes."
            }

            Remove-Item -Path "$TempDirectory/$solutionName-managed.old.zip","$TempDirectory/$solutionName-managed.new.zip"
        } else {
            $changesareadditive = $true
        }

        $solutionXmlPath = "$SourceDirectory/solutions/$solutionName/Other/Solution.xml"
        [xml]$solutionXml = Get-Content -Path $solutionXmlPath
        $currentVersion = [version] $solutionXml.ImportExportXml.SolutionManifest.Version

        if ($changesareadditive) {
            $newversion = [version] "$($currentVersion.Major).$($currentVersion.Minor).$([Math]::Max(0, $currentVersion.Build)).$([Math]::Max(0, $currentVersion.Revision) + 1)"
        } else {
            $newversion = [version] "$($currentVersion.Major).$([Math]::Max(0, $currentVersion.Minor)+1).0.0"

        }
        $solutionXml.ImportExportXml.SolutionManifest.Version = $newversion.ToString()
        $solutionXml.Save($solutionXmlPath)

        Write-Host "##[debug][$solutionName][Version] Updated solution folder to $newversion"

        if ($null -ne $exportPipeline) {
            $exportPipeline.OperationBudget.Wait($exportPipeline.Cancellation.Token)
            try { Set-DataverseSolution -UniqueName $solutionName -Version $newversion.ToString() }
            finally { $exportPipeline.OperationBudget.Release() | Out-Null }
        } else { Set-DataverseSolution -UniqueName $solutionName -Version $newversion.ToString() }
        Write-Host "##[debug][$solutionName][Version] Updated environment to $newversion"
    }

 
    
    Write-Host "[$solutionName][Compare] Completed"
    if ($null -ne $exportPipeline) {
        Add-AlmExportValidation -State $exportPipeline -Config $solutionsConfig -Solution $solution -Dependencies $validDependencyNames
    }
    $validDependencyNames += $solutionName
}

if ($null -ne $exportPipeline) {
    Complete-AlmExportValidation -State $exportPipeline
    $exportValidationResults = $exportPipeline.ValidationResults
}
Invoke-Hooks -HookType "postExport" -BaseDirectory $SourceDirectory -Config $solutionsConfig -LogContext:$false -AdditionalContext @{
    SourceDirectory = $SourceDirectory
    ArtifactStagingDirectory = $ArtifactStagingDirectory
    TempDirectory = $TempDirectory
    EnvironmentName = $EnvironmentName
    ExportValidationResults = $exportValidationResults
    ExportValidationSummaries = $exportValidationSummaries
    ExportOperationBudget = $exportOperationBudget
    ExportCancellationToken = $exportCancellationToken
}
$exportStatus = 'Succeeded'
} finally {
    if ($null -ne $exportPipeline) { Stop-AlmExportPipeline -State $exportPipeline }
    elseif ($null -ne $exportOperationBudget) { $exportOperationBudget.Dispose() }
    New-Item -ItemType Directory -Path $exportLogDirectory -Force | Out-Null
    $summary = @(foreach ($solution in $solutionsConfig.solutions) {
        $name = $solution.name
        $timings = @()
        if ($null -ne $exportPipeline) { $timings = @($exportPipeline.Timings | Where-Object SolutionName -eq $name) }
        $validation = $exportValidationSummaries[$name]
        $validationTiming = @($timings | Where-Object Kind -eq 'Validation')
        $exportTimings = @($timings | Where-Object Kind -eq 'Export')
        $row = [pscustomobject]@{
            Solution = $name
            RunStatus = $exportStatus
            PackagesCompleted = $(if ($null -ne $exportPipeline) { $exportTimings.Count } else { $null })
            ExportSpanSeconds = $(if ($exportTimings.Count) { (($exportTimings.Finished | Sort-Object | Select-Object -Last 1) - ($exportTimings.Started | Sort-Object | Select-Object -First 1)).TotalSeconds } else { $null })
            Validation = $(if ($null -ne $validation) { $validation.Status } else { 'NotReported' })
            Errors = $(if ($null -ne $validation) { $validation.Errors } else { $null })
            Warnings = $(if ($null -ne $validation) { $validation.Warnings } else { $null })
            ValidationSeconds = $(if ($validationTiming.Count) { ($validationTiming[0].Finished-$validationTiming[0].Started).TotalSeconds } elseif ($null -ne $validation) { $validation.Seconds } else { $null })
        }
        Write-Host "[$name][Summary] Run=$exportStatus; validation=$($row.Validation); errors=$($row.Errors); warnings=$($row.Warnings); export span=$($row.ExportSpanSeconds)s; validation=$($row.ValidationSeconds)s"
        $row
    })
    ConvertTo-Json -InputObject $summary -Depth 8 | Set-Content -LiteralPath (Join-Path $exportLogDirectory 'summary.json') -Encoding utf8
    if ($null -ne $exportPipeline) {
        ConvertTo-Json -InputObject $exportPipeline.Timings.ToArray() -Depth 8 | Set-Content -LiteralPath (Join-Path $exportLogDirectory 'timings.json') -Encoding utf8
    }
    if ($env:TF_BUILD) { Write-Host "##vso[artifact.upload containerfolder=export-logs;artifactname=export-logs]$exportLogDirectory" }
    Write-Host "[Export][Summary] Detailed logs: $exportLogDirectory"
}

Write-Host "##[section]Export completed successfully!"
$exportClock.Stop()
if ($PassThru) {
    $workerTimings = @()
    if ($null -ne $exportPipeline) { $workerTimings = $exportPipeline.Timings.ToArray() }
    [pscustomobject]@{
        Parallel = $exportSettings.parallel
        TotalSeconds = $exportClock.Elapsed.TotalSeconds
        WorkerTimings = $workerTimings
    }
}
