. "$PSScriptRoot/validation-workers.ps1"

function Invoke-CachedValidationQuery {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    if (-not $Cache.ContainsKey($Key)) {
        $Cache[$Key] = @(Invoke-DataverseSQL -Sql $Sql -Parameters $Parameters)
    }

    $Cache[$Key] | Select-Object -Property *
}

# Helper function to load component names using PowerShell cmdlets
function getComponentNames(
    [Parameter(Mandatory)][string] $componentId,
    [Parameter(Mandatory)][int] $componentType,
    [Parameter()][string] $solutionId,
    [Parameter()][psobject]$ValidationContext
) {
    
    # Cache for component definitions to avoid repeated lookups
    if (-not (Test-Path variable:script:componentDefinitionCache)) {
        Set-Variable -Scope Script -Name componentDefinitionCache -Value @{}
    }

    if (-not (Test-Path variable:script:componentNameCache)) {
        Set-Variable -Scope Script -Name componentNameCache -Value @{}
    }
    $definitionCache = $script:componentDefinitionCache
    $nameCache = $script:componentNameCache
    if ($null -ne $ValidationContext) {
        if (-not $ValidationContext.PSObject.Properties['ComponentDefinitionCache']) {
            $ValidationContext | Add-Member -NotePropertyName ComponentDefinitionCache -NotePropertyValue @{}
        }
        if (-not $ValidationContext.PSObject.Properties['ComponentNameCache']) {
            $ValidationContext | Add-Member -NotePropertyName ComponentNameCache -NotePropertyValue @{}
        }
        $definitionCache = $ValidationContext.ComponentDefinitionCache
        $nameCache = $ValidationContext.ComponentNameCache
    }
    $componentKey = "$componentType/$componentId"
    if ($nameCache.ContainsKey($componentKey)) {
        return $nameCache[$componentKey]
    }
    
    # Determine the table name and column names based on component type
    $tablename = $null
    $schemanamecolumn = $null
    $displaynamecolumn = $null
    
    # Try to get from cache first
    if ($definitionCache.ContainsKey($componentType)) {
        $cached = $definitionCache[$componentType]
        $tablename = $cached.TableName
        $schemanamecolumn = $cached.SchemaNameColumn
        $displaynamecolumn = $cached.DisplayNameColumn
    }
    else {
        # Common mappings for well-known component types (use metadata to get name columns)
        $wellKnownTables = @{
            1 = "entity"
            2 = "attribute"
            10 = "entityrelationship"
            14 = "entitykey"
            20 = "role"
            26 = "savedquery"
            29 = "workflow"
            31 = "report"
            60 = "systemform"
            61 = "webresource"
            62 = "sitemap"
            66 = "customcontrol"
            80 = "sdkmessageprocessingstep"
            90 = "plugintype"
            91 = "pluginassembly"
            92 = "sdkmessageprocessingstepimage"
            300 = "canvasapp"
            380 = "environmentvariabledefinition"
            381 = "environmentvariablevalue"
        }
        
        if ($wellKnownTables.ContainsKey($componentType)) {
            $tablename = $wellKnownTables[$componentType]
        }
        else {
            # Try to look up the component definition dynamically for non-standard types
            try {
                Write-Verbose "Looking up component definition for type $componentType"
                
                # Use SQL to query solutioncomponentdefinition
                $defSql = "SELECT primaryentityname FROM solutioncomponentdefinition WHERE solutioncomponenttype = @componentType"
                $defResult = Invoke-DataverseSQL -Sql $defSql -Parameters @{componentType = $componentType}
                
                if ($defResult -and $defResult.Length -gt 0 -and $defResult[0].primaryentityname) {
                    $tablename = $defResult[0].primaryentityname
                }
            }
            catch {
                Write-Verbose "Could not look up component definition for type $componentType : $_"
            }
        }
        
        # If we have a table name, get metadata to find the name columns
        if ($tablename) {
            try {
                # Special cases for tables with specific name/display name columns
                $specialCases = @{
                    'sitemap' = @{Schema = 'sitemapname'; Display = 'sitemapname'}
                    'webresource' = @{Schema = 'name'; Display = 'displayname'}
                    'canvasapp' = @{Schema = 'name'; Display = 'displayname'}
                    'environmentvariabledefinition' = @{Schema = 'schemaname'; Display = 'displayname'}
                }
                
                if ($specialCases.ContainsKey($tablename)) {
                    $schemanamecolumn = $specialCases[$tablename].Schema
                    $displaynamecolumn = $specialCases[$tablename].Display
                    Write-Verbose "Using special case for $tablename : SchemaColumn=$schemanamecolumn, DisplayColumn=$displaynamecolumn"
                }
                else {
                    # Get entity metadata to find the primary name attribute using shared cache
                    $entityMetadata = Get-DataverseEntityMetadata -EntityName $tablename -UseMetadataCache -ExcludeAttributes -ExcludeRelationships -ExcludePrivileges
                    
                    if ($entityMetadata -and $entityMetadata.PrimaryNameAttribute) {
                        # Use PrimaryNameAttribute from metadata as both schema and display name column
                        $schemanamecolumn = $entityMetadata.PrimaryNameAttribute
                        $displaynamecolumn = $schemanamecolumn
                        
                        Write-Verbose "Found component definition: Type=$componentType, Table=$tablename, SchemaColumn=$schemanamecolumn, DisplayColumn=$displaynamecolumn"
                    }
                    else {
                        Write-Verbose "Could not get entity metadata for table $tablename or no PrimaryNameAttribute found"
                    }
                }
            }
            catch {
                Write-Verbose "Error getting metadata for table $tablename : $_"
            }
        }
        
        # Cache the result (even if null)
        $definitionCache[$componentType] = @{
            TableName = $tablename
            SchemaNameColumn = $schemanamecolumn
            DisplayNameColumn = $displaynamecolumn
        }
    }
    
    if (-not $tablename) {
        Write-Verbose "No table name determined for component type $componentType"
        return $null
    }
    
    try {
        # Query the component by ID using cmdlet
        $idColumn = $tablename + "id"
        $columns = @($schemanamecolumn)
        if ($displaynamecolumn -and $displaynamecolumn -ne $schemanamecolumn) {
            $columns += $displaynamecolumn
        }
        
        $record = Get-DataverseRecord -TableName $tablename -Id $componentId -Columns $columns -Top 1
        
        if ($record) {
            $schemaName = $null
            $displayName = $null
            
            if ($record.PSObject.Properties.Name -contains $schemanamecolumn) {
                $schemaName = $record.$schemanamecolumn
            }
            
            if ($displaynamecolumn -and ($record.PSObject.Properties.Name -contains $displaynamecolumn)) {
                $displayName = $record.$displaynamecolumn
            }
            
            # Special handling for attributes and entities to get UserLocalizedLabel
            if ($componentType -eq 2 -and $schemaName) {
                # For attributes, get the display name from metadata using RetrieveAttributeRequest
                try {
                    $conn = Get-DataverseConnection -GetDefault
                    $request = New-Object Microsoft.Xrm.Sdk.Messages.RetrieveAttributeRequest
                    $request.MetadataId = [Guid]$componentId
                    $request.RetrieveAsIfPublished = $true
                    
                    $response = $conn.Execute($request)
                    if ($response.AttributeMetadata -and $response.AttributeMetadata.DisplayName.UserLocalizedLabel) {
                        $displayName = $response.AttributeMetadata.DisplayName.UserLocalizedLabel.Label
                    }
                }
                catch {
                    Write-Verbose "Could not get attribute display name from metadata: $_"
                }
            }
            elseif ($componentType -eq 1 -and $schemaName) {
                # For entities, get the display name from metadata
                try {
                    $entityMeta = Get-DataverseEntityMetadata -EntityName $schemaName -UseMetadataCache -ExcludeAttributes -ExcludeRelationships -ExcludePrivileges
                    if ($entityMeta -and $entityMeta.DisplayName.UserLocalizedLabel) {
                        $displayName = $entityMeta.DisplayName.UserLocalizedLabel.Label
                    }
                }
                catch {
                    Write-Verbose "Could not get entity display name from metadata: $_"
                }
            }
            
            $names = [PSCustomObject]@{
                ComponentSchemaName = $schemaName
                ComponentDisplayName = $displayName
            }
            $nameCache[$componentKey] = $names
            return $names
        }
        
        Write-Verbose "Component not found: ComponentId=$componentId, ComponentType=$componentType, Table=$tablename"
        $nameCache[$componentKey] = $null
        return $null
        
    } catch {
        Write-Warning "Error retrieving component names for ComponentId=$componentId, ComponentType=$componentType, Table=$tablename : $_"
        return $null
    }
}

