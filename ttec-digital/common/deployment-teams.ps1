
function getBU($businessunitname, $connection) {
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "businessunit"
    $query.ColumnSet.AddColumns("businessunitid")
    if ($businessunitname) {
        $query.Criteria.AddCondition("name", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $businessunitname)
    } else {
        $query.Criteria.AddCondition("parentbusinessunitid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Null)
    }
    
    $bu = $connection.RetrieveMultiple($query).Entities | select-object -first 1
    if (-not $bu) {
        throw "BU with name '$businessunitname' was not found"
    }

    return $bu
}

# Gets the role ID for role with specified name in a given BU
function getRoleId($rolename, $businessunitid, $connection) {
    $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "role"
    $query.ColumnSet.AddColumns("roleid")
    $query.Criteria.AddCondition("name", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $rolename)
    $query.Criteria.AddCondition("businessunitid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $businessunitid)
    
    $role = $connection.RetrieveMultiple($query).Entities | select-object -first 1
    if (-not $role) {
        throw "Role with name '$rolename' not found"
    }
    return $role.Id
}

function ensureTeamInternal(
    [string] $businessunitname,
    [guid] $teamid,
    [string] 
    $teamname, 
    [guid] $aadgroupid,
    [string[]] $rolenames,
    [switch] $accessteam
) {

    $connection = (getGlobalCrmConnection)

    #Find BUID for given name, or if not specified, return the root BU

    # Get list of existing role IDs assocaited with a team
    function getTeamRoleIds($teamid) {
        $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "teamroles"
        $query.ColumnSet.AddColumns("roleid")
        $query.Criteria.AddCondition("teamid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $teamid)

        return @($connection.RetrieveMultiple($query).Entities | foreach-object { $_["roleid"] })
    }



    # Finds existing team with the specified name/ID in the given BU.
    function getExistingTeam($teamname, $businessunitid) {
        $query = new-object Microsoft.Xrm.Sdk.Query.QueryExpression "team"
        $query.ColumnSet.AddColumns("teamid")
        $query.ColumnSet.AddColumns("name")

        if ($teamid) {
            $query.Criteria.AddCondition("teamid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $teamid)
        } elseif ($teamname) {
            $query.Criteria.AddCondition("name", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $teamname)
        } else {
            $query.Criteria.AddCondition("isdefault", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $true)
            $query.Criteria.AddCondition("businessunitid", [Microsoft.Xrm.Sdk.Query.ConditionOperator]::Equal, $businessunitid)
   
        }
         $team = $connection.RetrieveMultiple($query).Entities | select-object -first 1
        return $team
    }

    $bu = getBU -connection $connection -businessunitname $businessunitname
    $team = getExistingTeam -teamname $teamname -businessunitid $bu.Id
   
    if (-not $team) {
        write-host "Creating team $teamname"
        $team = new-object Microsoft.Xrm.Sdk.Entity "team"
        if ($teamid) {
            $team.Id = $teamid
        }
        $team["name"] = $teamname

        if ($aadgroupid) {
            $team["teamtype"] = [Microsoft.Xrm.Sdk.OptionSetValue] (new-object Microsoft.Xrm.Sdk.OptionSetValue 2)
        }elseif ($accessteam) {
            $team["teamtype"] = [Microsoft.Xrm.Sdk.OptionSetValue] (new-object Microsoft.Xrm.Sdk.OptionSetValue 1)
        } else {
            $team["teamtype"] = [Microsoft.Xrm.Sdk.OptionSetValue] (new-object Microsoft.Xrm.Sdk.OptionSetValue 0)
        }
        if ($aadgroupid) {
            $team["azureactivedirectoryobjectid"] = [guid]$aadgroupid
        }
        $team["businessunitid"] = $bu.ToEntityReference()
        $team.Id = $connection.Create($team)
    } else {
        write-host "Using existing team $($team.Id) - $($team["name"]) for $teamname"
        $team["name"] = $teamname
        $team["businessunitid"] = $bu.ToEntityReference()
        $connection.Update($team)
    }

    if(-not $accessteam) {
        $neededroleids = $rolenames | foreach-object { getRoleId -connection $connection -rolename $_ -businessunitid $bu.Id}

        $existingteamroleids = @(getTeamRoleIds -teamid $team.Id)
        $rolesidstoremove = @($existingteamroleids | where-object { $neededroleids -notcontains $_ })
        $rolesidstoadd = @($neededroleids | where-object { $existingteamroleids -notcontains $_ })

        $rolereln = (new-object Microsoft.Xrm.Sdk.Relationship "teamroles_association")

        if ($rolesidstoadd.Length) {
            write-host "Granting roles $rolesidstoadd to team $teamname"
            $rolerefstoadd = new-object Microsoft.Xrm.Sdk.EntityReferenceCollection

            $rolesidstoadd | foreach-object {
                $rolerefstoadd.Add((new-object Microsoft.Xrm.Sdk.EntityReference "role", $_))
            }
            
            $connection.Associate("team", $team.Id, $rolereln, $rolerefstoadd)
        }

        if ($rolesidstoremove.Length) {
            write-host "Removing roles $rolesidstoremove from team $teamname"
            $rolerefstoremove = new-object Microsoft.Xrm.Sdk.EntityReferenceCollection

            $rolesidstoremove | foreach-object {
                $rolerefstoremove.Add((new-object Microsoft.Xrm.Sdk.EntityReference "role", $_))
            }
            $connection.Disassociate("team", $team.Id, $rolereln, $rolerefstoremove)
        }
    }
}

function ensureAadGroupTeam(
    [string] $businessunitname,
    [Parameter(Mandatory)]
    [guid] $teamid,
    [Parameter(Mandatory)]
    [string] $teamname, 
    [Parameter(Mandatory)]
    [guid] $aadgroupid,
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $rolenames
) {
    ensureTeamInternal -businessunitname:$businessunitname -teamname:$teamname -teamid:$teamid -aadgroupid:$aadgroupid -rolenames:$rolenames
}

function ensureBuDefaultTeam(
    [string] $businessunitname, 
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $rolenames
) {
    ensureTeamInternal -businessunitname:$businessunitname -rolenames:$rolenames
}

function ensureOwnerTeam(
    [string] $businessunitname,
    [Parameter(Mandatory)]
    [guid] $teamid,
    [Parameter(Mandatory)]
    [string] $teamname, 
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [string[]] $rolenames
) {
    ensureTeamInternal -businessunitname:$businessunitname -teamname:$teamname -teamid:$teamid -rolenames:$rolenames
}

function ensureAccessTeam(
    [string] $businessunitname,
    [Parameter(Mandatory)]
    [guid] $teamid,
    [Parameter(Mandatory)]
    [string] $teamname
) {
    ensureTeamInternal -businessunitname:$businessunitname -teamname:$teamname -teamid:$teamid -accessteam
}