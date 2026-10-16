BeforeAll {
    Set-StrictMode -Version Latest
    . "$PSScriptRoot/../../common/solutionvalidation.ps1"
    . "$PSScriptRoot/../../../pipelines/scripts/parallel-export.ps1"
    . "$PSScriptRoot/../../../pipelines/scripts/common.ps1"
    function Invoke-DataverseSQL {
        param($Sql, $Parameters)
        $null = @($Sql, $Parameters)
    }
    function Get-DataverseRecord {
        param($TableName, $Id, $Columns, $Top)
        $null = @($TableName, $Id, $Columns, $Top)
    }
    Set-Item -Path Function:\Get-DataverseEntityMetadata -Value {
        param($EntityName, [switch]$UseMetadataCache, [switch]$ExcludeAttributes, [switch]$ExcludeRelationships, [switch]$ExcludePrivileges)
        $null = @($EntityName, $UseMetadataCache, $ExcludeAttributes, $ExcludeRelationships, $ExcludePrivileges)
    }
}

Describe 'Strict-mode export configuration' {
    It 'ships matching default concurrency settings in the consuming template' {
        foreach ($path in @("$PSScriptRoot/../../../alm-config-defaults.psd1", "$PSScriptRoot/../../../copy-to-your-repo/alm-config.psd1")) {
            $config = Import-PowerShellDataFile $path
            (Get-AlmExportSetting -Config $config).maxConcurrentOperations | Should -Be 4
            (Get-AlmValidationSettings -Config $config).parallel | Should -BeTrue
            (Get-AlmValidationSettings -Config $config).maxParallel | Should -Be 4
        }
        $defaults = Import-PowerShellDataFile "$PSScriptRoot/../../../alm-config-defaults.psd1"
        $defaults.hooks.parallelExportSolution | Should -Contain '[alm]/ttec-digital/parallel-export-solution.ps1'
    }

    It 'includes per-solution export hooks in migrated configuration output' {
        Import-Module "$PSScriptRoot/../../migrate-common.psm1" -Force
        $section = Build-HooksSection -Hooks @{
            preExportSolution = @('custom/pre-solution.ps1')
            parallelExportSolution = @('[alm]/ttec-digital/parallel-export-solution.ps1')
            postExportSolution = @('custom/post-solution.ps1')
        }
        $section | Should -Match 'preExportSolution\s*='
        $section | Should -Match 'parallelExportSolution\s*='
        $section | Should -Match 'postExportSolution\s*='
        $section | Should -Match ([regex]::Escape('[alm]/ttec-digital/parallel-export-solution.ps1'))
    }

    It 'defaults validation settings and preserves an explicit opt-out' {
        foreach ($config in @(@{}, @{validation=$null}, @{validation=@{}}, @{validation=@{parallel=$null;maxParallel=''}})) {
            $settings = Get-AlmValidationSettings -Config $config
            $settings.parallel | Should -BeTrue
            $settings.maxParallel | Should -Be 4
        }
        (Get-AlmValidationSettings -Config @{validation=@{parallel=$false;maxParallel=2}}).parallel | Should -BeFalse
        { Get-AlmValidationSettings -Config @{validation=@{parallel='false'}} } | Should -Throw
        { Get-AlmValidationSettings -Config @{validation=@{maxParallel=0}} } | Should -Throw
    }

    It 'tags every line while preserving pipeline logging commands' {
        $lines = @(Format-AlmLogLine -SolutionName TestSolution1 -Phase Validate -Text "First`nSecond")
        $lines | Should -Be @('[TestSolution1][Validate] First', '[TestSolution1][Validate] Second')
        Format-AlmLogLine -SolutionName TestSolution1 -Phase Validate -Text '##vso[task.logissue type=warning]Finding' | Should -Be '##vso[task.logissue type=warning][TestSolution1][Validate] Finding'
        Format-AlmLogLine -SolutionName TestSolution1 -Phase Validate -Text '::error::Finding' | Should -Be '::error::[TestSolution1][Validate] Finding'
    }

    It 'defaults missing, null, and empty settings' {
        foreach ($config in @(@{}, @{export=$null}, @{export=@{}}, @{export=@{parallel=$null;maxParallel=$null}}, @{export=@{parallel='';maxParallel=''}})) {
            $settings = Get-AlmExportSetting -Config $config
            $settings.parallel | Should -BeTrue
            $settings.maxParallel | Should -Be 2
            $settings.maxConcurrentOperations | Should -Be 4
        }
    }

    It 'preserves the explicit opt-out and worker limit' {
        $settings = Get-AlmExportSetting -Config @{export=@{parallel=$false;maxParallel=1}}
        $settings.parallel | Should -BeFalse
        $settings.maxParallel | Should -Be 1
    }

    It 'rejects invalid settings with configuration errors' {
        { Get-AlmExportSetting -Config @{export='invalid'} } | Should -Throw 'export must be a hashtable.'
        { Get-AlmExportSetting -Config @{export=@{parallel='false'}} } | Should -Throw 'export.parallel must be $true or $false.'
        foreach ($limit in @(0, 9, 'invalid')) {
            { Get-AlmExportSetting -Config @{export=@{maxParallel=$limit}} } | Should -Throw 'export.maxParallel must be an integer between 1 and 8.'
            { Get-AlmExportSetting -Config @{export=@{maxConcurrentOperations=$limit}} } | Should -Throw 'export.maxConcurrentOperations must be an integer between 1 and 8.'
        }
    }

    It 'handles missing, null, and empty hook configuration' {
        Mock Test-Path { throw 'Unexpected hook execution' }
        foreach ($config in @(@{}, @{hooks=$null}, @{hooks=@{}}, @{hooks=@{postExport=$null}}, @{hooks=@{postExport=@()}}, @{hooks=@{postExport=''}})) {
            Invoke-Hook -HookType postExport -BaseDirectory $TestDrive -Config $config
        }
        Should -Invoke Test-Path -Exactly -Times 0
    }

    It 'falls back to validation for missing, null, and empty result maps' {
        $tokens = $null
        $parseErrors = $null
        $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../../postexport.ps1", [ref]$tokens, [ref]$parseErrors)
        $loop = $syntaxTree.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$config.solutions' }, $true)[0]
        Mock validateSolution { }
        $config = @{solutions=@(@{name='TestSolution1'})}
        $validationSettings = Get-AlmValidationSettings -Config $config
        $validdependencysolutionnames = @()
        $ignoresolutionnames = @()
        foreach ($context in @(@{}, @{ParallelExportSolutionHookResults=$null}, @{ParallelExportSolutionHookResults=@{}}, @{ParallelExportSolutionHookResults=@{TestSolution1=$null}}, @{SolutionHookResults=$null}, @{SolutionHookResults=@{}}, @{SolutionHookResults=@{TestSolution1=$null}}, @{ExportValidationResults=$null}, @{ExportValidationResults=@{}}, @{ExportValidationResults=@{TestSolution1=$null}})) {
            . ([scriptblock]::Create($loop.Extent.Text))
        }
        Should -Invoke validateSolution -Exactly -Times 10 -ParameterFilter { $null -eq $PrecomputedResults }
    }

    It 'uses per-solution hook results without repeating validation' {
        $tokens = $null
        $parseErrors = $null
        $syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../../postexport.ps1", [ref]$tokens, [ref]$parseErrors)
        $loop = $syntaxTree.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$config.solutions' }, $true)[0]
        Mock validateSolution { }
        $finding = [pscustomobject]@{ Message = 'Precomputed finding'; IsWarning = $false }
        $config = @{solutions=@(@{name='TestSolution1'})}
        $validationSettings = Get-AlmValidationSettings -Config $config
        $validdependencysolutionnames = @()
        $ignoresolutionnames = @()
        $context = @{ParallelExportSolutionHookResults=@{TestSolution1=@($finding)}}
        . ([scriptblock]::Create($loop.Extent.Text))
        Should -Invoke validateSolution -Exactly -Times 1 -ParameterFilter { $PrecomputedResults.Count -eq 1 -and $PrecomputedResults[0].Message -eq 'Precomputed finding' }
    }

    It 'validates a solution with the configured dependency order in the per-solution hook' {
        Mock validateSolutionInternal { [pscustomobject]@{ Message = 'Finding'; IsWarning = $false } }
        $config = @{
            solutions = @(@{name='Earlier'}, @{name='Current'}, @{name='Later'})
            ExternalDependencySolutionNames = @('External')
            DependencySolutions = @('Shared')
            IgnoreSolutions = @('Ignored')
            validation = @{parallel=$false;maxParallel=2}
        }
        $context = @{
            SolutionName = 'Current'
            SolutionConfig = $config.solutions[1]
            SolutionIndex = 1
            Config = $config
        }
        $results = @(. "$PSScriptRoot/../../parallel-export-solution.ps1" -Context $context)
        $results.Count | Should -Be 1
        Should -Invoke validateSolutionInternal -Exactly -Times 1 -ParameterFilter {
            $validdependencysolutionnames -contains 'External' -and
            $validdependencysolutionnames -contains 'Shared' -and
            $validdependencysolutionnames -contains 'Earlier' -and
            $validdependencysolutionnames -notcontains 'Later' -and
            $LaterSolutionNames -contains 'Later' -and
            $ignoresolutionnames -contains 'Ignored' -and
            $ParallelRules -eq $false -and
            $MaxParallel -eq 2
        }
    }
}

