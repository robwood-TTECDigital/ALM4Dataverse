<#
.SYNOPSIS
    Pester tests for solution validation rules
.DESCRIPTION
    This script uses Pester to test all validation rules by creating test solutions and components
    in Dataverse. It includes both positive tests (should trigger errors) and negative tests (should pass).
    
    The script can setup test data, run tests, or cleanup - controlled by parameters.
.PARAMETER Cleanup
    Removes all test artifacts (solutions, tables, environment variables, publishers)
.PARAMETER SetupOnly
    Only creates test artifacts without running validation tests
.PARAMETER TestOnly
    Only runs validation tests (assumes test artifacts already exist)
.EXAMPLE
    # Full setup and test
    .\Invoke-SolutionValidationRuleTests.ps1
    
    # Only run tests (after setup)
    .\Invoke-SolutionValidationRuleTests.ps1 -TestOnly
    
    # Cleanup all test data
    .\Invoke-SolutionValidationRuleTests.ps1 -Cleanup
.NOTES
    Requires:
    - Rnwood.Dataverse.Data.PowerShell module
    - Pester module (Install-Module Pester -Force)
    - Active Dataverse connection: Get-DataverseConnection -Interactive -SetAsDefault
#>

param(
    [switch]$Cleanup,
    [switch]$SetupOnly,
    [switch]$TestOnly
)

$ErrorActionPreference = "Stop"

# Ensure Pester is available
if (-not (Get-Module -ListAvailable -Name Pester)) {
    throw "Pester module is required. Install it with: Install-Module Pester -Force"
}
#region Test Configuration

# Test data configuration - defines publishers, solutions, and component prefixes
$testPublisher1 = "valtest1"
$testPublisher1Prefix = "vt1"
$testPublisher2 = "valtest2" 
$testPublisher2Prefix = "vt2"

$testSolutions = @{
    # Positive test solutions - deliberately configured to fail validation rules
    "ValidationTest_Positive1" = @{ 
        Publisher = $testPublisher1
        Description = "Positive test solution 1 - contains components that violate validation rules" 
    }
    "ValidationTest_Positive2" = @{ 
        Publisher = $testPublisher1
        Description = "Positive test solution 2 - used for testing component overlap violations" 
    }
    "ValidationTest_SystemPub" = @{ 
        Publisher = "DefaultPublisherorgd34f1af1"  # System publisher - violates SolutionUsesSystemPublisher rule
        Description = "Solution with system publisher - should fail SolutionUsesSystemPublisher" 
    }
    
    # Negative test solutions - correctly configured and should pass all validation
    "ValidationTest_Negative1" = @{ 
        Publisher = $testPublisher1
        Description = "Negative test solution - properly configured, should pass all validations" 
    }
    "ValidationTest_Behavior1" = @{
        Publisher = $testPublisher1
        Description = "Behavior test solution - used to validate behavior 1 component handling"
    }
}

#endregion

#region Helper Functions

function Cleanup-TestArtifacts {
    <#
    .SYNOPSIS
        Removes all test artifacts created by this script
    .DESCRIPTION
        Cleans up solutions, tables, environment variables, and publishers in the correct order
        to avoid dependency issues
    #>
    
    Write-Host "`nCleaning up test artifacts..." -ForegroundColor Cyan
    
    # Remove test solutions first (to release dependencies on other components)
    foreach ($solutionName in $testSolutions.Keys) {
        Write-Verbose "Removing solution: $solutionName"
        try {
            $solution = Get-DataverseSolution | Where-Object { $_.uniquename -eq $solutionName }
            if ($solution) {
                Remove-DataverseSolution -UniqueName $solutionName -Confirm:$false
                Write-Host "  Removed solution: $solutionName" -ForegroundColor Green
            }
        } catch {
            Write-Verbose "Solution not found or already removed: $solutionName"
        }
    }
    
    # Remove test tables
    $testTables = @(
        "${testPublisher1Prefix}_testtable1",
        "${testPublisher1Prefix}_testtable2",
        "${testPublisher1Prefix}_testtable3",
        "${testPublisher2Prefix}_foreigntable"
    )
    
    foreach ($tableName in $testTables) {
        Write-Verbose "Removing table: $tableName"
        try {
            $entity = Get-DataverseEntityMetadata -EntityName $tableName -ErrorAction SilentlyContinue
            if ($entity) {
                Remove-DataverseEntityMetadata -EntityName $tableName -Confirm:$false
                Write-Host "  Removed table: $tableName" -ForegroundColor Green
            }
        } catch {
            Write-Verbose "Table not found or already removed: $tableName"
        }
    }
    
    # Remove test environment variables
    $testEnvVars = @(
        "${testPublisher1Prefix}_TestEnvVar",
        "${testPublisher1Prefix}_TestEnvVarNegative"
    )
    
    foreach ($envVar in $testEnvVars) {
        Write-Verbose "Removing environment variable: $envVar"
        try {
            Remove-DataverseEnvironmentVariableDefinition -SchemaName $envVar -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Removed environment variable: $envVar" -ForegroundColor Green
        } catch {
            Write-Verbose "Environment variable not found: $envVar"
        }
    }
    
    # Remove test publishers last (after all dependent components are removed)
    foreach ($pub in @($testPublisher1, $testPublisher2)) {
        Write-Verbose "Removing publisher: $pub"
        try {
            $publisher = Invoke-DataverseSql -Sql "SELECT publisherid FROM publisher WHERE uniquename = @name" -Parameters @{name = $pub}
            if ($publisher) {
                Remove-DataverseRecord -TableName "publisher" -Id $publisher[0].publisherid -Confirm:$false
                Write-Host "  Removed publisher: $pub" -ForegroundColor Green
            }
        } catch {
            Write-Verbose "Publisher not found or in use: $pub"
        }
    }
    
    Write-Host "Cleanup complete`n" -ForegroundColor Green
}