# Function to detect Git platform and build documentation link
function Get-ValidationRuleDocLink([string]$ruleType) {
    $docRelativePath = "ttec-digital/validationrules/$ruleType.md"
    
    # Try to get the git remote URL
    try {
        $gitRemote = git remote get-url origin 2>$null
        
        if ($gitRemote) {
            # Detect Azure DevOps
            if ($gitRemote -match "dev\.azure\.com" -or $gitRemote -match "visualstudio\.com") {
                # Azure DevOps URL patterns:
                # https://dev.azure.com/{org}/{project}/_git/{repo}
                # https://{org}.visualstudio.com/{project}/_git/{repo}
                # git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
                
                if ($gitRemote -match "dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)") {
                    $org = $matches[1]
                    $project = $matches[2]
                    $repo = $matches[3] -replace '\.git$', ''
                    
                    # Get current branch
                    $branch = git rev-parse --abbrev-ref HEAD 2>$null
                    if (-not $branch) { $branch = "main" }
                    
                    return "https://dev.azure.com/$org/$project/_git/$repo`?path=/$docRelativePath&version=GB$branch"
                }
                elseif ($gitRemote -match "([^@]+)\.visualstudio\.com/([^/]+)/_git/([^/]+)") {
                    $org = $matches[1]
                    $project = $matches[2]
                    $repo = $matches[3] -replace '\.git$', ''
                    
                    $branch = git rev-parse --abbrev-ref HEAD 2>$null
                    if (-not $branch) { $branch = "main" }
                    
                    return "https://$org.visualstudio.com/$project/_git/$repo`?path=/$docRelativePath&version=GB$branch"
                }
                elseif ($gitRemote -match "ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/([^/]+)") {
                    $org = $matches[1]
                    $project = $matches[2]
                    $repo = $matches[3] -replace '\.git$', ''
                    
                    $branch = git rev-parse --abbrev-ref HEAD 2>$null
                    if (-not $branch) { $branch = "main" }
                    
                    return "https://dev.azure.com/$org/$project/_git/$repo`?path=/$docRelativePath&version=GB$branch"
                }
            }
            # Detect GitHub
            elseif ($gitRemote -match "github\.com") {
                # GitHub URL patterns:
                # https://github.com/{owner}/{repo}.git
                # git@github.com:{owner}/{repo}.git
                
                if ($gitRemote -match "github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$") {
                    $owner = $matches[1]
                    $repo = $matches[2] -replace '\.git$', ''
                    
                    # Get current branch
                    $branch = git rev-parse --abbrev-ref HEAD 2>$null
                    if (-not $branch) { $branch = "main" }
                    
                    return "https://github.com/$owner/$repo/blob/$branch/$docRelativePath"
                }
            }
        }
    }
    catch {
        Write-Verbose "Could not detect git remote: $_"
    }
    
    # Fallback: return just the relative path
    return $docRelativePath
}

