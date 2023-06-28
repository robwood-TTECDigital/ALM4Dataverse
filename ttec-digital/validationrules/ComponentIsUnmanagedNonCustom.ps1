param($context)

# This rule validates that all components in the solution are either custom or have active customizations.
# It ensures we're not including out-of-box, unmodified system components in our solutions.
# This includes both top-level components and subcomponents (columns, forms, views, etc.)

# Get the solution ID for the solution being validated
$solutionIdSql = "SELECT solutionid FROM solution WHERE uniquename = @solutionname"
$solutionIdResult = Invoke-DataverseSQL -Sql $solutionIdSql -Parameters @{
    solutionname = $context.solutionname
}

if (-not $solutionIdResult -or $solutionIdResult.Length -eq 0) {
    Write-Verbose "Solution $($context.solutionname) not found"
    return
}

$solutionId = $solutionIdResult[0].solutionid.ToString()

# First, get all components from the solutioncomponent table
# This gives us both top-level components and subcomponents
# Exclude shell-only components (rootcomponentbehavior = 2) as they are metadata-only references
$componentsSql = @"
SELECT 
    sc.objectid,
    sc.componenttype,
    sc.rootsolutioncomponentid,
    sc.rootcomponentbehavior
FROM solutioncomponent sc
INNER JOIN solution s ON sc.solutionid = s.solutionid
WHERE s.uniquename = @solutionname
AND sc.rootcomponentbehavior <> 2  -- Not ShellOnly
"@

$solutionComponents = Invoke-DataverseSQL -Sql $componentsSql -Parameters @{
    solutionname = $context.solutionname
}

if (-not $solutionComponents -or $solutionComponents.Length -eq 0) {
    Write-Verbose "No components found in solution $($context.solutionname)"
    return
}

Write-Verbose "Found $($solutionComponents.Length) components in solution (including subcomponents)"

# Now query msdyn_solutioncomponentsummary for each component to get custom/customization status
# Note: Shell-only components (rootcomponentbehavior = 2) are already filtered out in the SQL query
# Shell-only means only the metadata/definition is referenced, not the actual component and subcomponents
$componentsToCheck = @()

foreach ($component in $solutionComponents) {
    $componentId = $component.objectid.ToString()
    $componentType = $component.componenttype
    
    # Skip if componentId is empty or null
    if ([string]::IsNullOrWhiteSpace($componentId)) {
        Write-Verbose "Skipping component with empty ID"
        continue
    }
    
    # Query msdyn_solutioncomponentsummary for this specific component
    # Note: We filter by solution, component type, and object ID
    $apiPath = "msdyn_solutioncomponentsummaries?`$filter=msdyn_solutionid eq $solutionId and msdyn_componenttype eq $componentType and msdyn_objectid eq $componentId&`$select=msdyn_objectid,msdyn_componenttype,msdyn_name,msdyn_schemaname,msdyn_displayname,msdyn_componenttypename,msdyn_iscustom,msdyn_hasactivecustomization,msdyn_ismanaged,msdyn_componentlogicalname"
    
    try {
        $response = Invoke-DataverseRequest -Method Get -Path $apiPath
        
        if ($response.value -and $response.value.Length -gt 0) {
            # Component was found in summary table
            $summaryComponent = $response.value[0]
            
            # Check if this is an unmanaged, non-custom component
            $isNotCustom = $summaryComponent.msdyn_iscustom -ne $true
            $hasNoCustomization = $summaryComponent.msdyn_hasactivecustomization -ne $true
            
            if ($isNotCustom -and $hasNoCustomization) {
                $componentsToCheck += [PSCustomObject]@{
                    ComponentId = $componentId
                    ComponentType = $componentType
                    Name = $summaryComponent.msdyn_name
                    SchemaName = $summaryComponent.msdyn_schemaname
                    DisplayName = $summaryComponent.msdyn_displayname
                    ComponentTypeName = $summaryComponent.msdyn_componenttypename
                    IsCustom = $summaryComponent.msdyn_iscustom
                    HasActiveCustomization = $summaryComponent.msdyn_hasactivecustomization
                    IsManaged = $summaryComponent.msdyn_ismanaged
                    ComponentLogicalName = $summaryComponent.msdyn_componentlogicalname
                    IsSubcomponent = $component.rootsolutioncomponentid -ne $null
                }
            }
        } else {
            # Component not found in summary table - this can happen for some component types
            Write-Verbose "Component not found in summary table: ID=$componentId, Type=$componentType"
        }
    } catch {
        Write-Verbose "Error querying component summary for ID=$componentId, Type=$componentType : $_"
    }
}

Write-Verbose "Found $($componentsToCheck.Count) unmanaged non-custom components (including subcomponents)"

# Report violations
$componentsToCheck | ForEach-Object {
    $componentId = $_.ComponentId
    $componentType = $_.ComponentType
    $componentName = $_.Name
    $componentSchemaName = $_.SchemaName
    $componentDisplayName = $_.DisplayName
    $componentTypeName = $_.ComponentTypeName
    $isSubcomponent = $_.IsSubcomponent
    
    # Use schema name if available, otherwise fall back to name or display name
    $displayName = $componentSchemaName
    if (-not $displayName) {
        $displayName = $componentName
    }
    if (-not $displayName) {
        $displayName = $componentDisplayName
    }
    if (-not $displayName) {
        $displayName = "Unknown"
    }
    
    # Check if this component should skip validation
    $mode = getValidationRuleMode `
        -ruleName 'ComponentIsUnmanagedNonCustom' `
        -componentId $componentId `
        -componentType $componentType `
        -componentSchemaName $componentSchemaName `
        -solutionconfig $context.solutionconfig
    
    # Override with rule-level mode if it's warning
    if ($context.ruleMode -eq 'warning' -and $mode -eq 'error') {
        $mode = 'warning'
    }
    
    if ($mode -eq 'skip') {
        return
    }
    
    $subcomponentNote = if ($isSubcomponent) { "  Is Subcomponent: Yes" } else { "" }
    
    $message = @"
Component is an out-of-box, unmodified system component.
Only custom components or components with active customizations should be included in solutions.

Component Details:
  Name: $displayName
  Type: $componentTypeName (Type ID: $componentType)
  Is Custom: $($_.IsCustom)
  Has Active Customization: $($_.HasActiveCustomization)
  Is Managed: $($_.IsManaged)$subcomponentNote
"@
    
    writeResult -type "ComponentIsUnmanagedNonCustom" `
        -componentid $componentId `
        -message $message `
        -asWarning ($mode -eq 'warning')
}