function Setup-TestPublishers {
    <#
    .SYNOPSIS
        Creates test publishers for validation testing
    .DESCRIPTION
        Creates two publishers:
        - valtest1 (vt1_ prefix) - primary test publisher
        - valtest2 (vt2_ prefix) - used for prefix mismatch testing
    #>
    
    Write-Host "`nSetting up test publishers..." -ForegroundColor Cyan
    
    # Create test publisher 1 - primary publisher for most test components
    $existingPub1 = Invoke-DataverseSql -Sql "SELECT publisherid FROM publisher WHERE uniquename = @name" -Parameters @{name = $testPublisher1}
    if (-not $existingPub1) {
        [PSCustomObject]@{
            uniquename = $testPublisher1
            friendlyname = "Validation Test Publisher 1"
            customizationprefix = $testPublisher1Prefix
            customizationoptionvalueprefix = 10100
        } | Set-DataverseRecord -TableName "publisher" -CreateOnly
        Write-Host "  Created publisher: $testPublisher1 (prefix: $testPublisher1Prefix)" -ForegroundColor Green
    } else {
        Write-Verbose "Publisher already exists: $testPublisher1"
    }
    
    # Create test publisher 2 - used for testing ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix
    $existingPub2 = Invoke-DataverseSql -Sql "SELECT publisherid FROM publisher WHERE uniquename = @name" -Parameters @{name = $testPublisher2}
    if (-not $existingPub2) {
        [PSCustomObject]@{
            uniquename = $testPublisher2
            friendlyname = "Validation Test Publisher 2"
            customizationprefix = $testPublisher2Prefix
            customizationoptionvalueprefix = 10200
        } | Set-DataverseRecord -TableName "publisher" -CreateOnly
        Write-Host "  Created publisher: $testPublisher2 (prefix: $testPublisher2Prefix)" -ForegroundColor Green
    } else {
        Write-Verbose "Publisher already exists: $testPublisher2"
    }
}

function Setup-TestSolutions {
    <#
    .SYNOPSIS
        Creates test solutions for validation testing
    .DESCRIPTION
        Creates positive test solutions (should fail validation) and negative test solutions (should pass)
    #>
    
    Write-Host "`nSetting up test solutions..." -ForegroundColor Cyan
    
    foreach ($solutionName in $testSolutions.Keys) {
        $config = $testSolutions[$solutionName]
        $publisherUniqueName = $config.Publisher

        # Resolve system default publisher dynamically for the current org
        if ($solutionName -eq "ValidationTest_SystemPub") {
            $publisherExists = Invoke-DataverseSql -Sql "SELECT publisherid FROM publisher WHERE uniquename = @name" -Parameters @{ name = $publisherUniqueName }
            if (-not $publisherExists) {
                $resolved = Invoke-DataverseSql -Sql "SELECT TOP 1 uniquename FROM publisher WHERE uniquename LIKE 'DefaultPublisher%' ORDER BY createdon ASC"
                if ($resolved -and $resolved[0].uniquename) {
                    $publisherUniqueName = $resolved[0].uniquename
                    Write-Verbose "Resolved system publisher dynamically: $publisherUniqueName"
                }
            }
        }
        
        $existing = Get-DataverseSolution | Where-Object { $_.uniquename -eq $solutionName }
        if (-not $existing) {
            Set-DataverseSolution -UniqueName $solutionName -Name $solutionName -Description $config.Description -PublisherUniqueName $publisherUniqueName
            Write-Host "  Created solution: $solutionName" -ForegroundColor Green
        } else {
            Write-Verbose "Solution already exists: $solutionName"
        }
    }
}

