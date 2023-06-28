function synapse_build([Parameter(Mandatory)] $config, [Parameter(Mandatory)][string]$outputpath) {

    if ($config.ContainsKey("SynapseFolders") -and $config.SynapseFolders.Length) {

        write-host "##[group]Copying Synapse assets"

        copy-item -verbose -Recurse .\scripts $outputpath
        copy-item -verbose -Recurse .\pipelines $outputpath
        copy-item -verbose -Recurse .\datasets $outputpath
        copy-item -verbose -Recurse .\triggers $outputpath
        copy-item -verbose -Recurse .\linked-services $outputpath

        write-host "##[endgroup]"

    }
}

function synapse_export([Parameter(Mandatory)] $config) {

    if ($config.ContainsKey("SynapseFolders") -and $config.SynapseFolders.Length) {

        if (-not $config.ContainsKey("SynapseRepositoryUrl") -or [string]::IsNullOrWhiteSpace($config.SynapseRepositoryUrl)) {
            throw "SynapseRepositoryUrl must be configured in alm-config.psd1 when SynapseFolders is set. Example: SynapseRepositoryUrl = 'https://user@dev.azure.com/org/project/_git/repo'"
        }

        write-host "##[group]Exporting Synapse assets"
            
        $temppath = [IO.Path]::GetTempPath() + "/" + [Guid]::NewGuid()

        new-item -type Directory $temppath

        if ($env:SYSTEM_ACCESSTOKEN) {
            git clone -c "http.extraHeader=Authorization: bearer ${env:SYSTEM_ACCESSTOKEN}" --depth=1 $config.SynapseRepositoryUrl $temppath/synapse-development
        }
        else {
            git clone --depth=1 $config.SynapseRepositoryUrl $temppath/synapse-development
        }
        if (-not $? -or $LASTEXITCODE -ne 0) {
            throw "Git clone failed with exit code $LASTEXITCODE"
        }


        function copyItemsWithFolderProperty([Parameter(Mandatory)] $sourcefoldername, [Parameter(Mandatory)] $targetfoldername, [Parameter(Mandatory)] $integrationfoldername) {
            
            new-item -ItemType Directory "$targetfoldername/$integrationfoldername" -Force
            "File to keep folder present if empty" | out-file $targetfoldername/$integrationfoldername/keep.me
            
            foreach ($file in (get-childitem $temppath/synapse-development/$sourcefoldername)) {
                $json = get-content -raw -Encoding UTF8 $file.FullName | convertfrom-json -depth 100
                if ($json.properties.PSObject.Properties.Name -contains 'folder' -and $json.properties.folder.name -eq $integrationfoldername) {
                    copy-item -Verbose $file $targetfoldername/$integrationfoldername
                }
            }
        }

        foreach ($targetfoldername in @("datasets", "pipelines", "scripts", "triggers", "linked-services")) {
            if (test-path $targetfoldername) {
                remove-item -Recurse $targetfoldername
            }
            
            new-item -ItemType Directory $targetfoldername

            "File to keep folder present if empty" | out-file $targetfoldername/keep.me
        }

        foreach ($integrationfoldername in @($config.SynapseFolders)) {

            write-host "Processing Synapse folder '$integrationfoldername'"

            copyItemsWithFolderProperty -sourcefoldername dataset -targetfoldername datasets -integrationfoldername $integrationfoldername
            foreach ($datasetfile in get-childitem -filter *.json datasets) {
                $json = get-content -raw -Encoding UTF8 $datasetfile.FullName | convertfrom-json -depth 100

                if ($json.properties.PSObject.Properties.Name -contains "linkedServiceName" -and $json.properties.linkedServiceName.PSObject.Properties.Name -contains "parameters" -and $null -ne $json.properties.linkedServiceName) {
                    $json | convertto-json -depth 100 | out-file -Encoding UTF8 $datasetfile
                }
            }

            copyItemsWithFolderProperty -sourcefoldername pipeline -targetfoldername pipelines -integrationfoldername $integrationfoldername

            copyItemsWithFolderProperty -sourcefoldername sqlscript -targetfoldername scripts -integrationfoldername $integrationfoldername
            # Extract content to .SQL file for better source control
            foreach ($scriptjsonfile in get-childitem -filter *.json scripts/$integrationfoldername) {
                $json = get-content -raw -Encoding UTF8 $scriptjsonfile.FullName | convertfrom-json -depth 100
                $json.properties.content.query | out-file -Encoding UTF8 "scripts/$integrationfoldername/$($scriptjsonfile.BaseName).sql"
                remove-item $scriptjsonfile
            }

            new-item -ItemType Directory "triggers/$integrationfoldername" -Force
            "File to keep folder present if empty" | out-file triggers/$integrationfoldername/keep.me

            foreach ($file in (get-childitem $temppath/synapse-development/trigger)) {
                $json = get-content -raw -Encoding UTF8 $file.FullName | convertfrom-json -depth 100
                # If any referenced pipeline was copied above
                if ($json.properties.pipelines | where-object { test-path "pipelines/$integrationfoldername/$($_.pipelineReference.referenceName).json" } ) {
                    copy-item -Verbose $file triggers/$integrationfoldername      
                }
            }    
        }

        $includelinkedservices = @()
        if ($config.ContainsKey("SynapseLinkedServicesInclude")) {
            $includelinkedservices += $config.SynapseLinkedServicesInclude
        }
        $excludelinkedservices = @("*WorkspaceDefault*")
        if ($config.ContainsKey("SynapseLinkedServicesExclude")) {
            $excludelinkedservices += $config.SynapseLinkedServicesExclude
        }

        foreach ($linkedservicefile in (Get-childitem $temppath/synapse-development/linkedService | where-object {
                    $file = $_;
                    ($includelinkedservices | where-object { $file.BaseName -like $_ }) -and
                    -not ($excludelinkedservices | where-object { $file.BaseName -like $_ })
                })) {

            $linkedservicefilejson = get-content -raw -Encoding UTF8 $linkedservicefile | convertfrom-json -Depth 100

            foreach ($property in $linkedservicefilejson.properties.typeProperties.PSObject.Properties) {
                if (@("encryptedCredential") -contains $property.Name) {
                    $property.Value = "<removed>"
                }
            }

            $linkedservicefilejson | convertto-json -Depth 100 | out-file -Force -Encoding utf8 "linked-services/$($linkedservicefile.BaseName).json"

        }

        remove-item -Recurse -force $temppath

        git add datasets pipelines scripts triggers linked-services

        write-host "##[endgroup]"
    }
}

