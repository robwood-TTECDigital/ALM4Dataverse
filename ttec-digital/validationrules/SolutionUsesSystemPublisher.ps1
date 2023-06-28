param($context)

# Check if the solution uses a publisher created by SYSTEM
$sql = @"
SELECT 
    s.uniquename AS SolutionName,
    p.friendlyname AS PublisherName,
    createdby.fullname AS CreatedBy
FROM solution s
INNER JOIN publisher p ON s.publisherid = p.publisherid
INNER JOIN systemuser createdby ON p.createdby = createdby.systemuserid
WHERE s.uniquename = @solutionname
    AND createdby.fullname = 'SYSTEM'
"@

$results = Invoke-DataverseSQL -Sql $sql -Parameters @{
    solutionname = $context.solutionname
}

$results | ForEach-Object {
    # Check if this validation should be skipped (solution-level check, use solution name as componentid)
    $mode = getValidationRuleMode -ruleName 'SolutionUsesSystemPublisher' -componentId $context.solutionname -componentType 0 -componentSchemaName $context.solutionname -solutionconfig $context.solutionconfig
    
    # Override with rule-level mode if it's warning
    if ($context.ruleMode -eq 'warning' -and $mode -eq 'error') {
        $mode = 'warning'
    }
    
    if ($mode -eq 'skip') {
        return
    }
    
    writeResult -type "SolutionUsesSystemPublisher" `
        -componentid $context.solutionname `
        -message "Solution uses a publisher created by SYSTEM" `
        -asWarning ($mode -eq 'warning')
}