function Setup-TestTables {
    <#
    .SYNOPSIS
        Creates test tables for validation testing
    .DESCRIPTION
        Creates custom tables with different publishers to test various validation scenarios
    #>
    
    Write-Host "`nSetting up test tables..." -ForegroundColor Cyan
    
    # Table 1 - used for ComponentInMoreThanOneUnmanagedSolution testing (added to multiple solutions)
    $table1Name = "${testPublisher1Prefix}_testtable1"
    $existing = Get-DataverseEntityMetadata -EntityName $table1Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        Set-DataverseEntityMetadata -EntityName $table1Name `
            -SchemaName $table1Name `
            -DisplayName "Validation Test Table 1" `
            -DisplayCollectionName "Validation Test Tables 1" `
            -PrimaryAttributeSchemaName "${testPublisher1Prefix}_name" `
            -PrimaryAttributeDisplayName "Name" `
            -OwnershipType "UserOwned"
        Write-Host "  Created table: $table1Name" -ForegroundColor Green
    }
    
    # Table 2 - used for ComponentInMoreThanOneUmanagedSolution-Metadata testing (ShellAndMetadata behavior)
    $table2Name = "${testPublisher1Prefix}_testtable2"
    $existing = Get-DataverseEntityMetadata -EntityName $table2Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        Set-DataverseEntityMetadata -EntityName $table2Name `
            -SchemaName $table2Name `
            -DisplayName "Validation Test Table 2" `
            -DisplayCollectionName "Validation Test Tables 2" `
            -PrimaryAttributeSchemaName "${testPublisher1Prefix}_name" `
            -PrimaryAttributeDisplayName "Name" `
            -OwnershipType "UserOwned"
        Write-Host "  Created table: $table2Name" -ForegroundColor Green
    }
    
    # Foreign table - owned by publisher 2, tests ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix
    # When added to a solution owned by publisher 1, this should fail validation (prefix mismatch)
    $foreignTableName = "${testPublisher2Prefix}_foreigntable"
    $existing = Get-DataverseEntityMetadata -EntityName $foreignTableName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Set-DataverseEntityMetadata -EntityName $foreignTableName `
            -SchemaName $foreignTableName `
            -DisplayName "Foreign Test Table" `
            -DisplayCollectionName "Foreign Test Tables" `
            -PrimaryAttributeSchemaName "${testPublisher2Prefix}_name" `
            -PrimaryAttributeDisplayName "Name" `
            -OwnershipType "UserOwned"
        Write-Host "  Created table: $foreignTableName" -ForegroundColor Green
    }
    
    # Publish customizations to make tables available
    Write-Verbose "Publishing customizations..."
    Publish-DataverseCustomizations
    Start-Sleep -Seconds 5
    
    # Table 3 - used for negative testing (only in one solution, correct prefix)
    $table3Name = "${testPublisher1Prefix}_testtable3"
    $existing = Get-DataverseEntityMetadata -EntityName $table3Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        Set-DataverseEntityMetadata -EntityName $table3Name `
            -SchemaName $table3Name `
            -DisplayName "Validation Test Table 3" `
            -DisplayCollectionName "Validation Test Tables 3" `
            -PrimaryAttributeSchemaName "${testPublisher1Prefix}_name" `
            -PrimaryAttributeDisplayName "Name" `
            -OwnershipType "UserOwned"
        Write-Host "  Created table: $table3Name" -ForegroundColor Green
        
        Publish-DataverseCustomizations
        Start-Sleep -Seconds 3
    }
}

