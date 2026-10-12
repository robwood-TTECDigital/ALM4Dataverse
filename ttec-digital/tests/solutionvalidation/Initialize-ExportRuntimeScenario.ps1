param(
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$SolutionName = 'TestSolution1',
    [ValidateRange(1, 50)]
    [int]$TextColumnCount = 6,
    [ValidateRange(2, 50)]
    [int]$LookupColumnCount = 6,
    [switch]$IncludeValidationViolations
)

$ErrorActionPreference = 'Stop'
Import-Module Rnwood.Dataverse.Data.PowerShell
$connection = Get-DataverseConnection -GetDefault
if (-not $connection.IsReady) {
    throw 'Connect first with Get-DataverseConnection -Interactive -Url <environment-url> -SetAsDefault.'
}

$solution = @(Invoke-DataverseSQL -Sql @'
SELECT s.solutionid, p.uniquename AS publishername, p.customizationprefix
FROM solution s INNER JOIN publisher p ON s.publisherid = p.publisherid
WHERE s.uniquename = @name
'@ -Parameters @{ name = $SolutionName })
if ($solution.Count -ne 1) {
    throw "Solution '$SolutionName' was not found uniquely."
}

$prefix = $solution[0].customizationprefix
$consumerTableName = "${prefix}_almruntimeconsumer"
$sharedTableName = "${prefix}_almruntimeshared"
$dependencySolutionName = "${SolutionName}RuntimeDependencies"

$dependencySolution = @(Invoke-DataverseSQL -Sql 'SELECT solutionid FROM solution WHERE uniquename = @name' -Parameters @{ name = $dependencySolutionName })
if ($dependencySolution.Count -eq 0) {
    Set-DataverseSolution -UniqueName $dependencySolutionName -Name 'Export Runtime Dependencies' `
        -Description "Shared table for the $SolutionName export runtime scenario." `
        -PublisherUniqueName $solution[0].publishername
}

foreach ($table in @(
    @{ Name = $sharedTableName; DisplayName = 'ALM Runtime Shared'; SolutionName = $dependencySolutionName },
    @{ Name = $consumerTableName; DisplayName = 'ALM Runtime Consumer'; SolutionName = $SolutionName }
)) {
    Write-Host "Setting up table '$($table.Name)' in '$($table.SolutionName)'..."
    Set-DataverseEntityMetadata -EntityName $table.Name -SchemaName $table.Name `
        -DisplayName $table.DisplayName -DisplayCollectionName "$($table.DisplayName) Records" `
        -Description 'Disposable export runtime validation fixture.' -OwnershipType OrganizationOwned `
        -PrimaryAttributeSchemaName "${prefix}_name" -PrimaryAttributeDisplayName Name
    $metadata = Get-DataverseEntityMetadata -EntityName $table.Name
    Set-DataverseSolutionComponent -SolutionName $table.SolutionName -ComponentId $metadata.MetadataId -ComponentType 1 -Behavior 1
    $primaryAttribute = Get-DataverseAttributeMetadata -EntityName $table.Name -AttributeName $metadata.PrimaryNameAttribute
    Set-DataverseSolutionComponent -SolutionName $table.SolutionName -ComponentId $primaryAttribute.MetadataId -ComponentType 2
}

foreach ($columnIndex in 1..$TextColumnCount) {
    $columnName = "${prefix}_runtime_text$columnIndex"
    $attribute = Set-DataverseAttributeMetadata -EntityName $consumerTableName -AttributeName $columnName `
        -SchemaName $columnName -DisplayName "Runtime Text $columnIndex" -AttributeType String -MaxLength 100 -PassThru
    Set-DataverseSolutionComponent -SolutionName $SolutionName -ComponentId $attribute.MetadataId -ComponentType 2
}

foreach ($columnIndex in 1..$LookupColumnCount) {
    $columnName = "${prefix}_runtime_shared$columnIndex"
    $relationshipName = "${prefix}_almruntime_shared_consumer$columnIndex"
    $attribute = Get-DataverseAttributeMetadata -EntityName $consumerTableName -AttributeName $columnName -ErrorAction SilentlyContinue
    if (-not $attribute) {
        $attribute = Set-DataverseAttributeMetadata -EntityName $consumerTableName -AttributeName $columnName `
            -SchemaName $columnName -DisplayName "Runtime Shared $columnIndex" -AttributeType Lookup `
            -Targets @($sharedTableName) -RelationshipSchemaName $relationshipName -PassThru
    } elseif ($attribute.Targets -notcontains $sharedTableName) {
        throw "Existing lookup '$columnName' does not target '$sharedTableName'."
    }
    Set-DataverseSolutionComponent -SolutionName $SolutionName -ComponentId $attribute.MetadataId -ComponentType 2
}

$consumerMetadata = Get-DataverseEntityMetadata -EntityName $consumerTableName
foreach ($relationship in $consumerMetadata.ManyToOneRelationships | Where-Object { $_.SchemaName -like "${prefix}_almruntime_shared_consumer*" }) {
    Set-DataverseSolutionComponent -SolutionName $SolutionName -ComponentId $relationship.MetadataId -ComponentType 10
}

if ($IncludeValidationViolations) {
    Set-DataverseSolutionComponent -SolutionName $dependencySolutionName -ComponentId $consumerMetadata.MetadataId -ComponentType 1 -Behavior 1
}

Publish-DataverseCustomizations -EntityName $sharedTableName
Publish-DataverseCustomizations -EntityName $consumerTableName

[pscustomobject]@{
    SolutionName = $SolutionName
    DependencySolutionName = $dependencySolutionName
    ConsumerTableName = $consumerTableName
    SharedTableName = $sharedTableName
    TextColumnCount = $TextColumnCount
    LookupColumnCount = $LookupColumnCount
    IncludeValidationViolations = [bool]$IncludeValidationViolations
}