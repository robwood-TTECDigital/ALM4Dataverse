. "$PSScriptRoot/../../ttec-digital/common/validation-workers.ps1"

function Get-AlmExportSettings {
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Config)

    $settings = @{ parallel = $true; maxParallel = 2; maxConcurrentOperations = 4 }
    if (-not $Config.ContainsKey('export') -or $null -eq $Config['export']) { return $settings }
    $configured = $Config['export']
    if ($configured -isnot [hashtable]) { throw 'export must be a hashtable.' }
    if ($configured.ContainsKey('parallel') -and $null -ne $configured['parallel'] -and ($configured['parallel'] -isnot [string] -or $configured['parallel'] -ne '')) {
        if ($configured['parallel'] -isnot [bool]) { throw 'export.parallel must be $true or $false.' }
        $settings.parallel = $configured['parallel']
    }
    if ($configured.ContainsKey('maxParallel') -and $null -ne $configured['maxParallel'] -and ($configured['maxParallel'] -isnot [string] -or $configured['maxParallel'] -ne '')) {
        $limit = 0
        if (-not [int]::TryParse([string]$configured['maxParallel'], [ref]$limit) -or $limit -lt 1 -or $limit -gt 8) {
            throw 'export.maxParallel must be an integer between 1 and 8.'
        }
        $settings.maxParallel = $limit
    }
    if ($configured.ContainsKey('maxConcurrentOperations') -and $null -ne $configured['maxConcurrentOperations'] -and ($configured['maxConcurrentOperations'] -isnot [string] -or $configured['maxConcurrentOperations'] -ne '')) {
        $limit = 0
        if (-not [int]::TryParse([string]$configured['maxConcurrentOperations'], [ref]$limit) -or $limit -lt 1 -or $limit -gt 8) {
            throw 'export.maxConcurrentOperations must be an integer between 1 and 8.'
        }
        $settings.maxConcurrentOperations = $limit
    }
    return $settings
}

function Test-AlmEarlyExportValidation {
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Config)

    if (-not $Config.ContainsKey('hooks') -or $Config['hooks'] -isnot [hashtable]) { return $false }
    $hooks = $Config['hooks']
    if (-not $hooks.ContainsKey('postExport') -or $null -eq $hooks['postExport']) { return $false }
    $postExportHooks = @($hooks['postExport'])
    if ($postExportHooks.Count -eq 0 -or $postExportHooks[0] -ne '[alm]/ttec-digital/postexport.ps1') { return $false }
    return -not ($Config.ContainsKey('PostExportScript') -and $Config['PostExportScript'])
}

function Expand-AlmExportSolution {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    Expand-DataverseSolutionFile -Path $ZipPath -OutputPath $OutputPath -PackageType Both -UnpackMsapp
}

