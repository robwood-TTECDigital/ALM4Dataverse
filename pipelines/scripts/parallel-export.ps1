<#
.SYNOPSIS
    Defines the shared in-process export scheduler and logging helpers.
.DESCRIPTION
    Dot-source this file; it does not start workers. State returned by
    Start-AlmExportPipeline owns jobs, cloned clients, synchronization handles and
    a working directory and must be released with Stop-AlmExportPipeline in finally.
#>
. "$PSScriptRoot/../../ttec-digital/common/validation-workers.ps1"
Set-Alias -Name Send-AlmExportEvent -Value Send-AlmWorkerEvent -Force

function Get-AlmExportSetting {
    <#
    .SYNOPSIS
        Validates export settings while preserving explicit sequential opt-out.
    .DESCRIPTION
        Defaults: parallel=true, maxParallel=2 package workers,
        maxConcurrentOperations=4 Dataverse operation slots. Null/empty strings
        retain defaults; parallel must be Boolean and both limits integers 1-8,
        even when parallel is false. Returns a new hashtable or throws.
    #>
    [OutputType([hashtable])]
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

Set-Alias -Name Get-AlmExportSettings -Value Get-AlmExportSetting -Force

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
    # The SDK locates the managed companion beside the unmanaged ZIP returned by
    # Wait-AlmSolutionExport; both exports must finish before unpacking Both.
    # MappingFile redirects unpacked components; blank preserves the ordinary layout.
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$MappingFile
    )

    if ([string]::IsNullOrWhiteSpace($MappingFile)) {
        Expand-DataverseSolutionFile -Path $ZipPath -OutputPath $OutputPath -PackageType Both -UnpackMsapp
    } else {
        Expand-DataverseSolutionFile -Path $ZipPath -OutputPath $OutputPath -PackageType Both -UnpackMsapp -MappingFile $MappingFile
    }
}