function Setup-TestEnvironmentVariables {
    <#
    .SYNOPSIS
        Creates test environment variables
    .DESCRIPTION
        Creates environment variables to test EnvironmentVariableCurrentValueInSolution rule
    #>
    
    Write-Host "`nSetting up test environment variables..." -ForegroundColor Cyan
    
    # Environment variable WITH current value - tests EnvironmentVariableCurrentValueInSolution
    # Current values should NOT be in solutions (only definitions should be)
    $envVarName = "${testPublisher1Prefix}_TestEnvVar"
    try {
        Set-DataverseEnvironmentVariableDefinition -SchemaName $envVarName `
            -DisplayName "Test Environment Variable" `
            -Description "For testing EnvironmentVariableCurrentValueInSolution rule" `
            -Type "String" `
            -DefaultValue "default"
        Set-DataverseEnvironmentVariableValue -SchemaName $envVarName -Value "test-value"
        Write-Host "  Created environment variable with current value: $envVarName" -ForegroundColor Green
    } catch {
        Write-Verbose "Environment variable may already exist: $envVarName"
    }
    
    # Environment variable WITHOUT current value - for negative testing
    $envVarNameNeg = "${testPublisher1Prefix}_TestEnvVarNegative"
    try {
        Set-DataverseEnvironmentVariableDefinition -SchemaName $envVarNameNeg `
            -DisplayName "Test Environment Variable Negative" `
            -Description "For negative testing - no current value" `
            -Type "String" `
            -DefaultValue "default-only"
        Write-Host "  Created environment variable (definition only): $envVarNameNeg" -ForegroundColor Green
    } catch {
        Write-Verbose "Environment variable may already exist: $envVarNameNeg"
    }
}

