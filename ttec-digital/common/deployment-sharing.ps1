function shareCanvasApp(
    [Parameter(Mandatory)] [string] $uniquename,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [guid[]] $aadgroupids,
    [Parameter(Mandatory)][string] $serviceaccountupn,
    [string] $serviceaccountpassword,
    [string] $serviceaccounttotpsecret
) {

    $connection = (getGlobalCrmConnection)
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "canvasapp"
    $query.ColumnSet.AddColumns("canvasappid")
    $query.ColumnSet.AddColumns("uniquecanvasappid")
    $query.Criteria.AddCondition("name", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $uniquename)
    
    $app = $connection.RetrieveMultiple($query).Entities | select-object -first 1
    if (-not $app) {
        throw "Canvas App with unique name '$uniquename' was not found"
    }

    $appname = $app["canvasappid"]
    if ($app.Contains("uniquecanvasappid")) {
        $appname = $app["uniquecanvasappid"]
    }

    $environmentid = getEnvironmentId

    foreach ($aadgroupid in $aadgroupids) {
        write-host "Sharing Canvas app $uniquename ($appname) with AAD group $aadgroupid"

        Set-AdminPowerAppRoleAssignment -PrincipalType Group -PrincipalObjectId $aadgroupid -RoleName "CanView" -AppName $appname -EnvironmentName $global:PowerAppsAdminEnvironmentId  | out-null
    }

    @(Get-AdminPowerAppRoleAssignment -EnvironmentName $global:PowerAppsAdminEnvironmentId -AppName $appname) | Where-Object { 
        $_ -and 
        $_.PrincipalType -eq "Group" -and $aadgroupids -notcontains ([guid] $_.PrincipalObjectId) } |
    Foreach-Object {
        write-host "Removing sharing of Canvas app $uniquename with AAD group $($_.PrincipalObjectId)"
        Remove-AdminPowerAppRoleAssignment -EnvironmentName $global:PowerAppsAdminEnvironmentId -AppName $appname -roleid $_.RoleId | out-null
    }
    

}

function shareFlow(
    [Parameter(Mandatory)] [guid] $workflowid,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [guid[]] $aadgroupids
) {
    $connection = (getGlobalCrmConnection)
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "workflow"
    $query.ColumnSet.AddColumns("workflowid")
    $query.ColumnSet.AddColumns("workflowidunique")
    $query.Criteria.AddCondition("workflowid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $workflowid)
    
    $workflow = $connection.RetrieveMultiple($query).Entities | select-object -first 1
    if (-not $workflow) {
        throw "Workflow with unique name '$uniquename' was not found"
    }

    $flowname = $workflow["workflowid"]
    if ($workflow.Contains("workflowidunique")) {
        $flowname = $workflow["workflowidunique"]
    }

    foreach ($aadgroupid in $aadgroupids) {

        write-host "Sharing Flow $workflowid with AAD group $aadgroupid"

        Set-AdminFlowOwnerRole -PrincipalType Group -PrincipalObjectId $aadgroupid -RoleName "CanView" -Flowname $flowname -EnvironmentName $global:PowerAppsAdminEnvironmentId  | out-null
    }

    @(Get-AdminFlowOwnerRole -EnvironmentName $global:PowerAppsAdminEnvironmentId -flowname $flowname) |
    Where-Object { $_ -and $_.PrincipalType -eq "Group" -and $aadgroupids -notcontains ([guid] $_.PrincipalObjectId) } |
    Foreach-Object {
        write-host "Removing sharing of Flow $workflowid with AAD group $($_.PrincipalObjectId)"
        Remove-AdminFlowOwnerRole -EnvironmentName $global:PowerAppsAdminEnvironmentId -flowname $flowname -roleid $_.RoleId | out-null
    }

}