Describe 'External-token connection initialization' {
    BeforeAll {
        if (-not ('AlmLazyOrganizationClient' -as [type])) {
            Add-Type -TypeDefinition @'
public sealed class AlmLazyOrganizationClient : System.IDisposable
{
    private bool isCloning;
    public bool DetailsRead { get; private set; }
    public bool IsClone { get; private set; }
    public object OrganizationDetail
    {
        get
        {
            if (!isCloning && !DetailsRead)
            {
                if (IsClone)
                    throw new System.InvalidOperationException("RefreshInstanceDetails");
                DetailsRead = true;
            }
            return this;
        }
    }
    public AlmLazyOrganizationClient Clone(object logger)
    {
        isCloning = true;
        try
        {
            _ = OrganizationDetail;
            return new AlmLazyOrganizationClient { DetailsRead = DetailsRead, IsClone = true };
        }
        finally { isCloning = false; }
    }
    public void Dispose() { }
}
'@
        }
    }

    It 'initializes organization details before export clients can be cloned' {
        $connection = [AlmLazyOrganizationClient]::new()
        Mock Get-DataverseConnection { $connection }
        Mock Get-Module { [pscustomobject]@{Path='unused-module-path'} }
        $state = Start-AlmExportPipeline -Config @{solutions=@()} -TempDirectory $TestDrive
        try {
            $connection.DetailsRead | Should -BeTrue
            $clone = $state.CloneMethod.Invoke($connection, [object[]]@($null))
            $clone.OrganizationDetail | Should -Not -BeNullOrEmpty
            $nestedClone = $state.CloneMethod.Invoke($clone, [object[]]@($null))
            $nestedClone.OrganizationDetail | Should -Not -BeNullOrEmpty
        } finally { Stop-AlmExportPipeline -State $state }
    }

    It 'initializes organization details before standalone parallel rule clients are cloned' {
        $connection = [AlmLazyOrganizationClient]::new()
        Mock Get-DataverseConnection { $connection }
        Mock Get-Module { [pscustomobject]@{Path='unused-module-path'} }
        Mock Start-ThreadJob {
            $ArgumentList[2].DetailsRead | Should -BeTrue
            $ArgumentList[2].OrganizationDetail | Should -Not -BeNullOrEmpty
            throw 'Initialized client reached scheduler'
        }
        $rules = @(@{Name='First';Mode='error';Path={}}, @{Name='Second';Mode='error';Path={}})
        { Invoke-AlmValidationRules -Context ([pscustomobject]@{solutionname='TestSolution1'}) -Rules $rules -Parallel } | Should -Throw '*Initialized client reached scheduler*'
        $connection.DetailsRead | Should -BeTrue
        Should -Invoke Start-ThreadJob -Exactly -Times 1
    }
}

