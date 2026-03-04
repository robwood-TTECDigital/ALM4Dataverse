param($context)

write-host "Getting current solution dependencies"

# Get the solution ID for the solution being validated
$solutionIdSql = "SELECT solutionid FROM solution WHERE uniquename = @solutionname"
$solutionIdResult = Invoke-DataverseSQL -Sql $solutionIdSql -Parameters @{
    solutionname = $context.solutionname
}
$solutionId = $solutionIdResult[0].solutionid.ToString()

# Find missing dependencies - components that the solution depends on but aren't in the solution
# This uses the dependency table to find required components
$sql = @"
SELECT DISTINCT
    dep.requiredcomponentobjectid,
    dep.requiredcomponenttype,
    dep.requiredcomponentparentid,
    dep.requiredcomponentbasesolutionid,
    dep.dependentcomponentobjectid,
    dep.dependentcomponenttype
FROM dependency dep
WHERE dep.dependentcomponentobjectid IN (
    SELECT sc.objectid
    FROM solutioncomponent sc
    INNER JOIN solution s ON sc.solutionid = s.solutionid
    WHERE s.uniquename = @solutionname
)
AND dep.requiredcomponentobjectid NOT IN (
    SELECT sc2.objectid
    FROM solutioncomponent sc2
    INNER JOIN solution s2 ON sc2.solutionid = s2.solutionid
    WHERE s2.uniquename = @solutionname
    AND (sc2.rootcomponentbehavior = 0 OR sc2.rootcomponentbehavior IS NULL)
)
"@

$dependencies = Invoke-DataverseSQL -Sql $sql -Parameters @{
    solutionname = $context.solutionname
}

# For each dependency, find which solution(s) contain the required component
$badDeps = @()