function validateSolution(
    #Solution name to validate
    [Parameter(Mandatory)][string] $solutionname,
    #List of solution names this solution is allowed to depend on
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$validdependencysolutionnames,
    [Parameter()][string] $outputpath,
    [Parameter()][string] $solutionfile,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ignoresolutionnames,
    #Solution configuration from alm-config.psd1
    [Parameter()][hashtable]$solutionconfig = @{},
    [Parameter()][AllowEmptyCollection()][object[]]$PrecomputedResults,
    [hashtable]$ValidationSettings = @{ parallel = $true; maxParallel = 4 },
    [string]$LogDirectory = '',
    [hashtable]$SummaryStore = @{},
    [System.Threading.SemaphoreSlim]$OperationBudget,
    [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
    [Parameter()][AllowEmptyCollection()][string[]]$LaterSolutionNames = @()
) {

<#
    #Standard Solution Checker

    $resultsfolder = "$([IO.Path]::GetTempPath())/$([IO.Path]::GetRandomFileName())/$solutionname.results"
 
    try {

        new-item -itemtype Directory $resultsfolder | out-null
        pac solution check --path $solutionfile -o $resultsfolder

        if (-not $? -or $LASTEXITCODE -ne 0) {
            throw "PAC SOLUTION CHECK failed"
        }

        $resultszip = resolve-path "$resultsfolder/*.zip"
        add-type -assembly System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($resultszip, $outputpath)

    }
    finally {
        if (test-path $resultsfolder) {
            remove-item -recurse -force $resultsfolder
        }
    }
#>

    # Custom Rules
    $validationClock = [System.Diagnostics.Stopwatch]::StartNew()
    $ruleTimings = [System.Collections.Generic.List[object]]::new()
    $SummaryStore[$solutionname] = [pscustomobject]@{ Status = 'Failed'; Errors = 0; Warnings = 0; Seconds = $null; Rules = @() }

    # Determine the effective validation mode for this solution
    $validationMode = 'error'  # default
    if ($solutionconfig.ContainsKey("validationMode") -and $solutionconfig.validationMode) {
        $validationMode = $solutionconfig.validationMode.ToLower()
    }

    # Check if validation is completely disabled for this solution
    if ($validationMode -eq 'disabled') {
        $SummaryStore[$solutionname].Status = 'Disabled'
        $warning = "[$solutionname][Validate] Validation disabled by configuration"
        Write-Warning $warning
        if ($env:TF_BUILD) {
            write-host "##vso[task.logissue type=warning]$warning"
        }
        return
    }

    # Display info if in warning mode
    if ($validationMode -eq 'warning') {
        Write-Host "[$solutionname][Validate] Warning mode; findings will not fail the pipeline"
    }

    $errors = @()
    $warnings = @()

    $results = if ($PSBoundParameters.ContainsKey('PrecomputedResults')) {
        $PrecomputedResults
    } else {
        validateSolutionInternal `
            -solutionname $solutionname `
            -validdependencysolutionnames:$validdependencysolutionnames `
            -ignoresolutionnames:$ignoresolutionnames `
            -solutionconfig:$solutionconfig `
            -validationMode:$validationMode -ParallelRules:$ValidationSettings.parallel -MaxParallel $ValidationSettings.maxParallel `
            -LogDirectory $LogDirectory -RuleTimings $ruleTimings -OperationBudget $OperationBudget -CancellationToken $CancellationToken `
            -LaterSolutionNames $LaterSolutionNames
    }
    $results | foreach-object {
        # Results from validation rules are objects with Message and IsWarning properties
        if ($_.IsWarning) {
            $warnings += $_.Message
        } else {
            $errors += $_.Message
        }
    }

    # In warning mode, treat all errors as warnings
    if ($validationMode -eq 'warning') {
        $warnings += $errors
        $errors = @()
    }

    # In warning mode, treat all errors as warnings
    if ($validationMode -eq 'warning') {
        $warnings += $errors
        $errors = @()
    }

    # Output warnings
    $validationClock.Stop()
    $SummaryStore[$solutionname] = [pscustomobject]@{
        Status = $(if ($errors.Length) { 'Failed' } else { 'Passed' })
        Errors = $errors.Length
        Warnings = $warnings.Length
        Seconds = $(if ($PSBoundParameters.ContainsKey('PrecomputedResults')) { $null } else { $validationClock.Elapsed.TotalSeconds })
        Rules = $ruleTimings.ToArray()
    }
    if ($LogDirectory) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        ConvertTo-Json -InputObject @($results) -Depth 8 | Set-Content -LiteralPath (Join-Path $LogDirectory 'findings.json') -Encoding utf8
    }
    $warnings = @(foreach ($message in $warnings) { (Format-AlmLogLine -SolutionName $solutionname -Phase Validate -Text $message) -join "`r`n" })
    $errors = @(foreach ($message in $errors) { (Format-AlmLogLine -SolutionName $solutionname -Phase Validate -Text $message) -join "`r`n" })
    if ($warnings.Length) {
        if ($env:TF_BUILD) {
            $warnings | foreach-object { write-host "##vso[task.logissue type=warning]$_`r`n" }
        }
        else {
            (@($warnings) -join "`r`n`r`n") | Write-Warning
        }
    }

    # Output errors
    if ($errors.Length) {
        if ($env:TF_BUILD) {
            $errors | foreach-object { write-host "##vso[task.logissue type=error]$_`r`n" }
            throw "Solution validation errors"
        }
        else {
            (@($errors) -join "`r`n`r`n") | write-error
        }

    }
}

function writeResult([Parameter(Mandatory)]$type, [Parameter(Mandatory)] $message, [Parameter(Mandatory)] $componentid, [Parameter()][bool]$asWarning = $false) {
    $docLink = Get-ValidationRuleDocLink -ruleType $type
    $fullMessage = "[$type : $componentid] $message`r`nDocumentation: $docLink"
    
    # Return structured output for the validation system to process
    return [PSCustomObject]@{
        Message = $fullMessage
        IsWarning = $asWarning
    }
}

# Helper function to check validation rule configuration for a component
# Returns: 'skip', 'warning', or 'error' (default)
function getValidationRuleMode(
    [Parameter(Mandatory)][string]$ruleName,
    [Parameter(Mandatory)][string]$componentId,
    [Parameter()][int]$componentType,
    [Parameter()][string]$componentSchemaName,
    [Parameter()][hashtable]$solutionconfig
) {
    if (-not ($solutionconfig.ContainsKey("skipValidationRules") -and $solutionconfig.skipValidationRules)) {
        return 'error'
    }
    
    foreach ($skipConfig in $solutionconfig.skipValidationRules) {
        if ($skipConfig.ruleName -ne $ruleName) {
            continue
        }
        
        # Determine the mode for this configuration
        $mode = 'error'  # default
        if ($skipConfig.ContainsKey('mode') -and $skipConfig.mode) {
            $mode = $skipConfig.mode.ToLower()
        }
        
        # If only ruleName is specified (no component filters), it was already handled at the rule level
        # This function handles component-specific configurations
        
        # Check componentId match
        if ($skipConfig.ContainsKey('componentId') -and $skipConfig.componentId) {
            if ($skipConfig.componentId.ToString() -eq $componentId.ToString()) {
                Write-Verbose "Applying mode '$mode' for rule '$ruleName' on component ID '$componentId' (configured in alm-config.psd1)"
                return $mode
            }
            continue  # componentId specified but didn't match, check next config
        }
        
        # Check componentType match
        if ($skipConfig.ContainsKey('componentType') -and $skipConfig.componentType) {
            if ($skipConfig.componentType -eq $componentType) {
                Write-Verbose "Applying mode '$mode' for rule '$ruleName' on component type '$componentType' (configured in alm-config.psd1)"
                return $mode
            }
            continue  # componentType specified but didn't match, check next config
        }
        
        # Check componentSchemaName match
        if ($skipConfig.ContainsKey('componentSchemaName') -and $skipConfig.componentSchemaName -and $componentSchemaName) {
            if ($skipConfig.componentSchemaName -eq $componentSchemaName) {
                Write-Verbose "Applying mode '$mode' for rule '$ruleName' on component schema name '$componentSchemaName' (configured in alm-config.psd1)"
                return $mode
            }
            continue  # componentSchemaName specified but didn't match, check next config
        }
    }
    
    return 'error'
}

# Validates solution using custom rules
function validateSolutionInternal(
    #Solution name to validate
    [Parameter(Mandatory)][string] $solutionname,
    #List of solution names this solution is allowed to depend on
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$validdependencysolutionnames,
    #List of solutions that will be ignored as though they don't exist at all
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ignoresolutionnames,
    #Solution configuration from alm-config.psd1
    [Parameter()][hashtable]$solutionconfig = @{},
    #Validation mode: 'error' or 'warning'
    [Parameter()][string]$validationMode = 'error',
    [switch]$ParallelRules,
    [ValidateRange(1, 8)][int]$MaxParallel = 4,
    [System.Threading.SemaphoreSlim]$OperationBudget,
    [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None,
    $LogEvents,
    [string]$LogDirectory = '',
    [System.Collections.Generic.List[object]]$RuleTimings,
    [Parameter()][AllowEmptyCollection()][string[]]$LaterSolutionNames = @()
) {   

    $script:componentDefinitionCache = @{}
    $script:componentNameCache = @{}

    Send-AlmWorkerEvent -Events $LogEvents -SolutionName $solutionname -Phase Validate -Message 'Preparing rules'

    $context = [PSCustomObject]@{
        solutionname                 = $solutionname;
        validdependencysolutionnames = $validdependencysolutionnames;
        ignoresolutionnames          = $ignoresolutionnames;
        solutionconfig               = $solutionconfig;
        validationMode               = $validationMode;
        laterSolutionNames           = @($LaterSolutionNames);
        ComponentDefinitionCache     = @{};
        ComponentNameCache           = @{};
        ruleMode                     = 'error';
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    get-childitem $PSScriptRoot/../validationrules -filter *.ps1 | ForEach-Object {
        $ruleName = $_.BaseName
        
        # Check if this rule should be skipped or run in warning mode for this solution
        $ruleMode = 'error'  # default
        $skipRule = $false
        
        if ( $solutionconfig.ContainsKey("skipValidationRules") -and $solutionconfig.skipValidationRules) {
            foreach ($skipConfig in $solutionconfig.skipValidationRules) {
                if ($skipConfig.ruleName -eq $ruleName) {
                    # If no component-specific filters, this applies to the entire rule
                    $hasComponentFilter = @('componentType', 'componentId', 'componentSchemaName') | Where-Object { $skipConfig.ContainsKey($_) -and $skipConfig[$_] }
                    if (-not $hasComponentFilter) {
                        # Determine mode
                        $configMode = 'error'  # default
                        if ($skipConfig.ContainsKey('mode') -and $skipConfig.mode) {
                            $configMode = $skipConfig.mode.ToLower()
                        }
                        
                        if ($configMode -eq 'skip') {
                            $skipRule = $true
                            Send-AlmWorkerEvent -Events $LogEvents -SolutionName $solutionname -Phase "Validate:$ruleName" -Message 'Skipped by configuration'
                            break
                        }
                        elseif ($configMode -eq 'warning') {
                            $ruleMode = 'warning'
                            break
                        }
                    }
                }
            }
        }
        
        if (-not $skipRule) {
            $rules.Add([pscustomobject]@{ Name = $ruleName; Path = $_.FullName; Mode = $ruleMode })
        }
    }
    Invoke-AlmValidationRules -Context $context -Rules $rules.ToArray() -Parallel:$ParallelRules -MaxParallel $MaxParallel `
        -OperationBudget $OperationBudget -CancellationToken $CancellationToken -LogEvents $LogEvents -LogDirectory $LogDirectory -RuleTimings $RuleTimings
}
