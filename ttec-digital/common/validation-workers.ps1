function Get-AlmValidationSetting {
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Config)

    $settings = @{ parallel = $true; maxParallel = 4 }
    if (-not $Config.ContainsKey('validation') -or $null -eq $Config['validation']) { return $settings }
    $configured = $Config['validation']
    if ($configured -isnot [hashtable]) { throw 'validation must be a hashtable.' }
    foreach ($key in @('parallel', 'maxParallel')) {
        if (-not $configured.ContainsKey($key) -or $null -eq $configured[$key] -or ($configured[$key] -is [string] -and $configured[$key] -eq '')) { continue }
        if ($key -eq 'parallel') {
            if ($configured[$key] -isnot [bool]) { throw 'validation.parallel must be $true or $false.' }
            $settings[$key] = $configured[$key]
        } else {
            $limit = 0
            if (-not [int]::TryParse([string]$configured[$key], [ref]$limit) -or $limit -lt 1 -or $limit -gt 8) {
                throw 'validation.maxParallel must be an integer between 1 and 8.'
            }
            $settings[$key] = $limit
        }
    }
    return $settings
}
Set-Alias -Name Get-AlmValidationSettings -Value Get-AlmValidationSetting -Force

function Format-AlmLogLine {
    param(
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    foreach ($line in ($Text -split '\r?\n')) {
        $prefix = "[$SolutionName][$Phase]"
        if ($line -match '^(##vso\[[^\]]+\]|##\[(?:debug|warning|error|section)\]|::(?:warning|error|notice)(?: [^:]*)?::)(.*)$') {
            "$($Matches[1])$prefix $($Matches[2])"
        } else {
            "$prefix $line"
        }
    }
}

function Send-AlmWorkerEvent {
    param($Events, [string]$SolutionName, [string]$Phase, [string]$Message)

    $entry = [pscustomobject]@{ SolutionName = $SolutionName; Phase = $Phase; Message = $Message }
    if ($null -ne $Events) {
        $Events.Queue.Enqueue($entry)
        $Events.Signal.Set() | Out-Null
    } else { Format-AlmLogLine -SolutionName $SolutionName -Phase $Phase -Text $Message | ForEach-Object { Write-Host $_ } }
}

function Invoke-AlmValidationRule {
    param($Rule, $Context, $Events, [string]$LogDirectory = '')

    $started = [datetime]::UtcNow
    $phase = "Validate:$($Rule.Name)"
    Send-AlmWorkerEvent -Events $Events -SolutionName $Context.solutionname -Phase $phase -Message 'Started'
    $findings = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[string]]::new()
    $status = 'Completed'
    try {
        & { $ProgressPreference = 'SilentlyContinue'; & $Rule.Path $Context } *>&1 | ForEach-Object {
            $record = $_
            if ($record.PSObject.Properties['IsWarning'] -and $record.PSObject.Properties['Message']) {
                $findings.Add($record)
            } elseif ($record -is [System.Management.Automation.ErrorRecord]) {
                throw $record
            } else {
                $logs.Add([string]$record)
            }
        }
    } catch {
        $status = 'Failed'
        $logs.Add([string]$_)
        $failureDetails = ($_ | Out-String).TrimEnd()
        Send-AlmWorkerEvent -Events $Events -SolutionName $Context.solutionname -Phase $phase -Message "Failed: $failureDetails"
        throw
    } finally {
        if ($LogDirectory) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
            $details = @("Started $($started.ToString('o'))") + @($logs.ToArray()) + @($findings | ForEach-Object { $_.Message }) + @("$status $([datetime]::UtcNow.ToString('o')); $($findings.Count) finding(s)")
            @(foreach ($line in $details) {
                Format-AlmLogLine -SolutionName $Context.solutionname -Phase $phase -Text $line
            }) | Set-Content -LiteralPath (Join-Path $LogDirectory "$($Rule.Name).log") -Encoding utf8
        }
    }
    $finished = [datetime]::UtcNow
    Send-AlmWorkerEvent -Events $Events -SolutionName $Context.solutionname -Phase $phase -Message "Completed in $([math]::Round(($finished-$started).TotalSeconds,2))s; $($findings.Count) finding(s)"
    [pscustomobject]@{ Rule = $Rule.Name; Started = $started; Finished = $finished; Results = $findings.ToArray(); Logs = $logs.ToArray() }
}