foreach ($dep in $dependencies) {
    $requiredsolutioncomponents = @()
    $requiredComponentId = $dep.requiredcomponentobjectid
    $requiredComponentType = $dep.requiredcomponenttype
    $requiredParentId = $dep.requiredcomponentparentid
    $requiredBaseSolutionId = $dep.requiredcomponentbasesolutionid
    $dependentComponentId = $dep.dependentcomponentobjectid
    $dependentComponentType = $dep.dependentcomponenttype
    
    Write-Verbose "Processing dependency: Required=$requiredComponentId (Type=$requiredComponentType), Dependent=$dependentComponentId (Type=$dependentComponentType)"
    
    # Build dynamic ignore filter for this query
    $ignoreFilter = ""
    if ($context.ignoresolutionnames -and $context.ignoresolutionnames.Length -gt 0) {
        $ignorePatterns = $context.ignoresolutionnames | ForEach-Object { $_.Replace("*", "%") }
        foreach ($pattern in $ignorePatterns) {
            $ignoreFilter += " AND s.uniquename NOT LIKE '$pattern'"
        }
    }
    
    # Build filter to exclude valid dependency solutions
    $validDependencyFilter = ""
    if ($context.validdependencysolutionnames -and $context.validdependencysolutionnames.Length -gt 0) {
        foreach ($validPattern in $context.validdependencysolutionnames) {
            $validDependencyFilter += " AND s.uniquename NOT LIKE '$($validPattern.Replace("*", "%"))'"
        }
    }

    # Prefer authoritative base solution from dependency table when available
    $baseSolutionEvaluated = $false
    if ($requiredBaseSolutionId -and -not [string]::IsNullOrWhiteSpace($requiredBaseSolutionId.ToString())) {
        $baseSolutionSql = @"
SELECT
    s.uniquename AS SolutionName,
    s.solutionid AS SolutionId,
    s.ismanaged AS Managed
FROM solution s
WHERE s.solutionid = @requiredBaseSolutionId
"@

        $baseSolutionRows = @(Invoke-DataverseSQL -Sql $baseSolutionSql -Parameters @{
            requiredBaseSolutionId = $requiredBaseSolutionId
        })

        if ($baseSolutionRows.Length -gt 0) {
            $baseSolutionEvaluated = $true
            $baseSolutionName = $baseSolutionRows[0].SolutionName
            $baseSolutionId = $baseSolutionRows[0].SolutionId.ToString()

            $isSystemOrDefault = $baseSolutionName -in @('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System') -or $baseSolutionId -eq '00000001-0000-0000-0001-00000000009b'

            $isIgnoredSolution = $false
            if ($context.ignoresolutionnames -and $context.ignoresolutionnames.Length -gt 0) {
                foreach ($pattern in $context.ignoresolutionnames) {
                    if ($baseSolutionName -like $pattern) {
                        $isIgnoredSolution = $true
                        break
                    }
                }
            }

            $isValidDependencySolution = $false
            if ($context.validdependencysolutionnames -and $context.validdependencysolutionnames.Length -gt 0) {
                foreach ($validPattern in $context.validdependencysolutionnames) {
                    if ($baseSolutionName -like $validPattern) {
                        $isValidDependencySolution = $true
                        break
                    }
                }
            }

            if (-not $isSystemOrDefault -and $baseSolutionName -ne $context.solutionname -and -not $isIgnoredSolution -and -not $isValidDependencySolution) {
                $requiredsolutioncomponents = @([PSCustomObject]@{
                    SolutionName = $baseSolutionName
                    SolutionId = $baseSolutionRows[0].SolutionId
                    Managed = $baseSolutionRows[0].Managed
                    ComponentId = $requiredComponentId
                    ComponentType = $requiredComponentType
                    Behaviour = "BaseLayer"
                })
            }
        }
    }
    
    # First try to find the required component (not ShellOnly) when no base solution was available
    if ($requiredsolutioncomponents.Length -eq 0 -and -not $baseSolutionEvaluated) {
    $componentSql = @"
SELECT 
    s.uniquename AS SolutionName,
    s.solutionid AS SolutionId,
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
WHERE sc.objectid = @requiredComponentId
    AND sc.componenttype = @requiredComponentType
    AND sc.rootcomponentbehavior <> 2  -- Not ShellOnly
    AND s.uniquename <> @solutionname
    AND s.uniquename NOT IN ('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System')
    AND s.solutionid <> '00000001-0000-0000-0001-00000000009b'
    $ignoreFilter
    $validDependencyFilter
ORDER BY s.installedon ASC, s.createdon ASC
"@
    
    $requiredsolutioncomponents = @(Invoke-DataverseSQL -Sql $componentSql -Parameters @{
        requiredComponentId = $requiredComponentId
        requiredComponentType = $requiredComponentType
        solutionname = $context.solutionname
    })
    }
    
    # If not found and there's a parent, fallback to earliest non-shell parent layer (only when base solution wasn't available)
    if ($requiredsolutioncomponents.Length -eq 0 -and $requiredParentId -and -not $baseSolutionEvaluated) {
        $parentSql = @"
SELECT TOP 1
    s.uniquename AS SolutionName,
    s.solutionid AS SolutionId,
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
WHERE sc.objectid = @requiredParentId
    AND sc.rootcomponentbehavior <> 2  -- Prefer non-shell parent layer
    AND s.uniquename <> @solutionname
    AND s.uniquename NOT IN ('Default', 'Common Data Services Default Solution', 'Active', 'Basic', 'System')
    AND s.solutionid <> '00000001-0000-0000-0001-00000000009b'
    $ignoreFilter
    $validDependencyFilter
ORDER BY s.installedon ASC, s.createdon ASC
"@
        
        $requiredsolutioncomponents = @(Invoke-DataverseSQL -Sql $parentSql -Parameters @{
            requiredParentId = $requiredParentId
            solutionname = $context.solutionname
        })
    }

    # If base solution was evaluated and didn't produce an invalid dependency, skip this dependency
    if ($requiredsolutioncomponents.Length -eq 0 -and $baseSolutionEvaluated) {
        continue
    }
    
    # If still not found, get the component name anyway and mark as not in any solution
    if ($requiredsolutioncomponents.Length -eq 0) {
        $requiredsolutioncomponents = @([PSCustomObject]@{
            SolutionName = "<Not in any solution>"
            ComponentId = $requiredComponentId
            ComponentType = $requiredComponentType
            Behaviour = "IncludeSubcomponents"
        })
    }
    
    # Load names for required and dependent components (only for invalid dependencies)
    if ($requiredsolutioncomponents.Length -gt 0) {
        # Get the solution ID of the first required solution component (if present)
        $reqSolutionId = $null
        if ($requiredsolutioncomponents[0].PSObject.Properties.Name -contains 'SolutionId' -and $requiredsolutioncomponents[0].SolutionId) {
            $reqSolutionId = $requiredsolutioncomponents[0].SolutionId.ToString()
        }

        # Load required component name
        $reqNames = if ($reqSolutionId) {
            getComponentNames -componentId $requiredComponentId -componentType $requiredComponentType -solutionId $reqSolutionId
        }
        else {
            getComponentNames -componentId $requiredComponentId -componentType $requiredComponentType
        }
        
        # Load dependent component name (from the solution being validated)
        Write-Verbose "Looking up dependent component: ID=$dependentComponentId, Type=$dependentComponentType"
        $depNames = getComponentNames -componentId $dependentComponentId -componentType $dependentComponentType -solutionId $solutionId
        
        # Get parent table name for dependent component using parent ID from solutioncomponent
        $dependentParentName = $null
        $parentSql = @"
SELECT sc.rootsolutioncomponentid, sc2.objectid, sc2.componenttype
FROM solutioncomponent sc
LEFT JOIN solutioncomponent sc2 ON sc.rootsolutioncomponentid = sc2.solutioncomponentid
WHERE sc.objectid = @componentId AND sc.componenttype = @componentType
"@
        $parentResult = Invoke-DataverseSQL -Sql $parentSql -Parameters @{
            componentId = $dependentComponentId
            componentType = $dependentComponentType
        }
        
        if ($parentResult -and $parentResult.Length -gt 0 -and $parentResult[0].objectid) {
            $parentId = $parentResult[0].objectid.ToString()
            $parentType = $parentResult[0].componenttype
            
            # Skip if parentId is empty or null
            if (-not [string]::IsNullOrWhiteSpace($parentId)) {
                # Get the parent component name
                $parentNames = getComponentNames -componentId $parentId -componentType $parentType -solutionId $solutionId
                if ($parentNames) {
                    $dependentParentName = $parentNames.ComponentSchemaName
                }
            }
        }
        
        # Add names to all required solution components and add to badDeps
        $requiredsolutioncomponents | ForEach-Object {
            $_ | Add-Member -NotePropertyName ComponentSchemaName -NotePropertyValue (&{if ($reqNames) { $reqNames.ComponentSchemaName } else { $null }}) -Force
            $_ | Add-Member -NotePropertyName ComponentDisplayName -NotePropertyValue (&{if ($reqNames) { $reqNames.ComponentDisplayName } else { $null }}) -Force
            $_ | Add-Member -NotePropertyName DependentComponentType -NotePropertyValue $dependentComponentType -Force
            $_ | Add-Member -NotePropertyName DependentComponentSchemaName -NotePropertyValue (&{if ($depNames) { $depNames.ComponentSchemaName } else { $null }}) -Force
            $_ | Add-Member -NotePropertyName DependentComponentDisplayName -NotePropertyValue (&{if ($depNames) { $depNames.ComponentDisplayName } else { $null }}) -Force
            $_ | Add-Member -NotePropertyName DependentComponentParentName -NotePropertyValue $dependentParentName -Force
            
            $badDeps += $_
        }
    }
}

