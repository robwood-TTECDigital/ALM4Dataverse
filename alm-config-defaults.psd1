@{
    hooks = @{
        # Called by `pipelines/scripts/export.ps1` before exporting solutions.
        preExport  = @()

        # Called by `pipelines/scripts/export.ps1` after exporting/unpacking/version bump logic.
        postExport = @(
            "[alm]/ttec-digital/postexport.ps1"
        )

        # Called by `pipelines/scripts/deploy.ps1` before staging/importing solutions.
        preDeploy  = @(
            "[alm]/ttec-digital/predeploy.ps1"
        )

        # Called by `pipelines/scripts/deploy.ps1` after publish customizations.
        postDeploy = @(
            "[alm]/ttec-digital/postdeploy.ps1"
        )

        # Called by `pipelines/scripts/build.ps1` before packing solutions.
        preBuild   = @()

        # Called by `pipelines/scripts/build.ps1` after packing solutions/copying assets.
        postBuild  = @(
            "[alm]/ttec-digital/postbuild.ps1"
        )

        # Called by `pipelines/scripts/deploy.ps1` after solutions are staged but before upgrades.
        # Use this for data migration scripts (e.g., moving data from one column to another before they disappear).
        dataMigrations = @(
            "[alm]/ttec-digital/solution-upgrade-migrations.ps1"
        )
    }

    scriptDependencies = @{
        "Rnwood.Dataverse.Data.PowerShell" = "2.18.0"
    }
}
