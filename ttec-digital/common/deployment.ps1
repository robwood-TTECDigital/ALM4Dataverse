# Workaround for platform issue where callbackregistration records can be left behind when the Cloud Flows they trigger are deleted
function deleteUnneededCallbackRegistrations() {
    $connection = getGlobalCrmConnection
    $query = new-object Microsoft.Xrm.Sdk.Query.FetchExpression "<fetch>
       <entity name='callbackregistration'>
         <all-attributes />
         <link-entity name='workflow' to='name' from='workflowid' alias='Expr1' link-type='outer' />
         <filter>
           <condition attribute='workflowid' entityname='Expr1' operator='null' />
         </filter>
       </entity>
     </fetch>"
    $cbstoremove = @($connection.RetrieveMultiple($query).Entities)
    foreach ($cbtoremove in $cbstoremove) {
        write-host "Deleting $($cbtoremove.LogicalName) $($cbtoremove.Id)"
        $connection.Delete($cbtoremove.LogicalName, $cbtoremove.Id)
    }
}

# Updates settings in "organization" table if any need to be changed.
# Settings values should have key matching the columns in that table and value understood by the Xrm.Sdk.
function deployOrgSettings([Parameter(Mandatory)][hashtable] $settings) {
    
    if ($settings.Count -eq 0) {
        return
    }

    write-host "##[group]Deploying org settings"

    $connection = getGlobalCrmConnection
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "organization"

    $query.ColumnSet.AddColumns($settings.Keys)

    $orgupdate = $connection.RetrieveMultiple($query).Entities[0]

    foreach ($orgsettingkey in $settings.Keys) {

        $oldvalue = $null
        if ($orgupdate.Attributes.ContainsKey($orgsettingkey)) {
            $oldvalue = $orgupdate[$orgsettingkey]
        }
        $newvalue = $settings[$orgsettingkey]

        if ($newvalue -is [scriptblock]) {
            $newvalue = & $newvalue
            write-host "Dynamic value of ${orgsettingkey}: '$newvalue'"
        }

        if ($oldvalue -eq $newvalue) {
            $orgupdate.Attributes.Remove($orgsettingkey) | out-null
        }
        else {
            $orgupdate[$orgsettingkey] = $newvalue
        }
    }

    if ($orgupdate.Attributes.Count -eq 1) {
        write-host "No org settings need to be updated"
    }
    else {
        write-host "Org settings need to be updated:"
        $orgupdate.Attributes | format-table
    }

    $connection.Update($orgupdate)

    write-host "##[endgroup]"
}

# Returns list of installed solutions
# Unique Name:string, Managed:bool, Version:string, Solution Id
function getInstalledSolutions() {

    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "solution"
    $query.ColumnSet = new-object Microsoft.Xrm.Sdk.Query.ColumnSet $true
    
    getQueryResults $query | foreach-object {
        [PSCustomObject] @{
            "Unique Name" = $_["uniquename"];
            "Managed"     = $_["ismanaged"];
            "Version"     = $_["version"];
            "Solution Id" = $_.Id
        }
    } | write-output

}

# Returns the install state for a single unmanagfed solution including any pending upgrade
# Managed:bool, Version:string, PendingUpgradeVersion:string, SolutionId:Guid
function getInstalledSolutionVersion([Parameter(Mandatory)][string] $uniquename) {
    $solutions = getInstalledSolutions

    $mainsolution = $solutions | where-object { $_."Unique Name" -eq $uniquename }
    $holdingsolution = $solutions | where-object { $_."Unique Name" -eq $uniquename + "_Upgrade" }

    return [PSCustomObject]@{
        Managed               = if ($mainsolution) { $mainsolution.Managed };
        Version               = if ($mainsolution) { $mainsolution.Version };
        PendingUpgradeVersion = if ($holdingsolution) { $holdingsolution.Version };
        SolutionId            = if ($mainsolution) { $mainsolution."Solution Id" };
    }
}