function Start-AlmExportPipeline {
    <#
    .SYNOPSIS
        Allocates scheduler state and queues managed/unmanaged packages per solution.
    .DESCRIPTION
        Requires a loaded Dataverse module, a default cloneable connection and
        Start-ThreadJob. Duplicate names (case-insensitive) or missing cloning throw.
        Creates a unique directory beneath TempDirectory but does not launch jobs.
        Returns mutable state for the queue/wait/stop helpers; declined ShouldProcess
        returns nothing. The borrowed default connection is not owned by the state.
    .PARAMETER MaxParallel
        Maximum active package workers, separately bounded by operation slots from Config.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$TempDirectory,
        [ValidateRange(1, 8)][int]$MaxParallel = 2,
        [string]$BaseDirectory = '',
        [hashtable]$AdditionalHookContext = @{}
    )

    if (-not $PSCmdlet.ShouldProcess($TempDirectory, 'Initialize parallel export workers')) { return }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($solution in $Config.solutions) {
        if (-not $names.Add($solution.name)) { throw "Duplicate solution in export configuration: $($solution.name)" }
    }
    $connection = Get-DataverseConnection -GetDefault
    $cloneMethod = $connection.GetType().GetMethods() | Where-Object { $_.Name -eq 'Clone' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
    if (-not $cloneMethod) {
        throw 'Connection cloning is unavailable. Set export.parallel = $false to use sequential processing.'
    }
    # Populate details on the original client before cloning so workers do not
    # independently refresh partially initialized organization metadata.
    $null = $connection.OrganizationDetail
    Get-Command Start-ThreadJob -ErrorAction Stop | Out-Null
    $validateEarly = Test-AlmEarlyExportValidation -Config $Config
    $exportSettings = Get-AlmExportSetting -Config $Config
    $workDirectory = Join-Path $TempDirectory ('export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $state = @{
        Config = $Config
        BaseDirectory = $BaseDirectory
        AdditionalHookContext = $AdditionalHookContext
        PendingExports = [System.Collections.Generic.Queue[object]]::new()
        ActiveExports = [System.Collections.Generic.List[object]]::new()
        PendingValidations = [System.Collections.Generic.Queue[object]]::new()
        ActiveValidation = $null
        CompletedExports = @{}
        ValidationResults = @{}
        PreparedSolutions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        PendingSolutionHooks = [System.Collections.Generic.Queue[object]]::new()
        ActiveSolutionHooks = [System.Collections.Generic.List[object]]::new()
        SolutionHookResults = @{}
        SolutionIndexes = @{}
        Jobs = [System.Collections.Generic.List[object]]::new()
        Clients = [System.Collections.Generic.List[object]]::new()
        Timings = [System.Collections.Generic.List[object]]::new()
        Connection = $connection
        CloneMethod = $cloneMethod
        ModulePath = (Get-Module Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1).Path
        HelpersPath = $PSCommandPath
        ValidationRoot = (Join-Path $PSScriptRoot '../../ttec-digital/common')
        CommonPath = Join-Path $PSScriptRoot 'common.ps1'
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
    for ($solutionIndex = 0; $solutionIndex -lt $Config.solutions.Count; $solutionIndex++) {
        $solution = $Config.solutions[$solutionIndex]
        $state.CompletedExports[$solution.name] = @{}
        $state.SolutionIndexes[$solution.name] = $solutionIndex
        foreach ($managed in @($false, $true)) {
            $suffix = if ($managed) { '_managed' } else { '' }
            $state.PendingExports.Enqueue(@{
                SolutionName = $solution.name
                SolutionConfig = $solution
                SolutionIndex = $solutionIndex
                Managed = $managed
                Path = (Join-Path $workDirectory "$($solution.name)$suffix.zip")
            })
        }
    }
    return $state
}

function Start-AlmQueuedExport {
    <#
    .SYNOPSIS
        Fills free worker slots from PendingExports, mutating the shared state.
    .DESCRIPTION
        Clones one client per package. ArgumentList passes live client, semaphore,
        cancellation and event references to thread jobs rather than serialized
        process-job copies. Declined ShouldProcess leaves the queue untouched.
        Worker output contains one Kind=Export completion record plus diagnostics.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The worker explicitly binds its parameters through Start-ThreadJob ArgumentList, preserving shared client and semaphore references.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][hashtable]$State)

    if (-not $PSCmdlet.ShouldProcess('Pending exports', 'Start parallel workers')) { return }
    if ($WhatIfPreference) { throw 'No active export workers were started.' }

    while ($State.PendingExports.Count -and $State.ActiveExports.Count -lt $State.MaxParallel) {
        $task = $State.PendingExports.Dequeue()
        if ($State.PreparedSolutions.Add($task.SolutionName)) {
            $hookContext = @{}
            foreach ($key in $State.AdditionalHookContext.Keys) { $hookContext[$key] = $State.AdditionalHookContext[$key] }
            $hookContext.SolutionName = $task.SolutionName
            $hookContext.SolutionConfig = $task.SolutionConfig
            $hookContext.SolutionIndex = $task.SolutionIndex
            $hasPreExportSolutionHooks = $State.Config.ContainsKey('hooks') -and
                $State.Config['hooks'] -is [hashtable] -and
                $State.Config['hooks'].ContainsKey('preExportSolution') -and
                $State.Config['hooks']['preExportSolution']
            if ($hasPreExportSolutionHooks) {
                $hookClient = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
                if ($null -eq $hookClient) { throw "[$($task.SolutionName)][preExportSolution] Connection cloning returned no client." }
                $State.Clients.Add($hookClient)
                $hookContext.Connection = $hookClient
                $hookContext.OperationBudget = $State.OperationBudget
                $hookContext.CancellationToken = $State.Cancellation.Token
                $null = Invoke-Hook -HookType preExportSolution -BaseDirectory $State.BaseDirectory -Config $State.Config -AdditionalContext $hookContext -LogContext:$false
            }
        }
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
            # Cancellation can fail the wait before ownership is acquired; only
            # release a slot actually held, including when export itself throws.
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
        if ($null -eq $job) { throw 'No active export workers were started.' }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue $(if ($task.Managed) { 'Export:Managed' } else { 'Export:Unmanaged' })
        $State.Jobs.Add($job)
        $State.ActiveExports.Add($job)
    }
}

Set-Alias -Name Start-AlmQueuedExports -Value Start-AlmQueuedExport -Force

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
            if ($null -eq $Client) { throw 'Validation worker received no Dataverse connection.' }
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
            Set-Item -Path Function:\Get-DataverseEntityMetadata -Value {
                param($EntityName, [switch]$UseMetadataCache, [switch]$ExcludeAttributes, [switch]$ExcludeRelationships, [switch]$ExcludePrivileges)
                & $metadataCommand -Connection $Client @PSBoundParameters
            }
            function Invoke-DataverseRequest {
                param($Method, $Path)
                & $requestCommand -Connection $Client @PSBoundParameters
            }
            function Get-DataverseConnection { param([switch]$GetDefault); $null = $GetDefault; return $Client }
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
    <#
    .SYNOPSIS
        Drains a terminal worker's streams, logs details and returns its completion record.
    .DESCRIPTION
        Job must carry AlmSolutionName/AlmPhase. Writes an optional per-worker log
        and host diagnostics, filtering nested group markers. Throws unless the job
        completed with exactly one Kind-bearing record and no ErrorRecord, even if
        other output appears successful. Does not remove the job or dispose its client.
    #>
    [OutputType([pscustomobject])]
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