function synapse_deploy([Parameter(Mandatory)] $config) {

    function checkSuccess($result) {
        if (
            $result.PSObject.Properties.Name -contains "AdditionalProperties" `
                -and $result.AdditionalProperties.ContainsKey("status")  `
                -and $result.AdditionalProperties["status"] -eq "Failed"
        ) {
            throw "Synapse Import failure: $($result.AdditionalProperties["error"] | convertto-json -depth 100)"
        }
    
        if ($result.PSObject.Properties.Name -contains "Properties" -and $result.Properties -eq $null) {
            throw "Synapse Import failure: $($result | convertto-json -depth 100)"
        }
    
        Write-Output $result
    }

    function ensureSynapseManagedPrivateEndpoint($synapseworkspacename, $name, $definition) {

        $tempfile = [IO.Path]::GetTempPath() + "/" + [Guid]::NewGuid() + ".json"
    
        $definition | out-file -Encoding UTF8 ($tempfile)
    
        try {
            $result = New-AzSynapseManagedPrivateEndpoint -WorkspaceName $synapseworkspacename -Name "$name" -DefinitionFile $tempfile
            if (
                $result.PSObject.Properties.Name -contains "AdditionalProperties" `
                    -and $result.AdditionalProperties.ContainsKey("status")  `
                    -and $result.AdditionalProperties["status"] -eq "Failed"
            ) {
                throw "Synapse Import failure: $($result.AdditionalProperties["error"] | convertto-json -depth 100)"
            }
            
            if ($result.PSObject.Properties.Name -contains "Properties" -and $null -eq $result.Properties) {
                throw "Synapse Import failure: $($result | convertto-json -depth 100)"
            }
            
            Write-Output $result    
        }
        finally {
            remove-item -Force $tempfile -ErrorAction SilentlyContinue
        }
    
    }

    function processManagedPrivateEndpoints($synapseworkspacename) {
        if ($config.ContainsKey("SynapseManagedPrivateEndpoints")) {

            foreach ($endpoint in $config.SynapseManagedPrivateEndpoints) {
                write-host "Processing managed private endpoint '$($endpoint.Name)'"
                $endpoint.Name = (replaceEnvVarPlaceholders $endpoint.Name)
                $endpoint.Definition = (replaceEnvVarPlaceholders $endpoint.Definition)
                $endpoint.Definition | write-host
                ensureSynapseManagedPrivateEndpoint -synapseworkspacename $synapseworkspacename -name $endpoint.Name -definition $endpoint.Definition
            }
        }
    }

    function processLinkedServices($synapseworkspacename) {
        foreach ($linkedservicefile in (Get-ChildItem -filter *.json linked-services)) {
            write-host "Importing linked-service $($linkedservicefile.BaseName)"

            $linkedservicefilejson = get-content -raw -Encoding UTF8 $linkedservicefile | convertfrom-json -Depth 100

            if ($linkedservicefilejson.properties.typeProperties.PSObject.Properties.Name -contains "encryptedCredential") {
          
                if ($linkedservicefilejson.properties.typeProperties.PSObject.Properties.Name -contains "servicePrincipalCredentialType" -and $linkedservicefilejson.properties.typeProperties.servicePrincipalCredentialType -eq "ServicePrincipalKey") {
                    Add-Member -InputObject $linkedservicefilejson.properties.typeProperties -Type NoteProperty -Name servicePrincipalCredential -value ""
                    # Value will be set below
                } elseif ($linkedservicefilejson.properties.typeProperties.PSObject.Properties.Name -contains "authenticationType" -and $linkedservicefilejson.properties.typeProperties.authenticationType -eq "SQL"){
                    Add-Member -InputObject $linkedservicefilejson.properties.typeProperties -Type NoteProperty -Name password -value ""
                } elseif ($linkedservicefilejson.properties.typeProperties.PSObject.Properties.Name -contains "authenticationType" -and $linkedservicefilejson.properties.typeProperties.authenticationType -eq "ServicePrincipal"){
                    Add-Member -InputObject $linkedservicefilejson.properties.typeProperties -Type NoteProperty -Name servicePrincipalCredential -value ""
                }
                 else {
                    throw "Unsupported encryptedCredential type"
                }


                $linkedservicefilejson.properties.typeProperties.PSObject.Properties.Remove("encryptedCredential")
            }
            
            foreach ($property in $linkedservicefilejson.properties.typeProperties.PSObject.Properties) {

                $propertyenvvarname = "SYNAPSELINKSVC_$($linkedservicefile.BaseName)_$($property.Name)" -replace " ", "_"
                if (-not (test-path env:$propertyenvvarname)) {
                    throw "$propertyenvvarname not found"
                }

                $propertyenvvaritem = (get-item env:$propertyenvvarname)
                write-host "Value for property $($property.Name) is '$($propertyenvvaritem.Value)'"

                if ($property.Name -eq "servicePrincipalCredential" -or $property.Name -eq "password") {
                    $property.Value = [PSCustomObject]@{
                        type  = 'SecureString'
                        value = $propertyenvvaritem.Value
                    }
                }
                else {
                    $property.Value = $propertyenvvaritem.Value
                }

                
            }

            $linkedservicefilejson | convertto-json -depth 100 | write-host 

            $linkedservicefilejson | convertto-json -Depth 100 | out-file -Force -Encoding utf8 "$($linkedservicefile.FullName).tmp"

            az synapse linked-service create --workspace-name $synapseworkspacename --name $linkedservicefile.BaseName --file "@$($linkedservicefile.FullName).tmp"
            if (-not $? -or $LASTEXITCODE -ne 0) {
                throw "az synapse linked-service create failed with exit code $LASTEXITCODE"
            }
        }
    }

    function processLinkedServiceDeletions($synapseworkspacename ) {
        $includelinkedservices = @()
        if ($config.ContainsKey("SynapseLinkedServicesInclude")) {
            $includelinkedservices += $config.SynapseLinkedServicesInclude
        }
        $excludelinkedservices = @("*WorkspaceDefault*")
        if ($config.ContainsKey("SynapseLinkedServicesExclude")) {
            $excludelinkedservices += $config.SynapseLinkedServicesExclude
        }

        # Find existing linked services that match the filters but aren't in the lastest files and delete them
        Get-AzSynapseLinkedService -WorkspaceName $synapseworkspacename | Where-Object {
            
            $linkedservice = $_
            (
                ($includelinkedservices | where-object { $linkedservice.Name -like $_ }) `
                -and (-not ($excludelinkedservices | where-object { $linkedservice.Name -like $_ })) `
                -and (-not (test-path "linked-services/$($linkedservice.Name).json"))  
            )       
        } | ForEach-Object {
            write-host "Deleting linked service '$($_.Name)'"
            az synapse linked-service delete --workspace-name $synapseworkspacename --name "$($linkedservice.Name)" --yes
            if (-not $? -or $LASTEXITCODE -ne 0) {
                throw "az synapse linked-service delete failed with exit code $LASTEXITCODE"
            }

        }
    }
    

    function processDatasetDeletions($synapseworkspacename, $integrationfoldername) {
        # Delete datasets already present in the folder but which are not in the latest set
        foreach ($dataset in ( Get-AzSynapseDataset -WorkspaceName $synapseworkspacename | where-object { 
            $_.Properties.PSObject.Properties.Name -contains "Folder" -and $_.Properties.Folder.Name -eq $integrationfoldername `
            -and (-not (test-path "datasets/$integrationfoldername/$($_.Name).json"))
        })) {
            write-host "Deleting dataset '$($dataset.Name)'"

            az synapse dataset delete --workspace-name $synapseworkspacename --name "$($dataset.Name)" --yes
            if (-not $? -or $LASTEXITCODE -ne 0) {
                throw "az synapse dataset delete failed with exit code $LASTEXITCODE"
            }
        }
    }

    
    if ($config.ContainsKey("SynapseFolders") -and $config.SynapseFolders.Length) {

        write-host "##[group]Deploying Synapse assets"

        if (-not $env:SYNAPSE_WORKSPACENAME) {
            throw "SYNAPSE_WORKSPACENAME not found"
        }

        $synapseworkspacename = $env:SYNAPSE_WORKSPACENAME
            
        if (-not (get-module Az.Synapse)) {
            import-module Az.Synapse
        }

        if (-not (get-module SQLServer)) {
            import-module SQLServer
        }

        $sqlaccesstoken = (Get-AzAccessToken -ResourceUrl https://database.windows.net).Token

        $dataversedboutput = invoke-sqlcmd -ServerInstance ${synapseworkspacename}-ondemand.sql.azuresynapse.net -AccessToken $sqlaccesstoken -Query "SELECT name FROM sys.databases where name like 'dataverse_%'"

        $dataversedbname = $dataversedboutput.name
        write-host "Dataverse DB name is '$dataversedbname'"

        processManagedPrivateEndpoints -synapseworkspacename $synapseworkspacename

        processLinkedServices -synapseworkspacename $synapseworkspacename

        foreach ($integrationfoldername in @($config.SynapseFolders)) {

            write-host "Processing Synapse folder '$integrationfoldername'"
                    
            foreach ($datasetfile in (Get-ChildItem -Path datasets/$integrationfoldername -Filter *.json | Sort-Object BaseName)) {
                write-host "Importing dataset $datasetfile"

                $dataset = get-content -raw -Encoding UTF8 $datasetfile | convertfrom-json -depth 100
                # Replace ...-WorkspaceDefault... LS names as they vary per instance
                $dataset.properties.linkedServiceName.referenceName = $dataset.properties.linkedServiceName.referenceName -replace '^(.*)-WorkspaceDefault(.*)$', "${synapseworkspacename}-WorkspaceDefault`$2"

                $dataset | convertto-json -depth 100 | out-file -Encoding UTF8 "$($datasetfile.FullName).temp"

                checkSuccess (New-AzSynapseDataset -WorkspaceName $synapseworkspacename -Name $datasetfile.BaseName -DefinitionFile "$($datasetfile.FullName).temp")
            }
    
            foreach ($sqlfile in (Get-ChildItem -Path scripts/$integrationfoldername -Filter *.sql | Sort-Object BaseName)) {

                write-host "Importing script $sqlfile"

                $sql = Get-Content -encoding UTF8 -raw $sqlfile.fullname 

                # Replace dataverse_... with the actual DB name for this environment
                $sql = $sql -replace "\bdataverse_[a-z0-9_-]+\b", $dataversedbname

                $sql | out-file -Encoding UTF8 -force "$($sqlfile.fullname).temp"

                checkSuccess (New-AzSynapseSqlScript -WorkspaceName $synapseworkspacename -FolderPath $integrationfoldername -Name $sqlfile.BaseName -DefinitionFile  "$($sqlfile.fullname).temp")
            }

            foreach ($sqlfile in (Get-ChildItem -Path scripts/$integrationfoldername -Filter *.sql | Sort-Object BaseName)) {

                write-host "Executing script $sqlfile"
                invoke-sqlcmd -ServerInstance ${synapseworkspacename}-ondemand.sql.azuresynapse.net -Database "integration" -AccessToken $sqlaccesstoken -Query (get-content -raw -Encoding UTF8 "$($sqlfile.fullname).temp")
            }


            foreach ($pipelinefile in (Get-ChildItem -Path pipelines/$integrationfoldername -Filter *.json | Sort-Object BaseName)) {
                write-host "Importing pipeline script $pipelinefile" 

                $pipelinejson = get-content -raw -Encoding UTF8 $pipelinefile

                # Replace [dataverse_...] with the actual DB name for this environment
                $pipelinejson = $pipelinejson -replace "dataverse_[a-z0-9_]+", $dataversedbname

                # Replace asw-...-d365cs-...-ondemand with actual name of this Synapse workspace
                $pipelinejson = $pipelinejson -replace "asw-.+d365cs.+-ondemand", "${synapseworkspacename}-ondemand"

                $pipelinejson | out-file -Encoding UTF8 "$($pipelinefile.FullName).temp"

                checkSuccess (New-AzSynapsePipeline -WorkspaceName $synapseworkspacename -Name $pipelinefile.BaseName -DefinitionFile "$($pipelinefile.FullName).temp")
            }

            foreach ($triggerfile in (Get-ChildItem -Path triggers/$integrationfoldername -Filter *.json | Sort-Object BaseName)) {
                write-host "Importing trigger $triggerfile" 
                checkSuccess (New-AzSynapseTrigger -WorkspaceName $synapseworkspacename -Name $triggerfile.BaseName -DefinitionFile $triggerfile.FullName)
            }


            # Delete pipelines already present in the folder but which are not in the latest set
            foreach ($pipeline in ( Get-AzSynapsePipeline -WorkspaceName $synapseworkspacename | where-object { 
                $_.Folder -and $_.Folder.Name -eq $integrationfoldername `
                -and (-not (test-path "pipelines/$integrationfoldername/$($_.Name).json"))
            })) {
                write-host "Deleting pipeline '$($pipeline.Name)'"
                az synapse pipeline delete --workspace-name $synapseworkspacename --name "$($pipeline.Name)" --yes
                if (-not $? -or $LASTEXITCODE -ne 0) {
                    throw "az synapse pipeline delete failed with exit code $LASTEXITCODE"
                }
            }
            
            processDatasetDeletions -synapseworkspacename $synapseworkspacename -integrationfoldername $integrationfoldername

            # Delete SQL scripts already present in the folder but which are not in the latest set
            foreach ($script in ( Get-AzSynapseSqlScript -WorkspaceName $synapseworkspacename | where-object { 
                $_.Properties.PSObject.Properties.Name -contains "Folder" -and $_.Properties.Folder.Name -eq $integrationfoldername `
                -and (-not (test-path "scripts/$integrationfoldername/$($_.Name).sql"))
            })) {
                # Bug 'Value can not be null' in this command makes it unusable
                #Remove-AzSynapseSqlScript -WorkspaceName $synapseworkspacename -Name $script.Name -force -Verbose

                write-host "Deleting SQL script '$($script.Name)'"
                az synapse sql-script delete --workspace-name $synapseworkspacename --name "$($script.Name)" 
                if (-not $? -or $LASTEXITCODE -ne 0) {
                    throw "az synapse sql-script delete failed with exit code $LASTEXITCODE"
                }
            }

    
        }

        processLinkedServiceDeletions -synapseworkspacename $synapseworkspacename

        write-host "##[endgroup]"
    }
}