function Start-AlmExportPipeline {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TempDirectory,
        [ValidateRange(1, 8)][int]$MaxParallel = 2
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($solution in $Config.solutions) {
        if (-not $names.Add($solution.name)) { throw "Duplicate solution in export configuration: $($solution.name)" }
    }
    $connection = Get-DataverseConnection -GetDefault
    $cloneMethod = $connection.GetType().GetMethods() | Where-Object { $_.Name -eq 'Clone' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
    if (-not $cloneMethod) {
        throw 'Connection cloning is unavailable. Set export.parallel = $false to use sequential processing.'
    }
    $null = $connection.OrganizationDetail
    Get-Command Start-ThreadJob -ErrorAction Stop | Out-Null
    $validateEarly = Test-AlmEarlyExportValidation -Config $Config
    $exportSettings = Get-AlmExportSettings -Config $Config
    $workDirectory = Join-Path $TempDirectory ('export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $state = @{
        PendingExports = [System.Collections.Generic.Queue[object]]::new()
        ActiveExports = [System.Collections.Generic.List[object]]::new()
        PendingValidations = [System.Collections.Generic.Queue[object]]::new()
        ActiveValidation = $null
        CompletedExports = @{}
        ValidationResults = @{}
        Jobs = [System.Collections.Generic.List[object]]::new()
        Clients = [System.Collections.Generic.List[object]]::new()
        Timings = [System.Collections.Generic.List[object]]::new()
        Connection = $connection
        CloneMethod = $cloneMethod
        ModulePath = (Get-Module Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1).Path
        HelpersPath = $PSCommandPath
        ValidationRoot = (Join-Path $PSScriptRoot '../../ttec-digital/common')
        WorkDirectory = $workDirectory
        MaxParallel = $MaxParallel
        ValidateEarly = $validateEarly
        ValidationSettings = Get-AlmValidationSettings -Config $Config
        OperationBudget = [System.Threading.SemaphoreSlim]::new($exportSettings.maxConcurrentOperations, $exportSettings.maxConcurrentOperations)
        Cancellation = [System.Threading.CancellationTokenSource]::new()
        LogEvents = [pscustomobject]@{
            Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            Signal = [System.Threading.AutoResetEvent]::new($false)
        }
        LogDirectory = ''
    }
    foreach ($solution in $Config.solutions) {
        $state.CompletedExports[$solution.name] = @{}
        foreach ($managed in @($false, $true)) {
            $suffix = if ($managed) { '_managed' } else { '' }
            $state.PendingExports.Enqueue(@{
                SolutionName = $solution.name
                Managed = $managed
                Path = (Join-Path $workDirectory "$($solution.name)$suffix.zip")
            })
        }
    }
    return $state
}

function Start-AlmQueuedExports {
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.PendingExports.Count -and $State.ActiveExports.Count -lt $State.MaxParallel) {
        $task = $State.PendingExports.Dequeue()
        $client = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
        if ($null -eq $client) { throw "[$($task.SolutionName)][Export] Connection cloning returned no client." }
        $State.Clients.Add($client)
        $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @($State.ModulePath, $client, $task, $State.OperationBudget, $State.Cancellation.Token, $State.LogEvents, "$PSScriptRoot/../../ttec-digital/common/validation-workers.ps1") -ScriptBlock {
            param($ModulePath, $Client, $Task, $Budget, $Cancellation, $Events, $LogHelpers)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $started = [datetime]::UtcNow
            Import-Module $ModulePath
            . $LogHelpers
            $phase = if ($Task.Managed) { 'Export:Managed' } else { 'Export:Unmanaged' }
            $acquired = $false
            try {
                $Budget.Wait($Cancellation)
                $acquired = $true
                Send-AlmWorkerEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message 'Started'
                Export-DataverseSolution -SolutionName $Task.SolutionName -Managed:$Task.Managed -OutFile $Task.Path -Connection $Client
                Send-AlmWorkerEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Completed in $([math]::Round(([datetime]::UtcNow-$started).TotalSeconds,2))s"
            } catch {
                Send-AlmWorkerEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Failed: $(($_ | Out-String).TrimEnd())"
                throw
            } finally {
                if ($acquired) { $Budget.Release() | Out-Null }
            }
            [pscustomobject]@{ Kind = 'Export'; SolutionName = $Task.SolutionName; Managed = $Task.Managed; Path = $Task.Path; Started = $started; Finished = [datetime]::UtcNow }
        }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue $(if ($task.Managed) { 'Export:Managed' } else { 'Export:Unmanaged' })
        $State.Jobs.Add($job)
        $State.ActiveExports.Add($job)
    }
}

