
#Executes query and pages results correctly.
function getQueryResults([Parameter(Mandatory)]$query, $connection = (getGlobalCrmConnection)) {
    $query.PageInfo = new-object Microsoft.Xrm.Sdk.Query.PagingInfo
    $query.PageInfo.Count = 1000
    $query.PageInfo.PageNumber = 1

    $results = @()

    do {
        $response = $connection.RetrieveMultiple($query)
        $response.Entities | foreach-object { $results += $_ }
        $query.PageInfo.PageNumber++
        $query.PageInfo.PagingCookie = $response.PagingCookie
        
    } while ($response.MoreRecords)

    return $results
}

function getRestQueryResults([Parameter(Mandatory)]$query, $connection = (getGlobalCrmConnection)) {


    while ($query) {

        
        $response = $connection.ExecuteWebRequest([System.Net.Http.HttpMethod]::Get, $query, @{"Prefer"="odata.maxpagesize=5000"}, $null)
        $response.EnsureSuccessStatusCode() | out-null
        
        $responsedata = $response.Content.ReadAsStringAsync().Result | convertfrom-json -depth 100

        $responsedata.value | write-output
        if ($responsedata.PSObject.Properties.Name.Contains("@odata.nextLink")) {
            $query = [IO.Path]::GetFileName( ([uri] $responsedata.'@odata.nextLink').AbsolutePath) + ([uri] $responsedata.'@odata.nextLink').Query

        } else {
            $query = $null;
        }
    }

    
}