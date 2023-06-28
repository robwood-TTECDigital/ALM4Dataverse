
function getGlobalCrmConnection() {
    return (Get-DataverseConnection -GetDefault)
}

function newCrmConnection() {
    return (Get-DataverseConnection -GetDefault).Clone()
}

function getEnvironmentId($connection = (getGlobalCrmConnection)) {
    $request = new-object Microsoft.Crm.Sdk.Messages.RetrieveCurrentOrganizationRequest
    $request.AccessType = "Internet"
    $response = $connection.Execute($request)
    
    $environmentid = $response.Detail.EnvironmentId

    if (-not $environmentid) {
        throw "Unable to get environment id (no environment id found)"
    }

    return $environmentid
}