function Invoke-AlmValidationRules {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Accepts and schedules multiple validation rules in a single invocation.')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules,
        [switch]$Parallel,
        [ValidateRange(1, 8)][int]$MaxParallel = 4,
        [System.Threading.SemaphoreSlim]$OperationBudget,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
        $LogEvents,
        [string]$LogDirectory = '',
        [System.Collections.Generic.List[object]]$RuleTimings
    )

    $completed = @{}
    $jobs = [System.Collections.Generic.List[object]]::new()
    $clients = [System.Collections.Generic.List[object]]::new()
    $ownedEvents = $null
    $ownedCancellation = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource([System.Threading.CancellationToken[]]@($CancellationToken))
    $CancellationToken = $ownedCancellation.Token
    $ownedBudget = $null
    try {
        if (-not $Parallel -or $Rules.Count -le 1) {
            foreach ($rule in $Rules) {
                $Context.ruleMode = $rule.Mode
                $acquired = $false
                try {
                    if ($null -ne $OperationBudget) { $OperationBudget.Wait($CancellationToken); $acquired = $true }
                    $completed[$rule.Name] = Invoke-AlmValidationRule -Rule $rule -Context $Context -Events $LogEvents -LogDirectory $LogDirectory
                } finally {
                    if ($acquired) { $OperationBudget.Release() | Out-Null }
                }
            }
        } else {
            if ($null -eq $LogEvents) {
                $ownedEvents = [pscustomobject]@{ Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new(); Signal = [System.Threading.AutoResetEvent]::new($false) }
                $LogEvents = $ownedEvents
            }
            $connection = Get-DataverseConnection -GetDefault
            $cloneMethod = $connection.GetType().GetMethods() | Where-Object { $_.Name -eq 'Clone' -and $_.GetParameters().Count -eq 1 } | Select-Object -First 1
            if (-not $cloneMethod) { throw 'Validation connection cloning is unavailable. Set validation.parallel = $false.' }
            $null = $connection.OrganizationDetail
            if ($null -eq $OperationBudget) {
                $ownedBudget = [System.Threading.SemaphoreSlim]::new($MaxParallel, $MaxParallel)
                $OperationBudget = $ownedBudget
            }
            $modulePath = (Get-Module Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1).Path
            $validationPath = Join-Path $PSScriptRoot 'solutionvalidation.ps1'
            $pending = [System.Collections.Generic.Queue[object]]::new()
            foreach ($rule in $Rules) { $pending.Enqueue($rule) }
            $active = [System.Collections.Generic.List[object]]::new()
            while ($pending.Count -or $active.Count) {
                while ($pending.Count -and $active.Count -lt $MaxParallel) {
                    $rule = $pending.Dequeue()
                    $client = $cloneMethod.Invoke($connection, [object[]]@($null))
                    $clients.Add($client)
                    $job = Start-ThreadJob -ThrottleLimit 32 -ArgumentList @($modulePath, $validationPath, $client, $Context, $rule, $OperationBudget, $CancellationToken, $LogEvents, $LogDirectory) -ScriptBlock {
                        param($ModulePath, $ValidationPath, $Client, $SourceContext, $Rule, $Budget, $Cancellation, $Events, $LogDirectory)
                        $ErrorActionPreference = 'Stop'
                        $ProgressPreference = 'SilentlyContinue'
                        if ($null -eq $Client) { throw 'Validation worker received no Dataverse connection.' }
                        $acquired = $false
                        try {
                            $Budget.Wait($Cancellation)
                            $acquired = $true
                            Import-Module $ModulePath
                            $sqlCommand = Get-Command Invoke-DataverseSQL
                            $recordCommand = Get-Command Get-DataverseRecord
                            $metadataCommand = Get-Command Get-DataverseEntityMetadata
                            $requestCommand = Get-Command Invoke-DataverseRequest
                            function Invoke-DataverseSQL { param($Sql, $Parameters); & $sqlCommand -Connection $Client @PSBoundParameters }
                            function Get-DataverseRecord { param($TableName, $Id, $Columns, $Top); & $recordCommand -Connection $Client @PSBoundParameters }
                            Set-Item -Path Function:\Get-DataverseEntityMetadata -Value {
                                param($EntityName, [switch]$UseMetadataCache, [switch]$ExcludeAttributes, [switch]$ExcludeRelationships, [switch]$ExcludePrivileges)
                                & $metadataCommand -Connection $Client @PSBoundParameters
                            }
                            function Invoke-DataverseRequest { param($Method, $Path); & $requestCommand -Connection $Client @PSBoundParameters }
                            function Get-DataverseConnection { param([switch]$GetDefault); $null = $GetDefault; return $Client }
                            . $ValidationPath
                            $context = [pscustomobject]@{
                                solutionname = $SourceContext.solutionname
                                validdependencysolutionnames = @($SourceContext.validdependencysolutionnames)
                                ignoresolutionnames = @($SourceContext.ignoresolutionnames)
                                solutionconfig = $SourceContext.solutionconfig
                                validationMode = $SourceContext.validationMode
                                laterSolutionNames = @($SourceContext.laterSolutionNames)
                                ruleMode = $Rule.Mode
                                ComponentDefinitionCache = @{}
                                ComponentNameCache = @{}
                            }
                            Invoke-AlmValidationRule -Rule $Rule -Context $context -Events $Events -LogDirectory $LogDirectory
                        } finally {
                            if ($acquired) { $Budget.Release() | Out-Null }
                        }
                    }
                    $jobs.Add($job)
                    $active.Add($job)
                }
                if ($null -ne $ownedEvents) {
                    Write-AlmWorkerEvents -Events $ownedEvents
                    $handles = [System.Threading.WaitHandle[]]@($ownedEvents.Signal) + [System.Threading.WaitHandle[]]@($active | ForEach-Object { $_.Finished })
                    [System.Threading.WaitHandle]::WaitAny($handles) | Out-Null
                    Write-AlmWorkerEvents -Events $ownedEvents
                } else { Wait-Job -Job $active.ToArray() -Any | Out-Null }
                foreach ($job in @($active.ToArray())) {
                    if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                        $result = @(Receive-Job -Job $job -ErrorAction Stop 6>$null)
                        if ($job.State -ne 'Completed' -or $result.Count -ne 1) { throw 'Validation rule worker failed.' }
                        $completed[$result[0].Rule] = $result[0]
                        $active.Remove($job) | Out-Null
                    }
                }
            }
        }
        foreach ($rule in $Rules) {
            $result = $completed[$rule.Name]
            if ($null -ne $RuleTimings) { $RuleTimings.Add($result) }
            $taggedLogs = @(foreach ($line in $result.Logs) { Format-AlmLogLine -SolutionName $Context.solutionname -Phase "Validate:$($rule.Name)" -Text $line })
            if ($taggedLogs.Count) {
                if ($env:TF_BUILD) { Write-Host "##[group][$($Context.solutionname)][Validate:$($rule.Name)] Details" }
                elseif ($env:GITHUB_ACTIONS) { Write-Host "::group::[$($Context.solutionname)][Validate:$($rule.Name)] Details" }
                $taggedLogs | ForEach-Object { Write-Host $_ }
                if ($env:TF_BUILD) { Write-Host '##[endgroup]' }
                elseif ($env:GITHUB_ACTIONS) { Write-Host '::endgroup::' }
            }
            $result.Results
        }
    } finally {
        if ($null -ne $ownedCancellation) { $ownedCancellation.Cancel() }
        foreach ($job in $jobs) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
        foreach ($client in $clients) { $client.Dispose() }
        if ($null -ne $ownedEvents) { Write-AlmWorkerEvents -Events $ownedEvents; $ownedEvents.Signal.Dispose() }
        if ($null -ne $ownedBudget) { $ownedBudget.Dispose() }
        $ownedCancellation.Dispose()
    }
}

function Write-AlmWorkerEvent {
    param([Parameter(Mandatory)]$Events)

    $entry = $null
    while ($Events.Queue.TryDequeue([ref]$entry)) {
        Format-AlmLogLine -SolutionName $entry.SolutionName -Phase $entry.Phase -Text $entry.Message | ForEach-Object { Write-Host $_ }
    }
}
Set-Alias -Name Write-AlmWorkerEvents -Value Write-AlmWorkerEvent -Force