function Update-AlmExportValidation {
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -ne $State.ActiveValidation -and $State.ActiveValidation.State -in @('Completed', 'Failed', 'Stopped')) {
        $result = Receive-AlmExportJob -Job $State.ActiveValidation -LogDirectory $State.LogDirectory
        $State.Timings.Add($result)
        $State.ValidationResults[$result.SolutionName] = @($result.Results)
        $State.ActiveValidation = $null
    }
    if ($null -eq $State.ActiveValidation -and $State.PendingValidations.Count) {
        $task = $State.PendingValidations.Dequeue()
        $client = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
        $State.Clients.Add($client)
        $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @($State.ModulePath, $State.ValidationRoot, $client, $task, $State.ValidationSettings, $State.OperationBudget, $State.Cancellation.Token, $State.LogEvents, $State.LogDirectory) -ScriptBlock {
            param($ModulePath, $ValidationRoot, $Client, $Task, $Settings, $Budget, $Cancellation, $Events, $LogDirectory)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $started = [datetime]::UtcNow
            Import-Module $ModulePath
            & "$ValidationRoot/load-dataverse-sdk.ps1"
            $sqlCommand = Get-Command Invoke-DataverseSQL
            $recordCommand = Get-Command Get-DataverseRecord
            $metadataCommand = Get-Command Get-DataverseEntityMetadata
            $requestCommand = Get-Command Invoke-DataverseRequest
            function Invoke-DataverseSQL {
                param($Sql, $Parameters)
                & $sqlCommand -Connection $Client @PSBoundParameters
            }
            function Get-DataverseRecord {
                param($TableName, $Id, $Columns, $Top)
                & $recordCommand -Connection $Client @PSBoundParameters
            }
            function Get-DataverseEntityMetadata {
                param($EntityName, [switch]$UseMetadataCache, [switch]$ExcludeAttributes, [switch]$ExcludeRelationships, [switch]$ExcludePrivileges)
                & $metadataCommand -Connection $Client @PSBoundParameters
            }
            function Invoke-DataverseRequest {
                param($Method, $Path)
                & $requestCommand -Connection $Client @PSBoundParameters
            }
            function Get-DataverseConnection { param([switch]$GetDefault); return $Client }
            . "$ValidationRoot/solutionvalidation.ps1"
            $ruleTimings = [System.Collections.Generic.List[object]]::new()
            $solutionLogs = if ($LogDirectory) { Join-Path $LogDirectory $Task.SolutionName } else { '' }
            Send-AlmWorkerEvent -Events $Events -SolutionName $Task.SolutionName -Phase Validate -Message 'Started'
            $results = @(validateSolutionInternal -solutionname $Task.SolutionName -solutionconfig $Task.Config `
                -validdependencysolutionnames $Task.Dependencies -ignoresolutionnames $Task.IgnoreSolutions -validationMode $Task.Mode `
                -ParallelRules:$Settings.parallel -MaxParallel $Settings.maxParallel -OperationBudget $Budget -CancellationToken $Cancellation -LogEvents $Events -LogDirectory $solutionLogs -RuleTimings $ruleTimings)
            Send-AlmWorkerEvent -Events $Events -SolutionName $Task.SolutionName -Phase Validate -Message "Completed; $($results.Count) finding(s)"
            [pscustomobject]@{ Kind = 'Validation'; SolutionName = $Task.SolutionName; Results = $results; Started = $started; Finished = [datetime]::UtcNow; RuleTimings = $ruleTimings.ToArray() }
        }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue 'Validate'
        $State.Jobs.Add($job)
        $State.ActiveValidation = $job
    }
}

function Receive-AlmExportJob {
    param([Parameter(Mandatory)]$Job, [string]$LogDirectory = '')

    $solutionName = if ($Job.PSObject.Properties['AlmSolutionName']) { $Job.AlmSolutionName } else { 'Worker' }
    $phase = if ($Job.PSObject.Properties['AlmPhase']) { $Job.AlmPhase } else { 'Processing' }
    $records = @(Receive-Job -Job $Job -ErrorAction Continue *>&1)
    $result = @($records | Where-Object { $_.PSObject.Properties['Kind'] })
    $details = @(foreach ($record in $records | Where-Object { -not $_.PSObject.Properties['Kind'] }) {
        $text = [string]$record
        foreach ($line in ($text -split '\r?\n')) {
            if ($line.StartsWith("[$solutionName]")) { $line }
            elseif ($line -notmatch '^(##\[(?:endgroup|group)\]|::(?:endgroup|group)::)') { Format-AlmLogLine -SolutionName $solutionName -Phase $phase -Text $line }
        }
    })
    if ($LogDirectory) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $LogDirectory "$solutionName-$($phase.Replace(':','-')).log") -Value (@("[$solutionName][$phase] Worker state=$($Job.State)") + $details) -Encoding utf8
    }
    if ($details.Count) {
        if ($env:TF_BUILD) { Write-Host "##[group][$solutionName][$phase] Details" }
        elseif ($env:GITHUB_ACTIONS) { Write-Host "::group::[$solutionName][$phase] Details" }
        try { $details | ForEach-Object { Write-Host $_ } }
        finally {
            if ($env:TF_BUILD) { Write-Host '##[endgroup]' }
            elseif ($env:GITHUB_ACTIONS) { Write-Host '::endgroup::' }
        }
    }
    if ($Job.State -ne 'Completed' -or $result.Count -ne 1 -or @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count) {
        throw "[$solutionName][$phase] Worker failed: $($Job.JobStateInfo.Reason)"
    }
    return $result[0]
}

