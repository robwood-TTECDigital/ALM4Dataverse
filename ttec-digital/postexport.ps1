param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$config = $context.Config
$SourceDirectory = $context.SourceDirectory

& $PSScriptRoot/common/load-dataverse-sdk.ps1
Import-Module $PSScriptRoot/common/alm.psm1

if (-not (test-path data) ) {
    new-item data -ItemType Directory
}

# DATA

function exportDataset($datasetname) {
    write-host "Exporting data set '$datasetname'"
    $tempdatafile = "$($context.TempDirectory)/data-$datasetname.zip"
    pac data export --schemafile (resolve-path data/$datasetname/schema.xml) --overwrite --datafile $tempdatafile
    if (-not $? -or $LASTEXITCODE -ne 0) { throw "pac data export failed"; }
    if (test-path data/$datasetname/data) {
        remove-item -recurse -force data/$datasetname/data
    }
    new-item -type Directory data/$datasetname/data
    expand-archive -path $tempdatafile data/$datasetname/data
}

if ($config.ContainsKey("DataSets")) {
    if ($config.DataSets -is [hashtable]) {
        $config.DataSets.Keys | foreach-object { 
            exportDataset -datasetname $_

        }
    }
    else {
        foreach ($datasetname in $config.DataSets) {
            exportDataset -datasetname $datasetname
        }
    }
}

git add -A data/
if (-not $? -or $LASTEXITCODE -ne 0) { throw "git add failed"; }

# PORTALS

if (-not (test-path portals) ) {
    new-item portals -ItemType Directory
}

if ($config.ContainsKey("Portals")) {
    if (-not (test-path portals/cfg) ) {
        new-item portals/cfg -ItemType Directory
    }

    foreach ($portalname in $config.Portals.Keys) {
   
        $tempfolder = "$($context.TempDirectory)/portal-$portalname"
        new-item -type Directory $tempfolder

        pac paportal download --overwrite --path "$tempfolder" --webSiteId ($config.Portals[$portalname])
        if (-not $? -or $LASTEXITCODE -ne 0) { throw "pac paportal export failed"; }

        $portalcfgpath = "portals/$portalname/cfg"
        if (test-path $portalcfgpath ) {
            remove-item -force -recurse $portalcfgpath
        }

        new-item -type Directory $portalcfgpath

        copy-item -recurse $tempfolder/*/* $portalcfgpath -exclude .portalconfig

        $profiletemplatepath = "portals/$portalname/deployment-profile-template.yml"
        if (-not (test-path $profiletemplatepath)) {
            (
                "# See https://learn.microsoft.com/en-us/power-pages/configure/power-platform-cli#use-deployment-profile",
                "# Put `$(Placeholders) in where an environment specific value should be used."
            ) | out-file $profiletemplatepath
        }
    }
}

git add -A portals/
if (-not $? -or $LASTEXITCODE -ne 0) { throw "git add failed"; }

if ($config.Contains("PostExportScript") -and $config.PostExportScript) {
    & "./$($config.PostExportScript)"
}


synapse_export -config $config


$validdependencysolutionnames = @()
if ($config.ContainsKey("ExternalDependencySolutionNames")) {
    $validdependencysolutionnames += @($config['ExternalDependencySolutionNames'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
if ($config.ContainsKey("DependencySolutions")) {
    $validdependencysolutionnames += @($config['DependencySolutions'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
$ignoresolutionnames = @()
if ($config.ContainsKey("IgnoreSolutions")) {
    $ignoresolutionnames = @($config['IgnoreSolutions'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
$validationSettings = Get-AlmValidationSettings -Config $config

foreach ($solutionconfig in $config.solutions) {

    $laterSolutionNames = @()
    $foundCurrentSolution = $false
    foreach ($configuredSolution in $config.solutions) {
        if ($foundCurrentSolution) {
            $laterSolutionNames += $configuredSolution.name
        } elseif ($configuredSolution.name -eq $solutionconfig.name) {
            $foundCurrentSolution = $true
        }
    }

    Write-Host "[$($solutionconfig.name)][Validate] Reporting validation"

    $validationParameters = @{ ValidationSettings = $validationSettings }
    if ($context.ContainsKey('ExportOperationBudget') -and $context['ExportOperationBudget'] -is [System.Threading.SemaphoreSlim]) {
        $validationParameters.OperationBudget = $context['ExportOperationBudget']
    }
    if ($context.ContainsKey('ExportCancellationToken') -and $context['ExportCancellationToken'] -is [System.Threading.CancellationToken]) {
        $validationParameters.CancellationToken = $context['ExportCancellationToken']
    }
    if ($context.ContainsKey('ExportValidationSummaries') -and $context['ExportValidationSummaries'] -is [hashtable]) {
        $validationParameters.SummaryStore = $context['ExportValidationSummaries']
    }
    if ($context.ContainsKey('ArtifactStagingDirectory') -and $context['ArtifactStagingDirectory']) {
        $validationParameters.LogDirectory = Join-Path $context['ArtifactStagingDirectory'] "export-logs/$($solutionconfig.name)"
    }
    $precomputedResults = $null
    if ($context.ContainsKey('ParallelExportSolutionHookResults') -and $context['ParallelExportSolutionHookResults'] -is [hashtable] -and $context['ParallelExportSolutionHookResults'].ContainsKey($solutionconfig.name) -and $null -ne $context['ParallelExportSolutionHookResults'][$solutionconfig.name]) {
        $precomputedResults = $context['ParallelExportSolutionHookResults'][$solutionconfig.name]
    } elseif ($context.ContainsKey('SolutionHookResults') -and $context['SolutionHookResults'] -is [hashtable] -and $context['SolutionHookResults'].ContainsKey($solutionconfig.name) -and $null -ne $context['SolutionHookResults'][$solutionconfig.name]) {
        $precomputedResults = $context['SolutionHookResults'][$solutionconfig.name]
    } elseif ($context.ContainsKey('ExportValidationResults') -and $context['ExportValidationResults'] -is [hashtable] -and $context['ExportValidationResults'].ContainsKey($solutionconfig.name) -and $null -ne $context['ExportValidationResults'][$solutionconfig.name]) {
        $precomputedResults = $context['ExportValidationResults'][$solutionconfig.name]
    }
    if ($null -ne $precomputedResults) {
        $validationParameters.PrecomputedResults = @($precomputedResults)
    }
    validateSolution `
        -solutionname $solutionconfig.name `
        -validdependencysolutionnames $validdependencysolutionnames `
        -ignoresolutionnames $ignoresolutionnames `
        -solutionconfig $solutionconfig @validationParameters `
        -LaterSolutionNames $laterSolutionNames

    $validdependencysolutionnames += $solutionconfig.name
}
