# Schema Migration Tracking

The Schema Migration Tracking feature provides a mechanism to execute database schema migration scripts in a controlled, versioned manner during Dataverse solution deployments. It ensures that each migration script runs exactly once per environment and maintains a history of executed migrations.

## Overview

Schema migrations are PowerShell scripts that modify data during solution upgrades. Common use cases include:
- Moving data from deprecated fields to new fields
- Transforming data to match new data models
- Populating new required fields with default or calculated values
- Cleaning up orphaned records after schema changes

The tracking system ensures:
- Scripts execute in the correct version order
- Each script runs only once per environment
- Execution history is persisted in Dataverse
- Failed scripts prevent deployment from continuing

## How It Works

### Execution Flow

Schema migrations execute during the **DEPLOY** pipeline in a specific sequence:

1. **Solution Staging**: All solutions are imported in "holding" state
2. **Migration Execution**: Schema migration scripts run (both old and new solutions are present)
3. **Solution Upgrade**: Solutions are upgraded to their new versions
4. **Publish Customizations**: Changes are published

This timing is critical because migration scripts often need access to both old and new schema elements simultaneously to safely move data.

### Tracking Solution

The system uses a managed Dataverse solution called **SchemaMigrationTracking** that contains a custom table: `ttec_schemamigrationscriptexecutionhistory`

**Table Schema:**
- **ttec_scriptname** (text): The exact filename of the migration script

Before executing migrations, the tracking solution is automatically installed or updated in the target environment.

### Script Discovery and Execution

The `applyMigrations` function:

1. Ensures the tracking solution is installed
2. Queries `ttec_schemamigrationscriptexecutionhistory` to get the list of previously executed scripts
3. Scans the specified scripts folder for migration files
4. Parses version numbers from filenames
5. Sorts scripts by version (ascending)
6. Filters out already-executed scripts
7. Executes remaining scripts in order
8. Records each successful execution in the tracking table

## Configuration

### Default Configuration

The schema migration tracking feature is **already configured by default** in the TTEC Digital fork. The `alm-config-defaults.psd1` file includes:

This means you don't need to configure anything in your `alm-config.psd1` to enable the feature.

### Create Migration Scripts

Simply create a `migrations/` folder in your repository root and add your migration scripts following the naming convention described below.

**Example folder structure:**

```
migrations/
  1.0.0 InitialSetup.ps1
  1.0.1 MigrateContactData.ps1
  1.2.0 UpdateAccountCategories.ps1
```

The default hook script will automatically discover and execute these migration scripts during deployment.

### Script Naming Convention

Migration scripts **must** follow this naming pattern:

```
<version> <description>.ps1
```

**Examples:**
- `1.0.0 InitialSetup.ps1`
- `1.0.1 MigrateContactAddresses.ps1`
- `1.2.0 ConvertPhoneNumbers.ps1`
- `2.0.0.1 FixAccountOwnership.ps1`

**Version Format:**
- Must be parseable as a .NET `System.Version`
- Supports 2, 3, or 4 part version numbers
- Scripts are sorted using version comparison (e.g., `1.0.10` comes after `1.0.9`)

**Invalid Names:**
```
MyScript.ps1                    # Missing version
v1.0.1 MyScript.ps1            # "v" prefix not allowed
1.0 - MyScript.ps1             # Dash immediately after version
```

## Writing Migration Scripts

### Script Template

Migration scripts use the `Invoke-DataverseSql` cmdlet from the `Rnwood.Dataverse.Data.PowerShell` module, which provides a high-performance SQL interface to Dataverse using the Sql4Cds engine.

```powershell
<#
.SYNOPSIS
    Brief description of what this migration does

.DESCRIPTION
    Detailed description of the data transformation or schema change

.PARAMETER connection
    The Dataverse connection object (automatically provided by applyMigrations)
#>
param(
    [Parameter(Mandatory)]
    $connection
)

# Your migration logic here using Invoke-DataverseSql
Write-Host "Starting migration: Moving legacy_field data to new_field"

# UPDATE example - Move data from one field to another
Invoke-DataverseSql -Sql @"
    UPDATE account
    SET new_field = legacy_field
    WHERE new_field IS NULL
      AND legacy_field IS NOT NULL
"@ -Connection $connection

Write-Host "Migration completed"
```

### Script Parameters

Each migration script receives:
- **$connection**: A Dataverse connection object (CRM service client) that can be passed to `Invoke-DataverseSql` and other Dataverse cmdlets

### Using Invoke-DataverseSql

The `Invoke-DataverseSql` cmdlet provides a SQL interface to Dataverse with these key features:

- **Familiar SQL syntax**: Use standard SQL for SELECT, UPDATE, DELETE, and INSERT operations
- **Parameterized queries**: Prevent injection and improve performance
- **Batch operations**: Use `-BatchSize` to control batch sizes for better performance
- **Parallelism**: Use `-MaxDegreeOfParallelism` for concurrent operations
- **Plugin bypass**: Use `-BypassCustomPluginExecution` to skip custom plugins when appropriate
- **TDS endpoint**: Use `-UseTdsEndpoint` for read-only queries that can use the TDS endpoint

