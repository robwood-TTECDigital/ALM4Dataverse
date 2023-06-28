@{
    # ALM for Dataverse configuration
    #
    # Paths in this file are relative to the directory this file is in (the repo root).
    #
    # DEFAULT CONFIGURATION:
    # To add default configuration for all repos using the shared repo, edit the alm-config-defaults.psd1 file
    # in the ALM4Dataverse repository root.
    # Default configuration is merged with this file (this file's values take precedence).
    # Arrays are concatenated, hashtables are merged.
    # This allows forks to add custom defaults without modifying this template.
    #
    # HOOK SCRIPT PATHS AND [ALM] REPLACEMENT:
    # Hook script paths can use the [alm] placeholder to reference the ALM4Dataverse
    # repository root. For example:
    #   '[alm]/custom-hooks/myScript.ps1' -> executes the script from the fork's copy of ALM4Dataverse
    # This is useful for running custom hook scripts provided by the ALM4Dataverse fork.
    # The placeholder is replaced with the absolute path to the ALM repo root before execution.

    # Solutions to process, in dependency order.
    # Each entry is a hashtable with keys
    # - name: unique solution name.
    # - deployUnmanaged: (optional) boolean indicating whether to deploy unmanaged version.
    # - serviceAccountUpnConfigKey: (optional) name of the environment configuration key containing
    #   the service account UPN to use when activating processes in this solution.
    #   The default is 'DataverseServiceAccountUpn'
    # - validationMode: (optional) 'error' (default), 'warning', or 'disabled'. Controls validation behavior for this solution.
    #   - 'error': Validation failures cause pipeline to fail (default behavior)
    #   - 'warning': Validation failures are reported as warnings only
    #   - 'disabled': No validation is performed
    # - skipValidationRules: (optional) array of validation rules to configure. Each entry is a hashtable with:
    #   - ruleName: (required) name of the validation rule (e.g., 'ComponentInMoreThanOneUnmanagedSolution')
    #   - mode: (optional) 'skip' (default) or 'warning'. Controls behavior for this rule.
    #   - componentType: (optional) apply only for this component type number (e.g., 1 for entities)
    #   - componentId: (optional) apply only for this specific component GUID
    #   - componentSchemaName: (optional) apply only for component with this schema name
    #
    # Example with validation configurations:
    # @{
    #     name = 'MySolution'
    #     validationMode = 'warning'  # All validation issues become warnings
    #     skipValidationRules = @(
    #         # Skip entire rule for this solution
    #         @{ ruleName = 'SolutionUsesSystemPublisher'; mode = 'skip' }
    #         # Warning mode for specific rule (errors become warnings)
    #         @{ ruleName = 'ComponentInMoreThanOneUnmanagedSolution'; mode = 'warning' }
    #         # Skip rule for specific component type (1 = entity)
    #         @{ ruleName = 'ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix'; componentType = 1; mode = 'skip' }
    #         # Warning for specific component by ID
    #         @{ ruleName = 'DependencyOnSolutionNotAllowed'; componentType = 1; componentId = 'guid-here'; mode = 'warning' }
    #         # Skip for specific component by schema name
    #         @{ ruleName = 'EnvironmentVariableCurrentValueInSolution'; componentType = 380; componentSchemaName = 'legacy_component'; mode = 'skip' }
    #     )
    # }
    # See ttec-digital/docs/solution-validation.md for complete documentation
    solutions = @(
    )


    # Extra folders/files to include in build artifacts (copied verbatim).
    assets = @(
        'data'
    )

    # Hook scripts executed by the pipeline scripts.
    #
    # Each hook is a list of script paths (relative to repo/artifact root).
    # Hooks are optional; leave them empty (@()) when not needed.
    #
    # Hook scripts receive a -Context parameter with a hashtable containing:
    # - HookType: the type of hook being executed
    # - BaseDirectory: the base directory for the hook (source or artifacts root)
    # - Config: the loaded alm-config.psd1 configuration
    # - Additional context specific to the hook type (see details below)
    #
    # Hook-specific context:
    #
    # preBuild, postBuild:
    #   - SourceDirectory: path to the source directory
    #   - ArtifactStagingDirectory: path to the artifact staging directory
    #
    # preExport, postExport:
    #   - SourceDirectory: path to the source directory
    #   - ArtifactStagingDirectory: path to the artifact staging directory
    #   - TempDirectory: path to temporary directory for export operations
    #   - EnvironmentName: name of the Dataverse environment being exported from
    #
    # preDeploy, dataMigrations, postDeploy:
    #   - ArtifactsPath: path to the artifacts directory
    #   - UseUnmanagedSolutions: boolean indicating if unmanaged solutions are being deployed
    #
    hooks = @{
        # Called by `pipelines/scripts/export.ps1` before exporting solutions.
        preExport  = @()

        # Called by `pipelines/scripts/export.ps1` after exporting/unpacking/version bump logic.
        postExport = @(
            'data/system/export.ps1'
        )

        # Called by `pipelines/scripts/deploy.ps1` before staging/importing solutions.
        preDeploy  = @()

        # Called by `pipelines/scripts/deploy.ps1` after publish customizations.
        postDeploy = @(
            'data/system/import.ps1'
        )

        # Called by `pipelines/scripts/build.ps1` before packing solutions.
        preBuild   = @()

        # Called by `pipelines/scripts/build.ps1` after packing solutions/copying assets.
        postBuild  = @()

        # Called by `pipelines/scripts/deploy.ps1` after solutions are staged but before upgrades.
        # Use this for data migration scripts (e.g., moving data from one column to another before they disappear).
        dataMigrations = @()
    }

    # PowerShell modules required by the scripts in addition to the default modules.
    # or to override with specific versions.

    # Key = module name, 
    # Value = version ('' = latest stable version, 'prerelease' = latest prerelease, or specific version).
    scriptDependencies = @{
        # Example:
        # 'PnP.PowerShell' = '1.12.0'
    }
}