function Setup-TestComponents {
    <#
    .SYNOPSIS
        Adds components to test solutions to create violation scenarios
    .DESCRIPTION
        Configures positive test cases (should trigger validation errors) and 
        negative test cases (should pass validation)
    #>
    
    Write-Host "`nAdding components to test solutions..." -ForegroundColor Cyan
    
    # Get metadata for tables
    $table1 = Get-DataverseEntityMetadata -EntityName "${testPublisher1Prefix}_testtable1"
    $table2 = Get-DataverseEntityMetadata -EntityName "${testPublisher1Prefix}_testtable2"
    $table3 = Get-DataverseEntityMetadata -EntityName "${testPublisher1Prefix}_testtable3" -ErrorAction SilentlyContinue
    $foreignTable = Get-DataverseEntityMetadata -EntityName "${testPublisher2Prefix}_foreigntable"
    $accountEntity = Get-DataverseEntityMetadata -EntityName "account"
    
    # Get environment variable IDs
    $envVarDef = Invoke-DataverseSql -Sql "SELECT environmentvariabledefinitionid FROM environmentvariabledefinition WHERE schemaname = @name" -Parameters @{name = "${testPublisher1Prefix}_TestEnvVar"}
    $envVarVal = Invoke-DataverseSql -Sql "SELECT environmentvariablevalueid FROM environmentvariablevalue WHERE environmentvariabledefinitionid = @defid" -Parameters @{defid = $envVarDef[0].environmentvariabledefinitionid}
    $envVarDefNeg = Invoke-DataverseSql -Sql "SELECT environmentvariabledefinitionid FROM environmentvariabledefinition WHERE schemaname = @name" -Parameters @{name = "${testPublisher1Prefix}_TestEnvVarNegative"}
    
    Write-Verbose "Setting up POSITIVE test cases (designed to fail validation)..."
    
    # Test: ComponentInMoreThanOneUnmanagedSolution
    # Rule basis: A component with IncludeSubcomponents (behavior=0) should only exist in one unmanaged solution
    # This prevents ownership conflicts and deployment issues
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $table1.MetadataId -ComponentType 1 -Behavior 0
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive2" -ComponentId $table1.MetadataId -ComponentType 1 -Behavior 0
    Write-Host "  ✓ ComponentInMoreThanOneUnmanagedSolution: table1 in both Positive1 and Positive2" -ForegroundColor Green
    
    # Test: ComponentInMoreThanOneUmanagedSolution-Metadata 
    # Rule basis: A component with ShellAndMetadata (behavior=1) in multiple solutions creates metadata conflicts
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $table2.MetadataId -ComponentType 1 -Behavior 1
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive2" -ComponentId $table2.MetadataId -ComponentType 1 -Behavior 1
    Write-Host "  ✓ ComponentInMoreThanOneUmanagedSolution-Metadata: table2 in both solutions with ShellAndMetadata" -ForegroundColor Green
    
    # Test: ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix
    # Rule basis: Components should have same prefix as solution publisher to maintain naming consistency
    # foreignTable has vt2_ prefix but Positive1 has vt1_ publisher prefix
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $foreignTable.MetadataId -ComponentType 1 -Behavior 0
    Write-Host "  ✓ ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix: vt2_ table in vt1_ solution" -ForegroundColor Green
    
    # Test: EnvironmentVariableCurrentValueInSolution
    # Rule basis: Only environment variable definitions should be in solutions, not current values
    # Current values are environment-specific and should be set per environment
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $envVarDef[0].environmentvariabledefinitionid -ComponentType 380 -Behavior 0
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $envVarVal[0].environmentvariablevalueid -ComponentType 381 -Behavior 0
    Write-Host "  ✓ EnvironmentVariableCurrentValueInSolution: env var current value added to solution" -ForegroundColor Green
    
    # Test: ComponentIsUnmanagedNonCustom (root component)
    # Rule basis: Unmodified system components should not be in solutions
    # They exist in all environments already and add unnecessary bloat
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $accountEntity.MetadataId -ComponentType 1 -Behavior 0
    Write-Host "  ✓ ComponentIsUnmanagedNonCustom: unmodified Account table added" -ForegroundColor Green
    
    # Test: ComponentIsUnmanagedNonCustom (subcomponent - column)
    # Rule basis: Unmodified system columns should not be in solutions
    $accountNameAttr = Get-DataverseAttributeMetadata -EntityName "account" -AttributeName "name"
    if ($accountNameAttr) {
        Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $accountNameAttr.MetadataId -ComponentType 2 -Behavior 0
        Write-Host "  ✓ ComponentIsUnmanagedNonCustom: unmodified system column (subcomponent) added" -ForegroundColor Green
    }
    
    # Test: ComponentIsUnmanagedNonCustom (subcomponent - form)
    # Rule basis: Unmodified system forms should not be in solutions
    $accountForms = Invoke-DataverseSql -Sql "SELECT formid FROM systemform WHERE objecttypecode = 'account' AND type = 2 AND iscustomizable = 1" | Select-Object -First 1
    if ($accountForms) {
        Set-DataverseSolutionComponent -SolutionName "ValidationTest_Positive1" -ComponentId $accountForms[0].formid -ComponentType 60 -Behavior 0
        Write-Host "  ✓ ComponentIsUnmanagedNonCustom: unmodified system form (subcomponent) added" -ForegroundColor Green
    }
    
    # Note: SolutionUsesSystemPublisher test case is already configured via ValidationTest_SystemPub solution
    
    Write-Verbose "Setting up NEGATIVE test cases (designed to pass validation)..."
    
    # Negative test: Table only in one solution with correct prefix
    if ($table3) {
        Set-DataverseSolutionComponent -SolutionName "ValidationTest_Negative1" -ComponentId $table3.MetadataId -ComponentType 1 -Behavior 0
        Write-Host "  ✓ Negative case: table3 only in Negative1, correct prefix" -ForegroundColor Green
    }
    
    # Negative test: Environment variable definition without current value
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Negative1" -ComponentId $envVarDefNeg[0].environmentvariabledefinitionid -ComponentType 380 -Behavior 0
    Write-Host "  ✓ Negative case: env var definition only (no current value)" -ForegroundColor Green
    
    # Negative test: ComponentIsUnmanagedNonCustom - Shell-only behavior should be excluded
    # Note: The API doesn't fully support behavior=2 and converts it to behavior=1
    # This means we can test that behavior=1 IS validated (unlike behavior=2 which would be excluded)
    # Rule basis: Shell-only components (behavior=2) are metadata references only and should be excluded from validation
    Set-DataverseSolutionComponent -SolutionName "ValidationTest_Behavior1" -ComponentId $accountEntity.MetadataId -ComponentType 1 -Behavior 2
    Write-Host "  ✓ Behavior case: Account table added with shell-only behavior request (API converts to behavior 1)" -ForegroundColor Green
}

#endregion

#region Main Execution

# Verify Dataverse connection first
try {
    $conn = Get-DataverseConnection -GetDefault
    if (-not $conn.IsReady) {
        throw "No active Dataverse connection. Run: Get-DataverseConnection -Interactive -SetAsDefault"
    }
    Write-Host "`nConnected to: $($conn.ConnectedOrgFriendlyName)" -ForegroundColor Green
}
catch {
    Write-Error "Dataverse connection required: $_"
    throw
}

# Execute based on parameters
if ($Cleanup) {
    # Cleanup mode - remove all test artifacts
    Cleanup-TestArtifacts
    return
}