function Write-AlmExportEvents {
    param([Parameter(Mandatory)][hashtable]$State)

    Write-AlmWorkerEvents -Events $State.LogEvents
}

function Wait-AlmExportActivity {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][object[]]$Jobs)

    Write-AlmExportEvents -State $State
    $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) + [System.Threading.WaitHandle[]]@($Jobs | ForEach-Object { $_.Finished })
    [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
    Write-AlmExportEvents -State $State
}

function Wait-AlmSolutionExports {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SolutionName
    )

    Start-AlmQueuedExports -State $State
    while ($State.CompletedExports[$SolutionName].Count -lt 2) {
        Update-AlmExportValidation -State $State
        $waitJobs = @($State.ActiveExports.ToArray())
        if ($null -ne $State.ActiveValidation) { $waitJobs += $State.ActiveValidation }
        Wait-AlmExportActivity -State $State -Jobs $waitJobs
        foreach ($job in @($State.ActiveExports.ToArray())) {
            if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
                $State.Timings.Add($result)
                $key = if ($result.Managed) { 'Managed' } else { 'Unmanaged' }
                $State.CompletedExports[$result.SolutionName][$key] = $result.Path
                $State.ActiveExports.Remove($job) | Out-Null
            }
        }
        Start-AlmQueuedExports -State $State
    }
    return $State.CompletedExports[$SolutionName].Unmanaged
}

function Add-AlmExportValidation {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Solution,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Dependencies
    )

    if (-not $State.ValidateEarly) { return }
    $mode = 'error'
    if ($Solution.ContainsKey('validationMode') -and $Solution.validationMode) { $mode = $Solution.validationMode.ToLower() }
    if ($mode -eq 'disabled') { return }
    $ignoreSolutions = @()
    if ($Config.ContainsKey('IgnoreSolutions')) {
        $ignoreSolutions = @($Config['IgnoreSolutions'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $State.PendingValidations.Enqueue(@{
        SolutionName = $Solution.name
        Config = $Solution
        Dependencies = @($Dependencies)
        IgnoreSolutions = $ignoreSolutions
        Mode = $mode
    })
    Update-AlmExportValidation -State $State
}

function Complete-AlmExportValidation {
    param([Parameter(Mandatory)][hashtable]$State)

    while ($null -ne $State.ActiveValidation -or $State.PendingValidations.Count) {
        Update-AlmExportValidation -State $State
        if ($null -ne $State.ActiveValidation) { Wait-AlmExportActivity -State $State -Jobs @($State.ActiveValidation) }
    }
    Write-AlmExportEvents -State $State
}

function Stop-AlmExportPipeline {
    param([Parameter(Mandatory)][hashtable]$State)

    $State.Cancellation.Cancel()
    try {
        foreach ($job in $State.Jobs) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job }
            if ($job.HasMoreData) {
                try {
                    $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
                    $State.Timings.Add($result)
                } catch {
                    Write-Host ([string]$_)
                }
            }
            Remove-Job -Job $job -Force
        }
        Write-AlmExportEvents -State $State
    } finally {
        foreach ($client in $State.Clients) { $client.Dispose() }
        $State.OperationBudget.Dispose()
        $State.Cancellation.Dispose()
        $State.LogEvents.Signal.Dispose()
        Remove-Item -LiteralPath $State.WorkDirectory -Recurse -Force
    }
}