function Write-AlmExportEvent {
    [OutputType([void])]
    # Drain progress separately from completion records so long-running exports
    # remain visible while Receive-AlmExportJob waits until a worker is terminal.
    param([Parameter(Mandatory)][hashtable]$State)

    Write-AlmWorkerEvents -Events $State.LogEvents
}
Set-Alias -Name Write-AlmExportEvents -Value Write-AlmExportEvent -Force

function Wait-AlmExportActivity {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][object[]]$Jobs)

    Write-AlmExportEvents -State $State
    $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) + [System.Threading.WaitHandle[]]@($Jobs | ForEach-Object { $_.Finished })
    [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
    Write-AlmExportEvents -State $State
}

function Wait-AlmSolutionExport {
    <#
    .SYNOPSIS
        Advances all queued work until both packages for one configured solution finish.
    .DESCRIPTION
        Drains events and terminal jobs for any solution, records timings and starts
        more queued work while waiting. Returns the unmanaged ZIP path only after
        its managed companion completes. Worker failure or declined startup with no
        active jobs throws; callers still own mandatory Stop-AlmExportPipeline cleanup.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SolutionName
    )

    if ($WhatIfPreference) { throw 'No active export workers were started.' }
    Start-AlmQueuedExport -State $State
    while ($State.CompletedExports[$SolutionName].Count -lt 2) {
        Update-AlmExportValidation -State $State
        Invoke-AlmPostExportSolutionHookQueue -State $State
        Write-AlmExportEvent -State $State
        if ($State.ActiveExports.Count -eq 0) { throw "[$SolutionName][Export] No active export workers; queued exports were not started." }
        $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) +
            [System.Threading.WaitHandle[]]@($State.ActiveExports | ForEach-Object { $_.Finished }) +
            [System.Threading.WaitHandle[]]@($State.ActiveSolutionHooks | ForEach-Object { $_.Finished })
        if ($null -ne $State.ActiveValidation) { $handles += $State.ActiveValidation.Finished }
        [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
        Update-AlmExportValidation -State $State
        Invoke-AlmPostExportSolutionHookQueue -State $State
        Write-AlmExportEvent -State $State
        foreach ($job in @($State.ActiveExports.ToArray())) {
            if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
                $State.Timings.Add($result)
                $key = if ($result.Managed) { 'Managed' } else { 'Unmanaged' }
                $State.CompletedExports[$result.SolutionName][$key] = $result.Path
                $State.ActiveExports.Remove($job) | Out-Null
            }
        }
        Start-AlmQueuedExport -State $State
    }
    return $State.CompletedExports[$SolutionName].Unmanaged
}
Set-Alias -Name Wait-AlmSolutionExports -Value Wait-AlmSolutionExport -Force

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

function Invoke-AlmQueuedPostExportSolutionHook {
    <#
    .SYNOPSIS
        Starts queued post-export solution hooks in background workers.
    .DESCRIPTION
        Each hook runs in an isolated thread-job runspace and receives its cloned
        Dataverse connection as Context.Connection. The worker sets that client
        as the runspace's default so existing Dataverse commands use the clone.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The worker receives the hook context and cloned Dataverse client explicitly through Start-ThreadJob ArgumentList.')]
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.PendingSolutionHooks.Count -and $State.ActiveSolutionHooks.Count -lt $State.MaxParallel) {
        $task = $State.PendingSolutionHooks.Dequeue()
        $client = $State.CloneMethod.Invoke($State.Connection, [object[]]@($null))
        if ($null -eq $client) { throw "[$($task.SolutionName)][postExportSolution] Connection cloning returned no client." }
        $State.Clients.Add($client)
        $additionalContext = @{}
        foreach ($key in $task.AdditionalContext.Keys) { $additionalContext[$key] = $task.AdditionalContext[$key] }
        $additionalContext.Connection = $client
        $additionalContext.OperationBudget = $State.OperationBudget
        $additionalContext.CancellationToken = $State.Cancellation.Token
        $task.AdditionalContext = $additionalContext
        $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @(
            $State.ModulePath, $State.HelpersPath, $State.CommonPath, $task, $State.LogEvents
        ) -ScriptBlock {
            param($ModulePath, $HelpersPath, $CommonPath, $Task, $Events)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $started = [datetime]::UtcNow
            $phase = 'postExportSolution'
            try {
                Import-Module $ModulePath -ErrorAction Stop
                . $HelpersPath
                . $CommonPath
                Set-DataverseConnectionAsDefault -Connection $Task.AdditionalContext.Connection
                try {
                    Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message 'Started'
                    $results = @(Invoke-Hook -HookType postExportSolution -BaseDirectory $Task.BaseDirectory -Config $Task.Config -AdditionalContext $Task.AdditionalContext -LogContext:$false)
                    Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Completed in $([math]::Round(([datetime]::UtcNow-$started).TotalSeconds,2))s"
                } finally {
                    Set-DataverseConnectionAsDefault -Clear
                }
                [pscustomobject]@{ Kind = 'SolutionHook'; SolutionName = $Task.SolutionName; Results = $results; Started = $started; Finished = [datetime]::UtcNow }
            } catch {
                Send-AlmExportEvent -Events $Events -SolutionName $Task.SolutionName -Phase $phase -Message "Failed: $(($_ | Out-String).TrimEnd())"
                throw
            }
        }
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue $task.SolutionName
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue 'postExportSolution'
        $State.Jobs.Add($job)
        $State.ActiveSolutionHooks.Add($job)
    }
}