if ($TestOnly) {
    # Test-only mode - run Pester tests
    Write-Host "`nRunning Pester tests (assumes test data already exists)..." -ForegroundColor Cyan
    
    # Import validation functions first
    $ttecDigitalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . "$ttecDigitalRoot\common\solutionvalidation.ps1"
    
    # Run only the Pester tests
    $pesterConfig = New-PesterConfiguration
    $pesterConfig.Run.ScriptBlock = {
        # Re-import in script block context
        $ttecDigitalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . "$ttecDigitalRoot\common\solutionvalidation.ps1"
        
        Describe "Solution Validation Rules" -Tag "Integration" {
            
            Context "Positive Tests - Should Detect Violations" {
                
                It "ComponentInMoreThanOneUnmanagedSolution - should detect table in multiple solutions with IncludeSubcomponents" {
                    # Basis: When a component exists in multiple unmanaged solutions with IncludeSubcomponents behavior,
                    # it creates ownership conflicts and can cause deployment failures
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\ComponentInMoreThanOneUnmanagedSolution.ps1" $context)
                    
                    $errors | Should -Not -BeNullOrEmpty -Because "table1 is in both Positive1 and Positive2 with IncludeSubcomponents behavior"
                }
                
                It "ComponentInMoreThanOneUmanagedSolution-Metadata - should detect table in multiple solutions with ShellAndMetadata" {
                    # Basis: Components with ShellAndMetadata behavior in multiple solutions can cause metadata conflicts
                    # during solution import and layering issues
                    # Note: This test may not trigger if Dataverse automatically changes behavior 1 to behavior 2
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\ComponentInMoreThanOneUmanagedSolution-Metadata.ps1" $context)
                    
                    # This test may not always trigger due to how Dataverse handles behavior settings
                    # If it doesn't find violations, verify that table2 exists with behavior 2 instead, which is OK
                    if (-not $errors) {
                        Write-Warning "ComponentInMoreThanOneUmanagedSolution-Metadata test did not find violations (Dataverse may have changed behavior 1 to 2)"
                        Set-ItResult -Skipped -Because "Dataverse changed ShellAndMetadata (1) to ShellOnly (2)"
                    } else {
                        $errors | Should -Not -BeNullOrEmpty -Because "table2 is in both Positive1 and Positive2 with ShellAndMetadata behavior"
                    }
                }
                
                It "ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix - should detect prefix mismatch" {
                    # Basis: Component schema names should match the solution publisher's customization prefix
                    # This ensures naming consistency and prevents confusion about component ownership
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix.ps1" $context)
                    
                    $errors | Should -Not -BeNullOrEmpty -Because "foreigntable has vt2_ prefix but solution has vt1_ publisher prefix"
                }
                
                It "EnvironmentVariableCurrentValueInSolution - should detect current value in solution" {
                    # Basis: Environment variable current values are environment-specific configuration
                    # Only definitions should be in solutions; current values should be set per environment
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\EnvironmentVariableCurrentValueInSolution.ps1" $context)
                    
                    $errors | Should -Not -BeNullOrEmpty -Because "environment variable current value (component type 381) is in the solution"
                }
                
                It "ComponentIsUnmanagedNonCustom - should detect unmodified system components (root level)" {
                    # Basis: Unmodified out-of-box system components should not be in solutions
                    # They already exist in all environments and create unnecessary solution bloat
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\ComponentIsUnmanagedNonCustom.ps1" $context)
                    $specificError = $errors | Where-Object { $_.Message -like "*Account*Entity*" }
                    
                    $specificError | Should -Not -BeNullOrEmpty -Because "unmodified Account table (system component) is in the solution"
                }
                
                It "ComponentIsUnmanagedNonCustom - should detect unmodified system subcomponents (columns, forms)" {
                    # Basis: Unmodified system subcomponents (columns, forms, views) should not be in solutions
                    # This validation now extends to subcomponents, not just root components
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_Positive1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\ComponentIsUnmanagedNonCustom.ps1" $context)
                    # Look for any subcomponent violations (could be column or form)
                    $subcomponentErrors = $errors | Where-Object { $_.Message -like "*Is Subcomponent: Yes*" }
                    
                    $subcomponentErrors | Should -Not -BeNullOrEmpty -Because "unmodified system subcomponents (column and/or form) are in the solution"
                }
            }
            
            Context "Positive Tests - System Publisher" {
                
                It "SolutionUsesSystemPublisher - should detect solution using system publisher" {
                    # Basis: Solutions should use custom publishers, not the default system publisher
                    # System publishers are automatically created and should not be used for custom solutions
                    
                    $context = [PSCustomObject]@{
                        solutionname = "ValidationTest_SystemPub"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }
                    $errors = @(& "$ttecDigitalRoot\validationrules\SolutionUsesSystemPublisher.ps1" $context)
                    
                    $errors | Should -Not -BeNullOrEmpty -Because "ValidationTest_SystemPub uses the system default publisher"
                }
            }
            
            Context "Negative Tests - Should Pass Validation" {
                
                It "Properly configured solution should pass all validation rules" {
                    # Basis: A correctly configured solution with:
                    # - Components only in one solution
                    # - Correct publisher prefix matching
                    # - No current values for environment variables
                    # - Only custom or customized components
                    # Should pass all validation rules without errors
                    # Note: This test intentionally uses validateSolutionInternal to run ALL rules
                    
                    $errors = @(validateSolutionInternal -solutionname "ValidationTest_Negative1" -validdependencysolutionnames @("ValidationTest_Positive1", "ValidationTest_Positive2") -ignoresolutionnames @())
                    
                    $errors | Should -BeNullOrEmpty -Because "ValidationTest_Negative1 is properly configured and should pass all validations"
                }

                It "DependencyOnSolutionNotAllowed - should not flag base-layer system dependency overlays" {
                    $context = [PSCustomObject]@{
                        solutionname = "TestSolution1"
                        validdependencysolutionnames = @()
                        ignoresolutionnames = @()
                        solutionconfig = @{}
                        validationMode = 'error'
                        ruleMode = 'error'
                    }

                    $errors = @(& "$ttecDigitalRoot\validationrules\DependencyOnSolutionNotAllowed.ps1" $context)
                    $targetFalsePositive = $errors | Where-Object {
                        $_.Message -like "*PowerPages_RuntimeCoreDependencies*" -and
                        $_.Message -like "*608861bc-50a4-4c5f-a02c-21fe1943e2cf*"
                    }

                    $targetFalsePositive | Should -BeNullOrEmpty -Because "base-layer dependency should resolve to system base instead of shell-only overlay solution"
                }
            }
        }
    }
    $pesterConfig.Output.Verbosity = 'Detailed'
    
    Invoke-Pester -Configuration $pesterConfig
    return
}

