
function ensureAppUser([guid] $applicationid, [string] $businessunitname, [string[]] $rolenames) {
    
    $connection = getGlobalCrmConnection

    # Finds existing team with the specified name/ID in the given BU.
    function getExistingUser([guid] $applicationid) {
        $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "systemuser"
        $query.ColumnSet.AddColumns("applicationid")
        $query.ColumnSet.AddColumns("fullname")
        $query.Criteria.AddCondition("applicationid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $applicationid)
        
            $user = $connection.RetrieveMultiple($query).Entities | select-object -first 1
        return $user
    }

    $bu = getBU -connection $connection $businessunitname
    $user = getExistingUser -applicationid $applicationid

    if (-not $user) {
        write-host "Creating application user with ID $applicationid"
        $user = new-object Microsoft.Xrm.Sdk.Entity "systemuser"
        $user["applicationid"] = $applicationid
        $user["businessunitid"] = $bu.ToEntityReference()
        $user.Id = $connection.Create($user)
    } else {
        write-host "Using existing systemuser $($user.Id) - $($user["fullname"]) for application ID $applicationid"
    }

    $existingroleids = getSystemUserRoleIds -systemuserid $user.Id

    $neededroleids = $rolenames | foreach-object { getRoleId -connection $connection -rolename $_ -businessunitid $bu.Id}

    $rolesidstoremove = @($existingroleids | where-object { $neededroleids -notcontains $_ })
    $rolesidstoadd = @($neededroleids | where-object { $existingroleids -notcontains $_ })

    $rolereln = (new-object Microsoft.Xrm.Sdk.Relationship "systemuserroles_association")

    if ($rolesidstoadd.Length) {
        write-host "Granting roles $rolesidstoadd to systemuser $($user.Id)"
        $rolerefstoadd = new-object Microsoft.Xrm.Sdk.EntityReferenceCollection

        $rolesidstoadd | foreach-object {
            $rolerefstoadd.Add((new-object Microsoft.Xrm.Sdk.EntityReference "role", $_))
        }
        
        $connection.Associate("systemuser", $user.Id, $rolereln, $rolerefstoadd)
    }

    if ($rolesidstoremove.Length) {
        write-host "Removing roles $rolesidstoremove from systemuser $($user.Id)"
        $rolerefstoremove = new-object Microsoft.Xrm.Sdk.EntityReferenceCollection

        $rolesidstoremove | foreach-object {
            $rolerefstoremove.Add((new-object Microsoft.Xrm.Sdk.EntityReference "role", $_))
        }
        $connection.Disassociate("systemuser", $user.Id, $rolereln, $rolerefstoremove)
    }
}

function getSystemUserRoleIds($systemuserid) {
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "systemuserroles"
    $query.ColumnSet.AddColumns("roleid")
    $query.Criteria.AddCondition("systemuserid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $systemuserid)

    return @($connection.RetrieveMultiple($query).Entities | foreach-object { $_["roleid"] })
}