function removeUnmanagedCustomisations(
    [Parameter(Mandatory)][string] $solutionname
) {
    write-host "##[group]Checking for unmanaged customisations for solution ID $solutionname"

    $solutionid = (getInstalledSolutionVersion $solutionname).SolutionId

    &{
        getRestQueryResults -query "msdyn_solutioncomponentsummaries?`$filter=msdyn_solutionid%20eq%20${solutionid}";
        getRestQueryResults -query "msdyn_solutioncomponentsummaries?`$filter=msdyn_solutionid%20eq%20${solutionid} and msdyn_componenttype eq 1" | foreach-object {
            $tablename = $_.msdyn_name
            getRestQueryResults -query "msdyn_solutioncomponentsummaries?`$filter=(msdyn_solutionid eq ${solutionid}) and (msdyn_componenttype eq 2 or msdyn_componenttype eq 10 or msdyn_componenttype eq 3 or msdyn_componenttype eq 14 or msdyn_componenttype eq 60 or msdyn_componenttype eq 26 or msdyn_componenttype eq 59 or msdyn_componenttype eq 29 or msdyn_componenttype eq 22) and (msdyn_primaryentityname eq '$tablename')"
        }
   
    } | where-object { $_.msdyn_ismanaged -eq "1" -and $_.msdyn_hasactivecustomization } | foreach-object {
        $componentid = [guid] $_.msdyn_objectid
        $componenttype = $_.msdyn_componentlogicalname

        if (-not $componenttype.Contains("_")) {
            $componenttype = ( Get-Culture ).TextInfo.ToTitleCase( $componenttype )
        }

        $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "msdyn_componentlayer"
        $query.Criteria.AddCondition("msdyn_solutionname", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, "Active");

        $query.Criteria.AddCondition("msdyn_solutioncomponentname", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $componenttype);
        
        
        $query.Criteria.AddCondition("msdyn_componentid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $componentid);
        $query.ColumnSet = new-object Microsoft.Xrm.Sdk.Query.ColumnSet $true
    
        if ( (getQueryResults $query | Where-Object { $_ -and $_["msdyn_overwritetime"].Year -eq 1900 } )) {       
            write-warning "Removing unmanaged customisations for $componenttype $componentid $($_.msdyn_name) '$($_.msdyn_displayname)'"

            $request = New-Object Microsoft.Xrm.Sdk.OrganizationRequest "RemoveActiveCustomizations"
            $request.Parameters["SolutionComponentName"] = $componenttype
            $request.Parameters["ComponentId"] = $componentid

            try {
            (getglobalcrmconnection).Execute($request)
            }
            catch {
                $_ | Write-Warning
            }
        }
    }

    write-host "##[endgroup]"
}

# Returns the solution file manifest from a solution zip file.
function getSolutionFolderManifest([Parameter(Mandatory)][string] $solutionfolder) {

    $manifestpath = join-path $solutionfolder "Other/Solution.xml"
    $solutionxml = [xml] (get-content -raw $manifestpath)
    return $solutionxml.ImportExportXml.SolutionManifest
}

# Returns the solution file manifest from a solution zip file.
function getSolutionFileManifest([Parameter(Mandatory)][string] $solutionfile) {
    add-type -assembly System.IO.Compression.FileSystem
    $zipfile = [System.IO.Compression.ZipFile]::Open($solutionfile, "Read")

    try {
        $stream = $zipfile.GetEntry("solution.xml").Open()
        $reader = new-object System.IO.StreamReader $stream
        $solutionxml = [xml] ($reader.ReadToEnd())
        return $solutionxml.ImportExportXml.SolutionManifest

    }
    finally {
        $zipfile.Dispose()
    }
}


# Replaces $(Placeholders) in a template string with values from env vars.
# An error if thrown if any key does not exist in the config.
function replaceEnvVarPlaceholders([Parameter(Mandatory)][string]$template) {

    [System.Text.RegularExpressions.Regex]::Replace($template, '(?<!^#.*)\$\((?<name>[^\)]+)\)', {
            param([System.Text.RegularExpressions.Match] $match)
            $name = $match.Groups["name"].Value
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                throw "Env var value '$name' not found";
            }

            return [Environment]::GetEnvironmentVariable($name);
        }, [Text.RegularExpressions.RegexOptions]::Multiline)   
}

