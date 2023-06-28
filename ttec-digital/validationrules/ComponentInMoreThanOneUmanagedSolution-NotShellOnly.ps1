param($context)

# Find components that are in the target solution with ShellAndMetadata or ShellOnly behavior
# but also exist in another unmanaged solution with IncludeSubcomponents behavior
$sql = @"
SELECT 
    sc.objectid,
    sc.componenttype
FROM solutioncomponent sc
INNER JOIN solution s ON sc.solutionid = s.solutionid
WHERE s.uniquename = @solutionname
    AND sc.rootcomponentbehavior IN (1, 2)  -- ShellAndMetadata or ShellOnly
    AND s.uniquename NOT IN ('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System')
    AND s.solutionid <> '00000001-0000-0000-0001-00000000009b'
    AND sc.objectid IN (
        SELECT sc2.objectid
        FROM solutioncomponent sc2
        INNER JOIN solution s2 ON sc2.solutionid = s2.solutionid
        WHERE s2.ismanaged = 0
            AND (sc2.rootcomponentbehavior = 0 OR sc2.rootcomponentbehavior IS NULL)  -- IncludeSubcomponents
            AND s2.uniquename NOT IN ('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System')
            AND s2.solutionid <> '00000001-0000-0000-0001-00000000009b'
    )
"@

$results = Invoke-DataverseSQL -Sql $sql -Parameters @{
    solutionname = $context.solutionname
}

$results | ForEach-Object {
    $componentId = $_.objectid
    $componentType = $_.componenttype
    
    # Get details of the target solution component and conflicting unmanaged solutions
    $detailSql = @"
SELECT 
    s.uniquename AS SolutionName,
    s.ismanaged AS Managed,
    sc.objectid AS ComponentId,
    sc.componenttype AS ComponentType,
    CASE sc.rootcomponentbehavior 
        WHEN 0 THEN 'IncludeSubcomponents'
        WHEN 1 THEN 'ShellAndMetadata'
        WHEN 2 THEN 'ShellOnly'
        ELSE 'IncludeSubcomponents'
    END AS Behaviour
FROM solutioncomponent sc
INNER JOIN solution s ON sc.solutionid = s.solutionid
WHERE sc.objectid = @componentId
    AND (
        s.uniquename = @solutionname
        OR (s.ismanaged = 0 AND (sc.rootcomponentbehavior = 0 OR sc.rootcomponentbehavior IS NULL))
    )
    AND s.uniquename NOT IN ('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System')
    AND s.solutionid <> '00000001-0000-0000-0001-00000000009b'
"@
    
    $details = Invoke-DataverseSQL -Sql $detailSql -Parameters @{
        componentId = $componentId
        solutionname = $context.solutionname
    }
    
    # Bulk load component names for this component type
    $componentSchemaName = $null
    if ($details -and $details.Length -gt 0) {
        $names = getComponentNames -componentId $componentId -componentType $componentType -solutionId $solutionId
        
        if ($names) {
            $componentSchemaName = $names.ComponentSchemaName
            $details | ForEach-Object {
                $_ | Add-Member -NotePropertyName ComponentSchemaName -NotePropertyValue $names.ComponentSchemaName -Force
                $_ | Add-Member -NotePropertyName ComponentDisplayName -NotePropertyValue $names.ComponentDisplayName -Force
            }
        }
    }
    
    # Check if this component should skip validation
    $mode = getValidationRuleMode -ruleName 'ComponentInMoreThanOneUmanagedSolution-NotShellOnly' -componentId $componentId -componentType $componentType -componentSchemaName $componentSchemaName -solutionconfig $context.solutionconfig
    
    # Override with rule-level mode if it's warning
    if ($context.ruleMode -eq 'warning' -and $mode -eq 'error') {
        $mode = 'warning'
    }
    
    if ($mode -eq 'skip') {
        return
    }
    
    $detailsText = $details | Format-List | Out-String
    
    writeResult -type "ComponentInMoreThanOneUmanagedSolution-NotShellOnly" `
        -componentid $componentId `
        -message "Component is in a solution with conflicting 'include subcomponents' option (that solution will export the subcomponent too):`n$detailsText" `
        -asWarning ($mode -eq 'warning')
}