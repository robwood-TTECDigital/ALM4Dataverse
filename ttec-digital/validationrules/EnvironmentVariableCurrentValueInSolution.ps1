param($context)

# Get the solution ID for the solution being validated
$solutionIdSql = "SELECT solutionid FROM solution WHERE uniquename = @solutionname"
$solutionIdResult = Invoke-DataverseSQL -Sql $solutionIdSql -Parameters @{
    solutionname = $context.solutionname
}
$solutionId = $solutionIdResult[0].solutionid.ToString()

# Find environment variable values in the target solution
# Component type 381 = Environment Variable Value
$sql = @"
SELECT 
    sc.objectid,
    sc.componenttype
FROM solutioncomponent sc
INNER JOIN solution s ON sc.solutionid = s.solutionid
WHERE s.uniquename = @solutionname
    AND sc.componenttype = 381
"@

$results = Invoke-DataverseSQL -Sql $sql -Parameters @{
    solutionname = $context.solutionname
}

$results | ForEach-Object {
    $componentId = $_.objectid
    $componentType = $_.componenttype
    
    # Load component names
    $names = getComponentNames -componentId $componentId -componentType $componentType -solutionId $solutionId
    $componentSchemaName = if ($names) { $names.ComponentSchemaName } else { $null }
    
    # Check if this component should skip validation
    $mode = getValidationRuleMode -ruleName 'EnvironmentVariableCurrentValueInSolution' -componentId $componentId -componentType $componentType -componentSchemaName $componentSchemaName -solutionconfig $context.solutionconfig
    
    # Override with rule-level mode if it's warning
    if ($context.ruleMode -eq 'warning' -and $mode -eq 'error') {
        $mode = 'warning'
    }
    
    if ($mode -eq 'skip') {
        return
    }
    
    $detailsObj = [PSCustomObject]@{
        objectid = $componentId
        componenttype = $componentType
        ComponentSchemaName = if ($names) { $names.ComponentSchemaName } else { $null }
        ComponentDisplayName = if ($names) { $names.ComponentDisplayName } else { $null }
    }
    
    $detailsText = $detailsObj | Format-List | Out-String
    
    writeResult -type "EnvironmentVariableCurrentValueInSolution" `
        -componentid $componentId `
        -message "Environment variable current value should be excluded from solution:`n$detailsText" `
        -asWarning ($mode -eq 'warning')
}