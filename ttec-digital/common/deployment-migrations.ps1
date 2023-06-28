

<#
.SYNOPSIS
    Applies database schema migration scripts in the correct order.

.DESCRIPTION
    This function scans a folder for migration scripts, sorts them by version number in the filename,
    ensures each script is executed only once per environment by checking a tracking table,
    and records the execution in the tracking table.

    These scripts are used to modify data during solution upgrades. For instance to move data from
    deprecated fields to new fields.

    These are executed in between staging and upgrading solutions during deployment when both old and new solutions are present.


.PARAMETER scriptsfolder
    The path to the folder containing the migration scripts. Each script filename must start with a version number (e.g., 1.0.1 MyMigration.ps1).

.PARAMETER connection
    The Dataverse connection object to use for operations. Defaults to the global CRM connection.

.EXAMPLE
    applyMigrations -scriptsfolder "C:\Migrations"
#>
function applyMigrations([Parameter(Mandatory)][string] $scriptsfolder, $connection = (getGlobalCrmConnection) ) {

    # Start a logging group for schema migration scripts
    write-host "##[group]Running schema migration scripts"

    # Log that we're ensuring the tracking solution is installed
    write-host "Ensuring tracking solution is installed"

    # Ensure the solution containing the tracking table is installed
    Import-DataverseSolution -Verbose -InFile $PSScriptRoot/../tools/SchemaMigrationTracking/SchemaMigrationTracking_managed.zip  -UseUpdateIfVersionMajorMinorMatches -SkipIfSameVersion

    # Query the tracking table to get list of scripts already executed in this environment
    $query = [Microsoft.Xrm.Sdk.Query.QueryExpression]::new("ttec_schemamigrationscriptexecutionhistory")
    $query.ColumnSet.AddColumn("ttec_scriptname")

    $scriptsalreadyapplied = @(getQueryResults $query | foreach-object { $_["ttec_scriptname"]})

    # Get all migration scripts, parse their version numbers, sort by version, filter out already applied ones, and execute them
    Get-ChildItem $scriptsfolder | ForEach-Object {
        # Parse the version number from the filename using regex
        $versionmatch = [Regex]::Match( $_.Name, "^(?'version'[0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?)\b.*$")
        if (-not $versionmatch.Success) {
            write-error "Version number not found in filename '$($_.Name)'. Migration scripts should be prefixed with a version number. For example `"1.0.1 Somename.ps1`""
        }
        $version = [version] $versionmatch.Groups["version"].Value
        # Create a hashtable with version and file for sorting
        @{Version = $version; File = $_ }
    } `
    | Sort-Object Version `
    | Select-Object -ExpandProperty File `
    | Where-Object {
        # Filter out scripts that have already been applied
        $scriptsalreadyapplied -notcontains $_.Name
    } `
    | ForEach-Object {

        # Log the execution of the script
        write-host "Executing script '$($_.Name)'"

        # Prepare arguments for the script (pass the connection)
        $scriptargs = @{"connection" = $connection }

        # Execute the migration script
        & $_.FullName @scriptargs

        # Record the execution in the tracking table
        $newhistory = [Microsoft.Xrm.Sdk.Entity]::new("ttec_schemamigrationscriptexecutionhistory")
        $newhistory["ttec_scriptname"] = $_.Name
        $connection.Create($newhistory)
    }

    # End the logging group
    write-host "##[endgroup]"
}