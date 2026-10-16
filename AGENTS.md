# Dataverse-ALM Repository Guidance

This repository is the TTEC Digital fork of the ALM4Dataverse open-source project. It provides PowerShell- and YAML-based application lifecycle management for Dataverse through Azure DevOps and GitHub Actions. The fork adds backwards compatibility and migration support, solution validation rules, Azure Synapse component management, and schema migration tracking.

## Repository Map

- `pipelines/`, `.github/`, and `copy-to-your-repo/` contain pipeline scripts, workflow actions/templates, and files copied into consuming repositories.
- `docs/` contains setup, configuration, usage, and validation guidance.
- `ttec-digital/` contains fork-specific migration scripts, extensions, common deployment logic, documentation, tests, and tools.
- Root `setup-*.ps1`, `prepare-release.ps1`, and `alm-config-defaults.psd1` support setup, release preparation, and shared configuration defaults.

## General Working Rules

- Keep changes scoped and preserve existing PowerShell, YAML, configuration, and documentation conventions.
- Treat `ttec-digital/` behavior as deliberate fork functionality. Preserve compatibility unless a task explicitly changes it.
- When behavior, configuration, or setup changes, update the closest user-facing documentation and consuming-repository templates as needed.
- Validate the smallest relevant slice first, then run broader checks when a shared pipeline, setup script, or deployment contract changes.
- Do not expose credentials, commit unrelated work, or rewrite shared history without explicit approval.

The upstream synchronization procedure below is specific to bringing public ALM4Dataverse releases into this fork; it is not required for ordinary feature, bug-fix, documentation, or fork-extension work.

## Upstream Merge and PR Runbook

Use this runbook when bringing the public ALM4Dataverse repository into the Azure DevOps fork.

## Safety Rules

- Do not merge directly into Azure DevOps `main`. Create a dated source branch and submit an Azure DevOps PR.
- Record a backup branch at the target tip before merging.
- Never put a PAT or other credential in this file, a commit, a PR description, or chat output. Use the existing Azure CLI authentication.
- Treat existing fork-specific code as intentional. Do not describe it as part of the upstream merge unless it is actually changed by the merge.
- Keep metadata-only PR updates separate from repository file changes.

## Remotes and Baselines

This workspace uses these tracking refs:

- `upstream/main`: Azure DevOps fork target.
- `alm4dataverse/main`: public GitHub upstream.

Start from a clean worktree and fetch both refs:

```powershell
git status --short --branch
git fetch upstream
git fetch alm4dataverse
$targetCommit = (git rev-parse upstream/main).Trim()
$sourceCommit = (git rev-parse alm4dataverse/main).Trim()
```

Do not use `git describe` on the target alone to identify the old upstream version. A fork can be many custom commits past the nearest shared tag. Determine the old baseline from the fork's first-parent history and explicit merge/update commits, for example:

```powershell
git log --first-parent --format='%h %ad %s' --date=short $targetCommit

git log --all --grep='ALM4Dataverse v[0-9]' --format='%h %ad %s' --date=short
```

Identify the new version from the exact public source tag or the GitHub release that contains `$sourceCommit`. Confirm the release sequence through the GitHub API rather than assuming every tag name is a release name:

```powershell
gh api repos/ALM4Dataverse/ALM4Dataverse/releases --paginate `
  --jq '.[] | [.tag_name, .name, .html_url, .draft, .prerelease] | @tsv'
```

Use every non-draft, non-prerelease GitHub release strictly newer than the old baseline and no newer than the new version (old baseline exclusive, new version inclusive). Do not include the baseline release itself: it is already incorporated in the target branch. For example, when updating from v1.12.0 to v1.15.0, summarize v1.14.0 and v1.15.0, but not v1.12.0; omit any versions in between that were not published as releases. If the release name and tag differ, show both, for example `v1.7.0 (tag v1.6.1)`, and link to the tag URL returned by GitHub.

## Branch and Merge Flow

1. From the Azure target baseline, create a backup branch and a PR source branch. Use date-stamped names, such as `backup/main-before-alm4dataverse-YYYY-MM-DD` and `pr/merge-alm4dataverse-YYYY-MM-DD`.
1. Merge `alm4dataverse/main` into the PR source branch with a real merge commit so the PR represents the upstream synchronization.
1. Resolve conflicts by preserving fork behavior where it is deliberate and taking upstream changes where the fork has no competing behavior.
1. For this fork, pay particular attention to `ttec-digital` customizations, `-PublishWorkflows` behavior in deployment scripts, README links, and compatibility with existing Azure DevOps workflows. Do not treat those existing fork features as newly introduced by the public release merge.
1. Validate the merged source branch before pushing it. Check for unresolved paths, conflict markers, stale reusable-workflow references, required paths, PowerShell parse errors, and whitespace errors. At minimum:

```powershell
git diff --name-only --diff-filter=U
git grep -n -E '^(<<<<<<<|=======|>>>>>>>)' -- .
git diff --check
git status --short --branch
```

1. Push only the PR source branch, then create or update the Azure DevOps PR. Do not force-push `main` as part of the normal flow.

## PR Title and Description

The title uses the actual upstream version transition:

```text
Update ALM4Dataverse from vX to vY
```

The description is a concise release-by-release summary. Do not use a long commit list and do not add a generic paragraph such as `It incorporates upstream improvements`. Include one bullet for every GitHub release strictly after the old baseline through the new version, inclusive, with a release link and a short summary of the changes. Never add a bullet for the baseline release because it was already included in the previous update:

```text
GitHub release changes after v1.12.0 through v1.15.0:
- [v1.14.0](https://github.com/ALM4Dataverse/ALM4Dataverse/releases/tag/v1.14.0): Adds PowerShell validation, coverage gates, and regression tests to CI.
- [v1.15.0](https://github.com/ALM4Dataverse/ALM4Dataverse/releases/tag/v1.15.0): Validates GitHub/Azure workflows, parallelizes BUILD, adds SemVer and branch-based solution versions, accepts unprefixed GitHub variables, and avoids deployment-gate tag collisions.
```

The description should contain one link for each release, no duplicate endpoint links, and enough detail to distinguish the releases without copying full release notes. Keep it below Azure DevOps' 4,000-character limit.

When updating a multiline description from PowerShell, pass an array of individual lines. A scalar here-string can be stored by Azure DevOps as only its first paragraph:

```powershell
$title = 'Update ALM4Dataverse from vX to vY'
$description = @(
  'GitHub release changes from vX to vY:'
  '- [vX](https://github.com/ALM4Dataverse/ALM4Dataverse/releases/tag/vX): Short summary.'
  '- [vY](https://github.com/ALM4Dataverse/ALM4Dataverse/releases/tag/vY): Short summary.'
)

az repos pr update `
  --id $pullRequestId `
  --organization https://dev.azure.com/ttecdigital-msba-emea `
  --title $title `
  --description $description
```

## Final PR Verification

After creating or updating the PR, verify all of the following with `az repos pr show`:

- The status is `active`.
- The title states the correct old and new versions.
- The source branch is the dated merge branch and the target is `main`.
- The description contains the expected release URLs, exactly one per release.
- Each release has a brief, version-specific summary.
- The generic upstream-summary sentence and commit-by-commit list are absent.
- The description is under 4,000 characters.

Finally, confirm the local worktree is still clean. A PR-description update must not create repository file changes.