Describe 'Validation worker reporting and budgets' {
    It 'separates findings from detail streams and preserves rule order and mode' {
        $context = [pscustomobject]@{ solutionname = 'TestSolution1'; ruleMode = 'error' }
        $rules = @(
            @{Name='First';Mode='warning';Path={param($context) Write-Host 'Detail'; [pscustomobject]@{Message='First';IsWarning=($context.ruleMode -eq 'warning')}}},
            @{Name='Second';Mode='error';Path={param($context) [pscustomobject]@{Message='Second';IsWarning=($context.ruleMode -eq 'warning')}}}
        )
        $budget = [System.Threading.SemaphoreSlim]::new(1,1)
        $timings = [System.Collections.Generic.List[object]]::new()
        try {
            $results = @(Invoke-AlmValidationRules -Context $context -Rules $rules -OperationBudget $budget -LogDirectory $TestDrive -RuleTimings $timings)
            $results.Message | Should -Be @('First','Second')
            $results.IsWarning | Should -Be @($true,$false)
            $budget.CurrentCount | Should -Be 1
            $timings.Count | Should -Be 2
            $timings[0].Logs | Should -Be @('Detail')
            $lines = @(Get-Content (Join-Path $TestDrive 'First.log'))
            $lines[0] | Should -Match '^\[TestSolution1\]\[Validate:First\] Started '
            $lines | Should -Contain '[TestSolution1][Validate:First] Detail'
            $lines | Should -Contain '[TestSolution1][Validate:First] First'
            $lines[-1] | Should -Match '^\[TestSolution1\]\[Validate:First\] Completed '
        } finally { $budget.Dispose() }
    }

    It 'retains failure details and releases a held slot' {
        $context = [pscustomobject]@{solutionname='TestSolution1';ruleMode='error'}
        $rule = @{Name='Failure';Mode='error';Path={param($context) $null = $context; Write-Host 'Before failure'; throw 'Deliberate rule failure'}}
        $budget = [System.Threading.SemaphoreSlim]::new(1,1)
        try {
            $caughtError = $null
            try {
                Invoke-AlmValidationRules -Context $context -Rules @($rule) -OperationBudget $budget -LogDirectory $TestDrive -InformationVariable messages
            } catch { $caughtError = $_ }
            $caughtError | Should -Not -BeNullOrEmpty
            $caughtError.Exception.Message | Should -Match 'Deliberate rule failure'
            $budget.CurrentCount | Should -Be 1
            Get-Content (Join-Path $TestDrive 'Failure.log') | Should -Match '^\[TestSolution1\]\[Validate:Failure\]'
            Get-Content (Join-Path $TestDrive 'Failure.log') | Should -Contain '[TestSolution1][Validate:Failure] Before failure'
            $output = @($messages | ForEach-Object { [string]$_ }) -join "`n"
            $output | Should -Match '(?m)^\[TestSolution1\]\[Validate:Failure\].*Deliberate rule failure'
            $output | Should -Not -Match 'Failed; see detailed log'
        } finally { $budget.Dispose() }
    }

    It 'prints queued failure details with a rule prefix on every line' {
        $context = [pscustomobject]@{solutionname='TestSolution1';ruleMode='error'}
        $rule = @{Name='Failure';Path={param($context) $null = $context; throw "First failure detail`nSecond failure detail"}}
        $events = [pscustomobject]@{Queue=[System.Collections.Concurrent.ConcurrentQueue[object]]::new();Signal=[System.Threading.AutoResetEvent]::new($false)}
        try {
            { Invoke-AlmValidationRule -Rule $rule -Context $context -Events $events } | Should -Throw '*First failure detail*'
            @(Write-AlmWorkerEvents -Events $events -InformationVariable messages).Count | Should -Be 0
            $lines = @($messages | ForEach-Object { [string]$_ })
            ($lines -join "`n") | Should -Match 'First failure detail'
            ($lines -join "`n") | Should -Match 'Second failure detail'
            $lines | Should -Not -Contain '[TestSolution1][Validate:Failure] Failed; see detailed log'
            foreach ($line in $lines) { $line | Should -Match '^\[TestSolution1\]\[Validate:Failure\] ' }
        } finally { $events.Signal.Dispose() }
    }

    It 'cancels a blocked slot without releasing an unacquired slot' {
        $budget = [System.Threading.SemaphoreSlim]::new(0,1)
        $cancellation = [System.Threading.CancellationTokenSource]::new()
        $cancellation.Cancel()
        try {
            { Invoke-AlmValidationRules -Context ([pscustomobject]@{solutionname='TestSolution1';ruleMode='error'}) -Rules @(@{Name='Blocked';Mode='error';Path={throw 'Must not run'}}) -OperationBudget $budget -CancellationToken $cancellation.Token } | Should -Throw
            $budget.CurrentCount | Should -Be 0
        } finally { $budget.Dispose(); $cancellation.Dispose() }
    }

    It 'overwrites stale findings with an empty JSON array' {
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -PrecomputedResults @([pscustomobject]@{Message='Old finding';IsWarning=$true}) -LogDirectory $TestDrive -WarningAction SilentlyContinue
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -PrecomputedResults @() -LogDirectory $TestDrive
        (Get-Content (Join-Path $TestDrive 'findings.json') -Raw).Trim() | Should -Be '[]'
    }

    It 'signals tagged status events without adding success-stream output' {
        $events = [pscustomobject]@{Queue=[System.Collections.Concurrent.ConcurrentQueue[object]]::new();Signal=[System.Threading.AutoResetEvent]::new($false)}
        try {
            @(Send-AlmWorkerEvent -Events $events -SolutionName TestSolution1 -Phase Validate -Message 'Started').Count | Should -Be 0
            $events.Signal.WaitOne(0) | Should -BeTrue
            @(Write-AlmWorkerEvents -Events $events -InformationVariable messages).Count | Should -Be 0
            [string]$messages[0] | Should -Be '[TestSolution1][Validate] Started'
            $events.Queue.Count | Should -Be 0
        } finally { $events.Signal.Dispose() }
    }

    It 'preserves whole-rule overrides with missing optional component keys' {
        Mock Get-ChildItem { @([pscustomobject]@{BaseName='Skip';FullName='skip.ps1'},[pscustomobject]@{BaseName='Warn';FullName='warn.ps1'},[pscustomobject]@{BaseName='Default';FullName='default.ps1'}) }
        Mock Invoke-AlmValidationRules { }
        validateSolutionInternal -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -solutionconfig @{skipValidationRules=@(@{ruleName='Skip';mode='skip'},@{ruleName='Warn';mode='warning'})} -ParallelRules -MaxParallel 4
        Should -Invoke Invoke-AlmValidationRules -Exactly -Times 1 -ParameterFilter { $Parallel -and $MaxParallel -eq 4 -and $Rules.Count -eq 2 -and $Rules[0].Name -eq 'Warn' -and $Rules[0].Mode -eq 'warning' -and $Rules[1].Mode -eq 'error' }
    }

    It 'retains completed worker output during failure cleanup' {
        $job = Start-ThreadJob -ScriptBlock { Write-Host 'Worker detail'; [pscustomobject]@{Kind='Export';SolutionName='TestSolution1'} }
        Wait-Job $job | Out-Null
        $job | Add-Member -NotePropertyName AlmSolutionName -NotePropertyValue TestSolution1
        $job | Add-Member -NotePropertyName AlmPhase -NotePropertyValue 'Export:Managed'
        $state = @{
            Jobs = @($job)
            Clients = @()
            Cancellation = [System.Threading.CancellationTokenSource]::new()
            OperationBudget = [System.Threading.SemaphoreSlim]::new(1,1)
            LogEvents = [pscustomobject]@{Queue=[System.Collections.Concurrent.ConcurrentQueue[object]]::new();Signal=[System.Threading.AutoResetEvent]::new($false)}
            LogDirectory = $TestDrive
            WorkDirectory = Join-Path $TestDrive 'disposable-worker-folder'
            Timings = [System.Collections.Generic.List[object]]::new()
        }
        New-Item -ItemType Directory -Path $state.WorkDirectory | Out-Null
        Stop-AlmExportPipeline -State $state
        $state.Timings.Count | Should -Be 1
        Get-Content (Join-Path $TestDrive 'TestSolution1-Export-Managed.log') | Should -Contain '[TestSolution1][Export:Managed] Worker detail'
        @(Get-Job -Id $job.Id -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Export validation lookup caching' {
    BeforeEach {
        $script:componentDefinitionCache = @{}
        $script:componentNameCache = @{}
    }

    It 'queries repeated keys once and returns independent records' {
        Mock Invoke-DataverseSQL { [pscustomobject]@{ ComponentId = 'component'; Name = 'original' } }
        $cache = @{}
        $first = Invoke-CachedValidationQuery -Cache $cache -Key component -Sql query -Parameters @{}
        $first.Name = 'changed'
        $first | Add-Member -NotePropertyName DependentName -NotePropertyValue first
        $second = Invoke-CachedValidationQuery -Cache $cache -Key component -Sql query -Parameters @{}
        $second.Name | Should -Be original
        $second.PSObject.Properties.Name | Should -Not -Contain DependentName
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 1
    }

    It 'caches empty query results and separates lookup keys' {
        Mock Invoke-DataverseSQL { }
        $cache = @{}
        @(Invoke-CachedValidationQuery -Cache $cache -Key first -Sql query -Parameters @{}).Count | Should -Be 0
        @(Invoke-CachedValidationQuery -Cache $cache -Key first -Sql query -Parameters @{}).Count | Should -Be 0
        @(Invoke-CachedValidationQuery -Cache $cache -Key second -Sql query -Parameters @{}).Count | Should -Be 0
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 2
    }

    It 'does not cache failed queries' {
        Mock Invoke-DataverseSQL { throw 'query failed' }
        $cache = @{}
        { Invoke-CachedValidationQuery -Cache $cache -Key first -Sql query -Parameters @{} } | Should -Throw 'query failed'
        $cache.ContainsKey('first') | Should -BeFalse
    }

    It 'caches component names across solution IDs' {
        Mock Get-DataverseRecord { [pscustomobject]@{ name = 'new_resource'; displayname = 'Resource' } }
        (getComponentNames -componentId component -componentType 61 -solutionId first).ComponentSchemaName | Should -Be new_resource
        (getComponentNames -componentId component -componentType 61 -solutionId second).ComponentDisplayName | Should -Be Resource
        Should -Invoke Get-DataverseRecord -Exactly -Times 1
    }

    It 'caches successful missing component lookups' {
        Mock Get-DataverseRecord { }
        getComponentNames -componentId missing -componentType 61 | Should -BeNullOrEmpty
        getComponentNames -componentId missing -componentType 61 | Should -BeNullOrEmpty
        Should -Invoke Get-DataverseRecord -Exactly -Times 1
    }

    It 'shares names through a context and isolates subsequent contexts' {
        Mock Get-DataverseRecord { [pscustomobject]@{ name = 'new_resource'; displayname = 'Resource' } }
        $firstContext = [pscustomobject]@{}
        $secondContext = [pscustomobject]@{}
        getComponentNames -componentId component -componentType 61 -ValidationContext $firstContext | Out-Null
        $script:componentNameCache = @{}
        getComponentNames -componentId component -componentType 61 -ValidationContext $firstContext | Out-Null
        getComponentNames -componentId component -componentType 61 -ValidationContext $secondContext | Out-Null
        Should -Invoke Get-DataverseRecord -Exactly -Times 2
    }

    It 'resets component caches for every validation invocation' {
        Mock Get-ChildItem { }
        $script:componentDefinitionCache[61] = @{}
        $script:componentNameCache['61/component'] = 'stale'
        validateSolutionInternal -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @()
        $script:componentDefinitionCache.Count | Should -Be 0
        $script:componentNameCache.Count | Should -Be 0
    }

    It 'accepts validation without solution ZIP parameters' {
        Mock validateSolutionInternal { }
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @()
        Should -Invoke validateSolutionInternal -Exactly -Times 1
    }

    It 'reuses empty precomputed results without repeating validation' {
        Mock validateSolutionInternal { throw 'Unexpected repeated validation' }
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -PrecomputedResults @()
        Should -Invoke validateSolutionInternal -Exactly -Times 0
    }

    It 'preserves error reporting for precomputed findings' {
        Mock validateSolutionInternal { throw 'Unexpected repeated validation' }
        { validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -PrecomputedResults @([pscustomobject]@{Message='Expected finding';IsWarning=$false}) -ErrorAction Stop } | Should -Throw '*Expected finding*'
        Should -Invoke validateSolutionInternal -Exactly -Times 0
    }

    It 'preserves warning mode for precomputed errors' {
        Mock validateSolutionInternal { throw 'Unexpected repeated validation' }
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -solutionconfig @{validationMode='warning'} -PrecomputedResults @([pscustomobject]@{Message='Expected warning';IsWarning=$false}) -WarningVariable findings -WarningAction SilentlyContinue
        @($findings).Count | Should -Be 1
        Should -Invoke validateSolutionInternal -Exactly -Times 0
    }

    It 'passes configured later solutions into validation' {
        Mock validateSolutionInternal { }
        validateSolution -solutionname TestSolution1 -validdependencysolutionnames @() -ignoresolutionnames @() -LaterSolutionNames @('LaterDependency')
        Should -Invoke validateSolutionInternal -Exactly -Times 1 -ParameterFilter { $LaterSolutionNames -contains 'LaterDependency' }
    }
}

Describe 'Repeated dependency validation' {
    BeforeEach {
        $ruleContext = [pscustomobject]@{
            solutionname = 'TestSolution1'
            validdependencysolutionnames = @()
            ignoresolutionnames = @()
            solutionconfig = @{}
            validationMode = 'error'
            laterSolutionNames = @()
            ruleMode = 'error'
        }
        Mock getComponentNames {
            [pscustomobject]@{ ComponentSchemaName = $componentId; ComponentDisplayName = $componentId }
        }
        Mock Get-ValidationRuleDocLink { 'rule.md' }
        Mock Invoke-DataverseSQL {
            if ($Sql -match 'SELECT solutionid FROM solution') {
                [pscustomobject]@{ solutionid = '00000000-0000-0000-0000-000000000001' }
            } elseif ($Sql -match 'FROM dependency dep') {
                foreach ($dependentId in @('first', 'second')) {
                    [pscustomobject]@{
                        requiredcomponentobjectid = 'shared'
                        requiredcomponenttype = 61
                        requiredcomponentparentid = $null
                        requiredcomponentbasesolutionid = $null
                        dependentcomponentobjectid = $dependentId
                        dependentcomponenttype = 61
                    }
                }
            } elseif ($Sql -match 'WHERE sc.objectid = @requiredComponentId') {
                [pscustomobject]@{
                    SolutionName = 'OtherSolution'
                    SolutionId = '00000000-0000-0000-0000-000000000002'
                    Managed = $false
                    ComponentId = 'shared'
                    ComponentType = 61
                    Behaviour = 'ShellAndMetadata'
                }
            } elseif ($Sql -notmatch 'LEFT JOIN solutioncomponent') {
                throw "Unexpected query: $Sql"
            }
        }
    }

    It 'queries shared membership once without overwriting earlier dependency details' {
        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)
        $findings.Count | Should -Be 1
        $findings[0].Message | Should -Match 'DependentComponentSchemaName\s+: first'
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 1 -ParameterFilter { $Sql -match 'WHERE sc.objectid = @requiredComponentId' }
    }

    It 'does not reuse membership results across validation runs' {
        & "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext | Out-Null
        & "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext | Out-Null
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 2 -ParameterFilter { $Sql -match 'WHERE sc.objectid = @requiredComponentId' }
    }

    It 'queries a shared authoritative base solution once' {
        Mock Invoke-DataverseSQL {
            foreach ($dependentId in @('first', 'second')) {
                [pscustomobject]@{
                    requiredcomponentobjectid = 'shared'
                    requiredcomponenttype = 61
                    requiredcomponentparentid = $null
                    requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000002'
                    dependentcomponentobjectid = $dependentId
                    dependentcomponenttype = 61
                }
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{ SolutionName = 'OtherSolution'; SolutionId = '00000000-0000-0000-0000-000000000002'; Managed = $false }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)
        $findings.Count | Should -Be 1
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 1 -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
    }

    It 'reports Active-based table dependencies when the table is shell and metadata only' {
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                requiredcomponentobjectid = 'active-component'
                requiredcomponenttype = 1
                requiredcomponentparentid = $null
                requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000003'
                dependentcomponentobjectid = 'dependent-entity'
                dependentcomponenttype = 1
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'Active'
                SolutionId = '00000000-0000-0000-0000-000000000003'
                Managed = $false
            }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        Mock Invoke-DataverseSQL { } -ParameterFilter { $Sql -match 's.solutionid <> @solutionId' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{ RootComponentBehavior = 1 }
        } -ParameterFilter { $Sql -match 'SELECT TOP 1 sc.rootcomponentbehavior AS RootComponentBehavior' }

        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)

        $findings.Count | Should -Be 1
        $findings[0].Message | Should -Match 'depends on solution <Not in any solution>'
        $findings[0].Message | Should -Not -Match 'SolutionName\s+:\s+Active'
    }

    It 'does not report Active-based table dependencies when the table includes all objects' {
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                requiredcomponentobjectid = 'active-component'
                requiredcomponenttype = 1
                requiredcomponentparentid = $null
                requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000003'
                dependentcomponentobjectid = 'dependent-entity'
                dependentcomponenttype = 1
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'Active'
                SolutionId = '00000000-0000-0000-0000-000000000003'
                Managed = $false
            }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        Mock Invoke-DataverseSQL { } -ParameterFilter { $Sql -match 's.solutionid <> @solutionId' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{ RootComponentBehavior = 0 }
        } -ParameterFilter { $Sql -match 'SELECT TOP 1 sc.rootcomponentbehavior AS RootComponentBehavior' }

        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)

        $findings | Should -BeNullOrEmpty
    }

    It 'does not query table behavior for non-table Active dependencies' {
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                requiredcomponentobjectid = 'active-component'
                requiredcomponenttype = 2
                requiredcomponentparentid = $null
                requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000003'
                dependentcomponentobjectid = 'dependent-attribute'
                dependentcomponenttype = 2
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'Active'
                SolutionId = '00000000-0000-0000-0000-000000000003'
                Managed = $false
            }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        Mock Invoke-DataverseSQL { } -ParameterFilter { $Sql -match 's.solutionid <> @solutionId' }

        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)

        $findings | Should -BeNullOrEmpty
        Should -Invoke Invoke-DataverseSQL -Exactly -Times 0 -ParameterFilter { $Sql -match 'SELECT TOP 1 sc.rootcomponentbehavior AS RootComponentBehavior' }
    }

    It 'resolves Active-based attribute dependencies to the solution containing the attribute' {
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                requiredcomponentobjectid = 'shared-name-attribute'
                requiredcomponenttype = 2
                requiredcomponentparentid = 'shared-table'
                requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000003'
                dependentcomponentobjectid = 'shared-relationship'
                dependentcomponenttype = 10
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'Active'
                SolutionId = '00000000-0000-0000-0000-000000000003'
                Managed = $false
            }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'DependencySolution'
                SolutionId = '00000000-0000-0000-0000-000000000004'
                Managed = $false
                ComponentId = 'shared-name-attribute'
                ComponentType = 2
                Behaviour = 'IncludeSubcomponents'
            }
        } -ParameterFilter { $Sql -match 's.solutionid <> @solutionId' }

        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)

        $findings.Count | Should -Be 1
        $findings[0].Message | Should -Match 'depends on solution DependencySolution'
        $findings[0].Message | Should -Not -Match 'solution Active'
        $findings[0].Message | Should -Not -Match 'configured after'
        $ruleContext.laterSolutionNames = @('DependencySolution')
        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)
        $findings[0].Message | Should -Match "DependencySolution.*configured later in the solution order"
        $findings[0].Message | Should -Match 'cannot depend on components in a solution that appears later in the order'
        $findings[0].Message | Should -Not -Match 'Move it before'
    }

    It 'does not report Active-based components in an allowed dependency solution' {
        $ruleContext.validdependencysolutionnames = @('DependencySolution')
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                requiredcomponentobjectid = 'shared-name-attribute'
                requiredcomponenttype = 2
                requiredcomponentparentid = 'shared-table'
                requiredcomponentbasesolutionid = '00000000-0000-0000-0000-000000000003'
                dependentcomponentobjectid = 'shared-relationship'
                dependentcomponenttype = 10
            }
        } -ParameterFilter { $Sql -match 'FROM dependency dep' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'Active'
                SolutionId = '00000000-0000-0000-0000-000000000003'
                Managed = $false
            }
        } -ParameterFilter { $Sql -match 'WHERE s.solutionid = @requiredBaseSolutionId' }
        Mock Invoke-DataverseSQL {
            [pscustomobject]@{
                SolutionName = 'DependencySolution'
                SolutionId = '00000000-0000-0000-0000-000000000004'
                Managed = $false
                ComponentId = 'shared-name-attribute'
                ComponentType = 2
                Behaviour = 'IncludeSubcomponents'
            }
        } -ParameterFilter { $Sql -match 's.solutionid <> @solutionId' }

        $findings = @(& "$PSScriptRoot/../../validationrules/DependencyOnSolutionNotAllowed.ps1" $ruleContext)

        $findings | Should -BeNullOrEmpty
    }
}