# Replaces $(Placeholders) in a template string with values from the config hashtable.
# An error if thrown if any key does not exist in the config.
function replaceConfigPlaceholders([Parameter(Mandatory)][string]$template, [Parameter(Mandatory)][hashtable] $config) {

    [System.Text.RegularExpressions.Regex]::Replace($template, '(?<!^#.*)\$\((?<name>[^\)]+)\)', {
            param([System.Text.RegularExpressions.Match] $match)
            $name = $match.Groups["name"].Value
            if (-not $config.ContainsKey($name)) {
                throw "Config value '$name' not found";
            }

            return $config[$name];
        }, [Text.RegularExpressions.RegexOptions]::Multiline)   
}

# Takes a template portal deployment profile containing $(Placeholders) and substitutes in values from the provided config hash.
# The resulting file is written to output path.
# An error is thrown if the template references any key not available in the config.
function createPortalDeploymentProfile([Parameter(Mandatory)][string]$templatepath, [Parameter(Mandatory)][string] $outputpath, [Parameter(Mandatory)][hashtable] $config) {
    write-host "Creating portal deployment profile at $outputpath"
    $template = get-content -raw $templatepath
    $outputfolder = split-path $outputpath
    if (-not (test-path $outputfolder)) {
        new-item -type Directory $outputfolder
    }
    $results = replaceConfigPlaceholders -template $template -config $config
    $results | out-file $outputpath
}

# Deploys the Portal config from "path" using the provided config hash.
# A deployment-profile-template.yml must exist alongside the provided path. The config provided is used to fill in the template (see: createPortalDeploymentProfile)
function deployPortal([Parameter(Mandatory)][string]$path, [Parameter(Mandatory)][hashtable] $config) {

    $templatepath = "$(split-path $path)/deployment-profile-template.yml"
    $profilepath = "$path/deployment-profiles/current.deployment.yml"

    write-host "##[group]Creating portal deployment profile"

    createPortalDeploymentProfile -templatepath $templatepath -outputpath $profilepath -config $config
    write-host "##[endgroup]"

    write-host "##[group]Deploying portal config"

    pac paportal upload --path $path --deploymentProfile current
    if (-not $? -or $LASTEXITCODE -ne 0) {
        throw "PAC PAPORTAL UPLOAD failed"
    }

    write-host "##[endgroup]"

    # write-host "##[group]Deleting obsolete portal config records"

    # deployPortalDeleteUnneededRecords -path $path
}

# Finds records that no longer exist in config data and deletes them.
function deployDatasetDeleteUnneededRecords([Parameter(Mandatory)][string]$path) {

    if ($path.EndsWith(".zip")) {
        
        add-type -assembly System.IO.Compression.FileSystem
        $zipfile = [System.IO.Compression.ZipFile]::Open($path, "Read")
    
        try {
            $stream = $zipfile.GetEntry("data.xml").Open()
            $reader = new-object System.IO.StreamReader $stream
            $dataxml = [xml] ($reader.ReadToEnd())

            $stream = $zipfile.GetEntry("data_schema.xml").Open()
            $reader = new-object System.IO.StreamReader $stream
            $schemaxml = [xml] ($reader.ReadToEnd())
        }
        finally {
            $zipfile.Dispose()
        }
        
    }
    else {
        $dataxml = [xml] (get-content -raw $path/data.xml)
        $schemaxml = [xml] (get-content -raw $path/data_schema.xml)
    }

    foreach ($entity in $dataxml.entities.entity) {

        write-host "Processing deletion for table '$($entity.name)'"

        $schemaentity = $schemaxml.entities.entity | where-object { $_.name -eq $entity.name }

        if ($entity.name -eq "businessunit" -or $entity.name -eq "team" -or $schemaentity.SelectSingleNode("filter")) {
            write-warning "...Failed: Table not supported"
            continue;
        }

        $keepids = $entity.records.record | Select-Object -ExpandProperty id
        deleteAllRecordsExcept -tablename $entity.name -keepids $keepids
    }
}

