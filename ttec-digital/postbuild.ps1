param($context)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

& $PSScriptRoot/common/load-dataverse-sdk.ps1
import-module $PSScriptRoot/common/alm.psm1

$sourcedir = $context.SourceDirectory
$outputdir = $context.ArtifactStagingDirectory

new-item -type Directory $outputdir/dependencies -verbose

if ($config.ContainsKey("DependencySolutions")) {
    @($config.DependencySolutions) | foreach-object { copy-item -verbose (join-path $sourcedir $_) $outputdir/dependencies }
}

if ($config.ContainsKey("PostDependencySolutions")) {
    @($config.PostDependencySolutions) | foreach-object { copy-item -verbose (join-path $sourcedir $_) $outputdir/dependencies }
}

if (-not (test-path (join-path $outputdir "data"))) {
    new-item -type Directory $outputdir/data -verbose
}
if ($config.ContainsKey("DataSets")) {
    if ($config.DataSets -is [hashtable]) {
        $config.DataSets.Keys | foreach-object { 
            compress-archive -path "$sourcedir/data/$_/data/*" -destinationpath $outputdir/data/$_.zip
        }
    }
    else {
        @($config.DataSets) | foreach-object { 
            compress-archive -path "$sourcedir/data/$_/data/*" -destinationpath $outputdir/data/$_.zip
        }
    }
}

new-item -type Directory $outputdir/portals -verbose
if ($config.ContainsKey("Portals")) {
    $config.Portals.Keys | foreach-object { 
        copy-item -recurse (join-path $sourcedir "portals/$_") $outputdir/portals
    }
}

if (test-path (join-path $sourcedir "migrations")) {
    copy-item (join-path $sourcedir "migrations") $outputdir -Recurse -verbose
}

Push-Location $sourcedir
try {
    synapse_build -config $config -outputpath $outputdir
}
finally {
    Pop-Location
}
