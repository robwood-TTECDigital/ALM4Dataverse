param($context)

# Get the solution ID for the solution being validated
$solutionIdSql = "SELECT solutionid FROM solution WHERE uniquename = @solutionname"
$solutionIdResult = Invoke-DataverseSQL -Sql $solutionIdSql -Parameters @{
    solutionname = $context.solutionname
}
$solutionId = $solutionIdResult[0].solutionid.ToString()

# Get the publisher prefix for the solution
$prefixSql = @"
SELECT 
    p.customizationprefix
FROM solution s
INNER JOIN publisher p ON s.publisherid = p.publisherid
WHERE s.uniquename = @solutionname
"@

$prefixResult = Invoke-DataverseSQL -Sql $prefixSql -Parameters @{
    solutionname = $context.solutionname
}
$correctprefix = $prefixResult[0].customizationprefix + "_"

# Find components with schema names that don't match the publisher prefix
# Exclude certain component types: 3, 10, 61, 92, 300, 10044
# Only check components that are not ShellOnly and don't have a managed version
$sql = @"
SELECT 
    sc.objectid,
    sc.componenttype
FROM solutioncomponent sc
INNER JOIN solution s ON sc.solutionid = s.solutionid
WHERE s.uniquename = @solutionname
    AND sc.rootcomponentbehavior <> 2  -- Not ShellOnly
    AND sc.componenttype NOT IN (3, 10, 61, 92, 300, 10044)
    AND sc.objectid NOT IN (
        SELECT sc2.objectid
        FROM solutioncomponent sc2
        INNER JOIN solution s2 ON sc2.solutionid = s2.solutionid
        WHERE sc2.objectid = sc.objectid
            AND s2.ismanaged = 1
    )
"@

$results = Invoke-DataverseSQL -Sql $sql -Parameters @{
    solutionname = $context.solutionname
}

$results | ForEach-Object {
    $componentId = $_.objectid
    $componentType = $_.componenttype
    
    # Load component name to check prefix
    $names = getComponentNames -componentId $componentId -componentType $componentType -solutionId $solutionId -ValidationContext $context
    
    if ($names) {
        $schemaName = $names.ComponentSchemaName
        
        # Check if schema name contains underscore and doesn't start with correct prefix
        if ($schemaName -and $schemaName.Contains("_") -and -not $schemaName.StartsWith($correctprefix)) {
            # Check if this component should skip validation
            $mode = getValidationRuleMode -ruleName 'ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix' -componentId $componentId -componentType $componentType -componentSchemaName $schemaName -solutionconfig $context.solutionconfig
            
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
                ComponentSchemaName = $names.ComponentSchemaName
                ComponentDisplayName = $names.ComponentDisplayName
            }
            
            $detailsText = $detailsObj | Format-List | Out-String
            
            writeResult -type "ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix" `
                -componentid $componentId `
                -message "Component schema name prefix does not match publisher prefix ($correctprefix) for unmanaged component:`n$detailsText" `
                -asWarning ($mode -eq 'warning')
        }
    }
}