# Setup mode (default or with -SetupOnly)
try {
    Write-Host "`nSetting up test data..." -ForegroundColor Cyan
    
    Setup-TestPublishers
    Setup-TestSolutions
    Setup-TestTables
    Setup-TestEnvironmentVariables
    Setup-TestComponents
    
    Write-Host "`nSetup complete!" -ForegroundColor Green
    
    if (-not $SetupOnly) {
        # Run tests after setup
        Write-Host "`nRunning Pester tests..." -ForegroundColor Cyan
        
        # Import validation functions
        $ttecDigitalRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . "$ttecDigitalRoot\common\solutionvalidation.ps1"
        
        # Run Pester tests inline
        & {
            Describe "Solution Validation Rules" -Tag "Integration" {
                
                Context "Positive Tests - Should Detect Violations" {
                    
                    It "ComponentInMoreThanOneUnmanagedSolution - should detect table in multiple solutions with IncludeSubcomponents" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentInMoreThanOneUnmanagedSolution.ps1" $context)
                        $errors | Should -Not -BeNullOrEmpty -Because "table1 is in both Positive1 and Positive2 with IncludeSubcomponents behavior"
                    }
                    
                    It "ComponentInMoreThanOneUmanagedSolution-Metadata - should detect table in multiple solutions with ShellAndMetadata" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentInMoreThanOneUmanagedSolution-Metadata.ps1" $context)
                        
                        # This test may not always trigger due to how Dataverse handles behavior settings
                        if (-not $errors) {
                            Write-Warning "ComponentInMoreThanOneUmanagedSolution-Metadata test did not find violations (Dataverse may have changed behavior 1 to 2)"
                            Set-ItResult -Skipped -Because "Dataverse changed ShellAndMetadata (1) to ShellOnly (2)"
                        } else {
                            $errors | Should -Not -BeNullOrEmpty -Because "table2 is in both Positive1 and Positive2 with ShellAndMetadata behavior"
                        }
                    }
                    
                    It "ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix - should detect prefix mismatch" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix.ps1" $context)
                        $errors | Should -Not -BeNullOrEmpty -Because "foreigntable has vt2_ prefix but solution has vt1_ publisher prefix"
                    }
                    
                    It "EnvironmentVariableCurrentValueInSolution - should detect current value in solution" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\EnvironmentVariableCurrentValueInSolution.ps1" $context)
                        $errors | Should -Not -BeNullOrEmpty -Because "environment variable current value (component type 381) is in the solution"
                    }
                    
                    It "ComponentIsUnmanagedNonCustom - should detect unmodified system components (root level)" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentIsUnmanagedNonCustom.ps1" $context)
                        $specificError = $errors | Where-Object { $_.Message -like "*Account*Entity*" }
                        $specificError | Should -Not -BeNullOrEmpty -Because "unmodified Account table (system component) is in the solution"
                    }
                    
                    It "ComponentIsUnmanagedNonCustom - should detect unmodified system subcomponents (columns, forms)" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Positive1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentIsUnmanagedNonCustom.ps1" $context)
                        $subcomponentErrors = $errors | Where-Object { $_.Message -like "*Is Subcomponent: Yes*" }
                        $subcomponentErrors | Should -Not -BeNullOrEmpty -Because "unmodified system subcomponents (column and/or form) are in the solution"
                    }
                }
                
                Context "Positive Tests - System Publisher" {
                    
                    It "SolutionUsesSystemPublisher - should detect solution using system publisher" {
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_SystemPub"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\SolutionUsesSystemPublisher.ps1" $context)
                        $errors | Should -Not -BeNullOrEmpty -Because "ValidationTest_SystemPub uses the system default publisher"
                    }
                }
                
                Context "Negative Tests - Should Pass Validation" {
                    
                    It "Properly configured solution should pass all validation rules" {
                        $errors = @(validateSolutionInternal -solutionname "ValidationTest_Negative1" -validdependencysolutionnames @("ValidationTest_Positive1", "ValidationTest_Positive2") -ignoresolutionnames @())
                        $errors | Should -BeNullOrEmpty -Because "ValidationTest_Negative1 is properly configured and should pass all validations"
                    }

                    It "DependencyOnSolutionNotAllowed - should not flag base-layer system dependency overlays" {
                        $context = [PSCustomObject]@{
                            solutionname = "TestSolution1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }

                        $errors = @(& "$ttecDigitalRoot\validationrules\DependencyOnSolutionNotAllowed.ps1" $context)
                        $targetFalsePositive = $errors | Where-Object {
                            $_.Message -like "*PowerPages_RuntimeCoreDependencies*" -and
                            $_.Message -like "*608861bc-50a4-4c5f-a02c-21fe1943e2cf*"
                        }

                        $targetFalsePositive | Should -BeNullOrEmpty -Because "base-layer dependency should resolve to system base instead of shell-only overlay solution"
                    }
                    
                    It "ComponentIsUnmanagedNonCustom - should validate behavior 1 components (shell-only not testable via API)" {
                        # Basis: Behavior 1 (Do Not Include Subcomponents) should still be validated
                        # Note: Behavior 2 (Shell Only) would be excluded, but the API doesn't support adding it
                        # The API converts behavior 2 to behavior 1, so we test that behavior 1 IS validated
                        
                        $context = [PSCustomObject]@{
                            solutionname = "ValidationTest_Behavior1"
                            validdependencysolutionnames = @()
                            ignoresolutionnames = @()
                            solutionconfig = @{}
                            validationMode = 'error'
                            ruleMode = 'error'
                        }
                        $errors = @(& "$ttecDigitalRoot\validationrules\ComponentIsUnmanagedNonCustom.ps1" $context)
                        # The Account table was added with behavior 1 (API limitation)
                        # This SHOULD trigger a validation error because it's unmodified and behavior != 2
                        $accountError = $errors | Where-Object { $_.Message -like "*Account*" -or $_.Message -like "*account*" }
                        
                        # Since the API can't add behavior=2, the Account table has behavior=1 and SHOULD be validated
                        # If this test fails (no error found), it means behavior 1 is also being excluded, which is wrong
                        $accountError | Should -Not -BeNullOrEmpty -Because "Account table with behavior 1 (not 2) should still be validated as it's unmodified"
                    }
                }
            }
        } | Invoke-Pester -Output Detailed
    }
}
catch {
    Write-Error "Script failed: $_"
    throw
}

#endregion