# Finds records that no longer exist in portal config data and deletes them.
function deployPortalDeleteUnneededRecords([Parameter(Mandatory)][string]$path) {

    $manifestfile = resolve-path $path/.portalconfig/*-manifest.yml

    $excludetables = @("annotation", "adx_websitelanguage")

    #Brute force way of parsing the YAML. YAML.NET was much too slow.
    $recordsbytable = (get-content $manifestfile | foreach-object {
  
            $newtablename = $_ | select-string -pattern "^(\w+):" -AllMatches | foreach-object -MemberName Matches | foreach-object { $_.Groups[1].Value }  
  
            if ($newtablename) {
                $tablename = $newtablename
            }
            else {
                $recordid = $_ | select-string -pattern "- RecordId: (.+)" -AllMatches | foreach-object -MemberName Matches | foreach-object { $_.Groups[1].Value }  
                if ($recordid -and $excludetables -notcontains $tablename) {
                    [PSCustomObject] (@{Table = $tablename; Id = [guid] $recordid })
                }
            }
        }) | Group-Object -Property Table

    $recordsbytable | foreach-object {
        write-host "Processing portal config data deletions for table $($_.name)"

        $keepids = $_.Group | Select-Object -ExpandProperty Id
        deleteAllRecordsExcept -tablename $_.name -keepids $keepids
    }
}

# Deletes all records in the given Dataverse table except those having PKs in the list of keep ids.
function deleteAllRecordsExcept([Parameter(Mandatory)][string] $tablename, [Parameter(Mandatory)][guid[]] $keepids) {
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression $tablename

    $connection = getGlobalCrmConnection
    $connection.RetrieveMultiple($query).Entities | foreach-object {
        $id = $_.Id
        if ($keepids -notcontains $id) {
            write-host "Deleting $id"

            try {
                $connection.Delete($tablename, $id)
            }
            catch {
                if (!$_.ToString().Contains("The 'Delete' method does not support entities")) {
                    throw
                }
                else {
                    Write-Warning "...Failed! M:M tables not yet supported"
                }
            }
        }
    }
}

function deploySolutionSet([string[]] $solutionfiles, [string] $description) {
        
    $connectionReferences = @{}

    # Find all env vars prefixed with "DataverseConnRef_" to set as connection references
    Get-ChildItem Env: | Where-Object { $_.Name -like "DataverseConnRef_*" } | ForEach-Object {
        $connRefName = $_.Name.Substring(17) # Remove "DataverseConnRef_" prefix
        $connectionReferences[$connRefName] = $_.Value
    }

    $environmentVariables = @{}

    # Find all env vars prefixed with "DataverseEnvVar_" to set as environment variables
    Get-ChildItem Env: | Where-Object { $_.Name -like "DataverseEnvVar_*" } | ForEach-Object {
        $envVarName = $_.Name.Substring(16) # Remove "DataverseEnvVar_" prefix
        $environmentVariables[$envVarName] = $_.Value
    }
    
    Write-Host "##[section]Installing solutions"
    $connectionReferences.GetEnumerator() | ForEach-Object {
        Write-Host "##[debug]Connection Reference: $($_.Key) = $($_.Value)"
    }
    $environmentVariables.GetEnumerator() | ForEach-Object {
        Write-Host "##[debug]Environment Variable: $($_.Key) = $($_.Value)"
    }
    foreach ($solutionfile in $solutionfiles) {
        Write-Host "##[group]Installing $description solution from file: $solutionfile"

        Import-DataverseSolution `
            -Verbose `
            -InFile $solutionfile `
            -Mode "Auto" `
            -TimeoutSeconds 600 `
            -EnvironmentVariables $environmentVariables `
            -ConnectionReferences $connectionReferences `
            -OverwriteUnmanagedCustomizations `
            -SkipIfSameVersion
        Write-Host "##[endgroup]"
    }
}


# Deploys the configuration migration tool dataset provided as a zip file or data folder
function deployDataset([Parameter(Mandatory)][string] $datapath) {   
    write-host "##[group]Deploying data set from $datapath"

    if (-not (test-path $datapath)) {
        # Use data folder - development
        $datapath = join-path (split-path $datapath) ([IO.Path]::GetFileNameWithoutExtension($datapath))
    }

    pac data import --data $datapath --verbose 
    if (-not $? -or $LASTEXITCODE -ne 0) {
        throw "PAC DATA IMPORT failed"
    }

    deployDatasetDeleteUnneededRecords -path $datapath
    write-host "##[endgroup]"
}