**Key Parameters:**
- `-Sql`: The SQL query to execute
- `-Parameters`: Hashtable of parameter values
- `-Connection`: The Dataverse connection (pass the `$connection` parameter)
- `-BatchSize`: Number of records per batch (default varies by operation)
- `-MaxDegreeOfParallelism`: Number of parallel threads
- `-BypassCustomPluginExecution`: Skip custom plugins for better performance

### Best Practices

1. **Idempotency**: Design scripts to be safely re-runnable even though the tracking system prevents duplicate execution
2. **Logging**: Use `Write-Host` to output progress for pipeline visibility
3. **Error Handling**: Let exceptions propagate to fail the deployment if the migration cannot complete
4. **Batch Processing**: Use `-BatchSize` parameter for large datasets
5. **Parallelism**: Use `-MaxDegreeOfParallelism` for better performance on large updates
6. **Performance**: Add WHERE clauses to limit the working set
7. **Testing**: Test migrations in a development environment first
8. **Documentation**: Include clear comments explaining what data is being transformed and why
9. **Plugin bypass**: Consider using `-BypassCustomPluginExecution` when custom plugin logic isn't needed

### Example: Moving Data Between Fields

```powershell
param($connection)

Write-Host "Migrating phone numbers from old format to new format"

# Update in a single SQL statement - more efficient than SDK
$rowsAffected = Invoke-DataverseSql -Sql @"
    UPDATE contact
    SET new_phonenumber = telephone1
    WHERE telephone1 IS NOT NULL
      AND new_phonenumber IS NULL
"@ -Connection $connection -BatchSize 100 -MaxDegreeOfParallelism 4

Write-Host "Migration complete: Updated $rowsAffected contacts"
```

### Example: Populating New Required Fields

```powershell
param($connection)

Write-Host "Populating new required category field with default value"

# Set default category (optionset value 1) for all accounts missing it
Invoke-DataverseSql -Sql @"
    UPDATE account
    SET new_category = 1
    WHERE new_category IS NULL
"@ -Connection $connection

Write-Host "Set default category for all applicable accounts"
```

### Example: Complex Data Transformation with Parameterized Query

```powershell
param($connection)

Write-Host "Migrating opportunities based on probability threshold"

# Get high-probability opportunities and update their status
$results = Invoke-DataverseSql -Sql @"
    SELECT opportunityid, name, closeprobability
    FROM opportunity
    WHERE closeprobability >= @threshold
      AND statecode = 0
"@ -Parameters @{
    threshold = 75
} -Connection $connection

Write-Host "Found $($results.Count) opportunities to migrate"

# Update status in batch
Invoke-DataverseSql -Sql @"
    UPDATE opportunity
    SET new_prioritystatus = 100000001
    WHERE closeprobability >= @threshold
      AND statecode = 0
"@ -Parameters @{
    threshold = 75
} -Connection $connection -BatchSize 100 -BypassCustomPluginExecution

Write-Host "Migration complete"
```

### Example: Conditional Migration with Multiple Criteria

```powershell
param($connection)

Write-Host "Consolidating contact addresses"

# Migrate address data with multiple conditions
Invoke-DataverseSql -Sql @"
    UPDATE contact
    SET new_fulladdress = address1_line1 + ', ' + address1_city + ', ' + address1_stateorprovince
    WHERE address1_line1 IS NOT NULL
      AND address1_city IS NOT NULL
      AND new_fulladdress IS NULL
"@ -Connection $connection -MaxDegreeOfParallelism 8

Write-Host "Address consolidation complete"
```

## Folder Structure

Recommended repository structure:

```
migrations/
  1.0.0 InitialSetup.ps1
  1.0.1 MigrateContactData.ps1
  1.0.2 UpdateAccountCategories.ps1
  1.1.0 ConvertPhoneNumbers.ps1
  2.0.0 MajorSchemaChange.ps1
```

The default hook script `[alm]/ttec-digital/solution-upgrade-migrations.ps1` automatically looks for a `migrations/` folder in your repository root.

## Tracking Table Details

**Logical Name**: `ttec_schemamigrationscriptexecutionhistory`

**Fields**:
- **ttec_scriptname** (text, 200 characters): Stores the complete filename of the executed script
- Plus standard Dataverse fields (createdon, modifiedon, ownerid, etc.)

**Key Characteristics**:
- No uniqueness constraint - tracking relies on script names being unique
- Records are never deleted - permanent audit trail
- Owned by the user running the deployment

## Pipeline Integration

The `applyMigrations` function is called from the `dataMigrations` hook, which executes:

1. After all solutions are staged (imported in holding state)
2. Before solutions are upgraded
3. Before customizations are published

This is implemented in the deployment pipeline's sequence:

```
preDeploy hooks → Stage Solutions → dataMigrations hooks → Upgrade Solutions → postDeploy hooks
```

## Related Documentation

- [Solution Validation](solution-validation.md)
- [ALM Configuration](../../docs/config/alm-config.md)