# Output errors for bad dependencies
$badDeps | Select-Object -Unique ComponentId, SolutionName | ForEach-Object {
    $componentId = $_.ComponentId
    $solutionName = $_.SolutionName
    
    $matchingDeps = $badDeps | Where-Object { $_.ComponentId -eq $componentId -and $_.SolutionName -eq $solutionName }
    
    # Get component type and schema name for skip check
    $componentType = if ($matchingDeps.Length -gt 0) { $matchingDeps[0].ComponentType } else { 0 }
    $componentSchemaName = if ($matchingDeps.Length -gt 0) { $matchingDeps[0].ComponentSchemaName } else { $null }
    
    # Check if this component should skip validation
    $mode = getValidationRuleMode -ruleName 'DependencyOnSolutionNotAllowed' -componentId $componentId -componentType $componentType -componentSchemaName $componentSchemaName -solutionconfig $context.solutionconfig
    
    # Override with rule-level mode if it's warning
    if ($context.ruleMode -eq 'warning' -and $mode -eq 'error') {
        $mode = 'warning'
    }
    
    if ($mode -eq 'skip') {
        return
    }
    
    $detailsText = $matchingDeps[0] | Format-List | Out-String
    
    writeResult -type "DependencyOnSolutionNotAllowed" `
        -componentid $componentId `
        -message "`r`nThe solution $($context.solutionname) depends on solution $solutionName for a component but this is not in the valid list of dependency solutions ($($context.validdependencysolutionnames))`r`n$detailsText" `
        -asWarning ($mode -eq 'warning')
}