function Add-AlmPostExportSolutionHook {
    <#
    .SYNOPSIS
        Queues the post-export hook for a solution after unpack and comparison.
    .DESCRIPTION
        Copies the export context, adds solution-specific values and schedules
        the hook without waiting for other exports to finish.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$SolutionConfig,
        [Parameter(Mandatory)][int]$SolutionIndex
    )

    $hasHooks = $State.Config.ContainsKey('hooks') -and
        $State.Config['hooks'] -is [hashtable] -and
        $State.Config['hooks'].ContainsKey('postExportSolution') -and
        $State.Config['hooks']['postExportSolution']
    if (-not $hasHooks) { return }
    $additionalContext = @{}
    foreach ($key in $State.AdditionalHookContext.Keys) { $additionalContext[$key] = $State.AdditionalHookContext[$key] }
    $additionalContext.SolutionName = $SolutionConfig.name
    $additionalContext.SolutionConfig = $SolutionConfig
    $additionalContext.SolutionIndex = $SolutionIndex
    $State.PendingSolutionHooks.Enqueue(@{
        SolutionName = $SolutionConfig.name
        SolutionIndex = $SolutionIndex
        SolutionConfig = $SolutionConfig
        Config = $State.Config
        BaseDirectory = $State.BaseDirectory
        AdditionalContext = $additionalContext
    })
    Invoke-AlmPostExportSolutionHookQueue -State $State
}

function Invoke-AlmPostExportSolutionHookQueue {
    <#
    .SYNOPSIS
        Collects completed solution hooks and starts queued hooks.
    .DESCRIPTION
        Stores each hook's results by solution name, surfaces worker failures and
        fills available parallel slots from the pending queue.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    foreach ($job in @($State.ActiveSolutionHooks.ToArray())) {
        if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
            $result = Receive-AlmExportJob -Job $job -LogDirectory $State.LogDirectory
            if ($result.Kind -ne 'SolutionHook') { throw "[$($job.AlmSolutionName)][postExportSolution] Unexpected worker result '$($result.Kind)'." }
            $State.SolutionHookResults[$result.SolutionName] = @($result.Results)
            $State.ActiveSolutionHooks.Remove($job) | Out-Null
        }
    }
    Invoke-AlmQueuedPostExportSolutionHook -State $State
}

function Complete-AlmPostExportSolutionHook {
    <#
    .SYNOPSIS
        Waits for all queued post-export solution hooks to finish.
    .DESCRIPTION
        Continues draining hook events and completion records until no pending
        or active hooks remain, before the global postExport hook runs.
    #>
    param([Parameter(Mandatory)][hashtable]$State)

    while ($State.PendingSolutionHooks.Count -or $State.ActiveSolutionHooks.Count) {
        Invoke-AlmPostExportSolutionHookQueue -State $State
        if ($State.ActiveSolutionHooks.Count) {
            $handles = [System.Threading.WaitHandle[]]@($State.LogEvents.Signal) +
                [System.Threading.WaitHandle[]]@($State.ActiveSolutionHooks | ForEach-Object { $_.Finished })
            [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
        }
        Write-AlmExportEvent -State $State
    }
}

function Stop-AlmExportPipeline {
    <#
    .SYNOPSIS
        Cancels and releases an owned scheduler, including after failure.
    .DESCRIPTION
        Stops/removes jobs, drains remaining logs, disposes cloned clients and
        synchronization handles and deletes WorkDirectory, but not the default
        connection or external LogDirectory. Intended for one finally call per
        initialized state, not repeated disposal. Cleanup bypasses ambient WhatIf.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mandatory teardown cancels owned jobs and releases clients, synchronization handles and temporary files; prompting must not strand resources after an export failure.')]
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
        Remove-Item -LiteralPath $State.WorkDirectory -Recurse -Force -WhatIf:$false
    }
}