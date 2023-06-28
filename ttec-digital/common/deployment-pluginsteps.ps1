# Sets the secure plugin config for the specified step
function setPluginStepSecureConfig([Parameter(Mandatory)][guid]$stepid,[string] $value) {

    $step = (getGlobalCrmConnection).Retrieve("sdkmessageprocessingstep", $stepid, (new-object Microsoft.Xrm.Sdk.Query.ColumnSet "sdkmessageprocessingstepsecureconfigid"))


    if ($step.Contains("sdkmessageprocessingstepsecureconfigid")) {
       $secureconfig = new-object Microsoft.Xrm.Sdk.Entity "sdkmessageprocessingstepsecureconfig", $step["sdkmessageprocessingstepsecureconfigid"].Id
    } else {
       $secureconfig = new-object Microsoft.Xrm.Sdk.Entity "sdkmessageprocessingstepsecureconfig"
    }

    $secureconfig["secureconfig"] = $value

    if ($step.Contains("sdkmessageprocessingstepsecureconfigid")) {
        write-host "Updating plugin step $stepid secure config value"
        (getGlobalCrmConnection).Update($secureconfig)
    } else {
        write-host "Creating plugin step $stepid secure config value"
        $secureconfig.Id = (getGlobalCrmConnection).Create($secureconfig)
        $step["sdkmessageprocessingstepsecureconfigid"] = $secureconfig.ToEntityReference()
        (getGlobalCrmConnection).Update($step)
    }

}

