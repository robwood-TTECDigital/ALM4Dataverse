# GitHub Actions Migration Guide

This fork previously shipped its own GitHub Actions support, workflow templates, variable names, and migration path. Upstream ALM4Dataverse now provides first-party GitHub support, so the fork-specific GitHub setup is deprecated.

Use this guide to move repositories that were using the older TTEC Digital GitHub support onto the upstream GitHub workflow model.

## Canonical docs

After migration, use the upstream docs as the source of truth:

- `docs/setup/github-setup.md`
- `docs/setup/github-variables.md`
- `docs/config/github-secrets.md`

## What changed

The old fork-specific GitHub support used:

- Workflow stubs that called `ttecdigital-msba-emea/Dataverse-ALM/pipelines/github-workflows/*`
- `DEPLOY.yml` with a matrix-based deployment model
- Lowercase variables such as `dataverseurl`, `dataverseapplicationid`, and `dataversetenantid`
- Fork-specific documentation in this folder

The current upstream GitHub support uses:

- Reusable workflows hosted by `ALM4Dataverse/ALM4Dataverse/.github/workflows/*`
- `DEPLOY-main.yml` with one deploy job per environment and explicit promotion mode
- Uppercase Azure variables such as `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `DATAVERSE_URL`
- Either GitHub Environment scoped variables/secrets or prefixed repo-level credentials

## Migration steps

### 1. Replace workflow files

In your application repository, replace the old workflow files with the current templates from `copy-to-your-repo/.github/workflows/`.

Expected result:

- Keep `BUILD.yml`
- Keep `EXPORT.yml`
- Keep `IMPORT.yml`
- Replace `DEPLOY.yml` with `DEPLOY-main.yml`

If you used the helper script:

```powershell
pwsh -File ttec-digital/migrate-github-repo.ps1 -WorkspacePath c:\repos\my-dataverse-project
```

Review the generated `DEPLOY-main.yml` afterwards and replace the example environments with your real deployment stages.

### 2. Update workflow references

Old fork-specific workflow references looked like this:

```yaml
uses: ttecdigital-msba-emea/Dataverse-ALM/pipelines/github-workflows/BUILD@main
```

The new workflow stubs call upstream reusable workflows like this:

```yaml
uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/build.yml@stable
```

Do not try to keep the old `pipelines/github-workflows/*` references. That layout is the part being retired.

### 3. Rename GitHub environment conventions

If you were using the old fork defaults, update your GitHub environment names:

| Old fork convention | Current upstream convention |
| --- | --- |
| `DEV_main` | `Dev-main` |
| `SAT_main` | `TEST-main` or your chosen environment name |
| `UAT_main` | `UAT-main` or your chosen environment name |

Use the actual upstream workflow environment names in your workflows, federated credentials, and GitHub Environment configuration.

### 4. Rename variables and secrets

Map the old fork variable names to the new upstream names:

| Old fork name | New upstream name |
| --- | --- |
| `dataverseurl` | `DATAVERSE_URL` |
| `dataverseapplicationid` | `AZURE_CLIENT_ID` |
| `dataversetenantid` | `AZURE_TENANT_ID` |
| `dataverseclientsecret` | `AZURE_CLIENT_SECRET` |

These values can now be stored either:

- In GitHub Environments
- As prefixed repo-level credentials described in `docs/setup/github-variables.md`

Connection references and Dataverse environment variables should continue to use the `DataverseConnRef_*` and `DataverseEnvVar_*` naming pattern.

### 5. Recreate federated credentials if you use WIF

If you were using the fork's workload identity setup, recreate or update the Entra federated credentials so their subject matches the upstream environment naming.

Current upstream subject format:

```text
repo:{owner}/{repo}:environment:{environment-name}
```

Example:

```text
repo:MyOrg/MyRepo:environment:Dev-main
```

### 6. Review deployment mode

The old fork deploy flow was a single workflow with a matrix of environments. The upstream GitHub model is explicit per stage and supports two promotion modes:

- `manual-gate-tag`
- `environment-approval`

Choose one mode per stage and configure `DEPLOY-main.yml` accordingly.

### 7. Re-test the full path

After updating workflows and variables:

1. Run `IMPORT`
2. Run `EXPORT`
3. Verify `BUILD` triggers correctly
4. Run `DEPLOY-main` manually or through automatic chaining, depending on your promotion mode

## Recommended cleanup

After your application repository is migrated:

- Remove any custom references to `pipelines/github-workflows/*`
- Remove old lowercase GitHub environment variables and secrets once the new workflows are confirmed working
- Remove any local documentation that still instructs users to configure the fork-specific GitHub setup

## See also

- `docs/setup/github-setup.md`
- `docs/setup/github-variables.md`
- `docs/config/github-secrets.md`
