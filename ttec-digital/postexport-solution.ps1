param($context)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if ($context -isnot [hashtable]) {
    throw 'The postExportSolution validation hook requires a hashtable context.'
}
if (-not $context.ContainsKey('SolutionName') -or -not $context['SolutionName']) {
    throw 'The postExportSolution validation hook requires SolutionName.'
}
if (-not $context.ContainsKey('SolutionConfig') -or $context['SolutionConfig'] -isnot [hashtable]) {
    throw 'The postExportSolution validation hook requires SolutionConfig.'
}
if (-not $context.ContainsKey('SolutionIndex')) {
    throw 'The postExportSolution validation hook requires SolutionIndex.'
}
if (-not $context.ContainsKey('Config') -or $context['Config'] -isnot [hashtable]) {
    throw 'The postExportSolution validation hook requires Config.'
}

. (Join-Path $PSScriptRoot 'common/solutionvalidation.ps1')

$solutionName = [string]$context['SolutionName']
$solutionConfig = $context['SolutionConfig']
$config = $context['Config']
$solutionIndex = [int]$context['SolutionIndex']
$solutions = @($config.solutions)

if ($solutionIndex -lt 0 -or $solutionIndex -ge $solutions.Count -or $solutions[$solutionIndex].name -ne $solutionName) {
    throw "Solution '$solutionName' does not match configuration index $solutionIndex."
}

$validationMode = 'error'
if ($solutionConfig.ContainsKey('validationMode') -and $solutionConfig.validationMode) {
    $validationMode = $solutionConfig.validationMode.ToLowerInvariant()
}
if ($validationMode -eq 'disabled') {
    return @()
}

$validDependencySolutionNames = @()
foreach ($configKey in @('ExternalDependencySolutionNames', 'DependencySolutions')) {
    if ($config.ContainsKey($configKey)) {
        $validDependencySolutionNames += @($config[$configKey] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}
for ($index = 0; $index -lt $solutionIndex; $index++) {
    $validDependencySolutionNames += $solutions[$index].name
}

$laterSolutionNames = @()
for ($index = $solutionIndex + 1; $index -lt $solutions.Count; $index++) {
    $laterSolutionNames += $solutions[$index].name
}

$ignoreSolutionNames = @()
if ($config.ContainsKey('IgnoreSolutions')) {
    $ignoreSolutionNames = @($config['IgnoreSolutions'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

$settings = Get-AlmValidationSettings -Config $config
$ruleTimings = [System.Collections.Generic.List[object]]::new()
$validationParameters = @{
    solutionname = $solutionName
    solutionconfig = $solutionConfig
    validdependencysolutionnames = @($validDependencySolutionNames)
    ignoresolutionnames = @($ignoreSolutionNames)
    validationMode = $validationMode
    ParallelRules = $settings.parallel
    MaxParallel = $settings.maxParallel
    RuleTimings = $ruleTimings
    LaterSolutionNames = @($laterSolutionNames)
}

if ($context.ContainsKey('OperationBudget') -and $context['OperationBudget'] -is [System.Threading.SemaphoreSlim]) {
    $validationParameters.OperationBudget = $context['OperationBudget']
}
if ($context.ContainsKey('CancellationToken') -and $context['CancellationToken'] -is [System.Threading.CancellationToken]) {
    $validationParameters.CancellationToken = $context['CancellationToken']
}
if ($context.ContainsKey('ArtifactStagingDirectory') -and $context['ArtifactStagingDirectory']) {
    $validationParameters.LogDirectory = Join-Path (Join-Path $context['ArtifactStagingDirectory'] 'export-logs') $solutionName
}

@(validateSolutionInternal @validationParameters)
