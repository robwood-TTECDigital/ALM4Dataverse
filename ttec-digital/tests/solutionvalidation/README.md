# Validation Rule Tests

This folder contains automated tests for the Dataverse ALM validation rules.

## Export Runtime Scenario

From the repository root, connect to a disposable development environment and initialize the fixture:

```powershell
Import-Module Rnwood.Dataverse.Data.PowerShell
Get-DataverseConnection -Interactive -Url 'https://<environment>.crm.dynamics.com' -SetAsDefault
./ttec-digital/tests/solutionvalidation/Initialize-ExportRuntimeScenario.ps1 -SolutionName TestSolution1
```

The script uses the existing solution publisher's prefix. It creates a consumer table with six text columns and six lookup columns in `TestSolution1`, plus a shared table in `TestSolution1RuntimeDependencies`. The lookup relationships reference the same shared table, providing cross-solution dependencies for validation tests. Only the fixture tables are published; no business records are created and the existing solution version is not changed. Setup can be rerun without duplicating components.

To test overlapping-component validation and error/warning reporting, add the consumer table's metadata to the companion solution too:

```powershell
./ttec-digital/tests/solutionvalidation/Initialize-ExportRuntimeScenario.ps1 -IncludeValidationViolations
```

This deliberately creates an overlapping-metadata validation finding. Subsequent setup runs without the switch do not remove that overlap. The tables use reserved `<prefix>_almruntimeconsumer` and `<prefix>_almruntimeshared` names; use one runtime fixture per publisher. To clean up, remove the consumer table's solution memberships, delete the consumer table before the referenced shared table, and remove the companion solution. Do not delete `TestSolution1` or its unrelated components.

Run the offline export and validation regression tests separately; they do not require an environment connection:

```powershell
Invoke-Pester -Path ./ttec-digital/tests/solutionvalidation/ExportRuntime.Tests.ps1 -Output Detailed
```

## Running Tests

### Prerequisites

1. **Rnwood.Dataverse.Data.PowerShell** module installed
2. An active Dataverse connection with System Administrator privileges

### Connect to Dataverse

```powershell
Get-DataverseConnection -Interactive -SetAsDefault
```

### Run Full Test Suite

```powershell
.\tests\Setup-ValidationRuleTests.ps1
```

This will:
1. Create test publishers
2. Create test solutions
3. Create test tables and environment variables
4. Add components to solutions to trigger validation rules
5. Run validation tests

### Run Setup Only

```powershell
.\tests\Setup-ValidationRuleTests.ps1 -SetupOnly
```

### Run Tests Only (requires setup to be run first)

```powershell
.\tests\Setup-ValidationRuleTests.ps1 -TestOnly
```

### Cleanup Test Artifacts

```powershell
.\tests\Setup-ValidationRuleTests.ps1 -Cleanup
```

## Test Scenarios

### Positive Tests (should fail validation)

| Rule | Test Scenario |
|------|---------------|
| `ComponentInMoreThanOneUnmanagedSolution` | Same table added to two solutions with IncludeSubcomponents behavior |
| `ComponentInMoreThanOneUmanagedSolution-Metadata` | Same table added to two solutions with ShellAndMetadata behavior |
| `ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix` | Table with `vt2_` prefix added to solution with `vt1_` publisher |
| `EnvironmentVariableCurrentValueInSolution` | Environment variable current value included in solution |
| `SolutionUsesSystemPublisher` | Solution created with Default Publisher (SYSTEM-created) |

### Negative Tests (should pass validation)

| Scenario | Description |
|----------|-------------|
| Clean Solution | Solution with properly prefixed components, no overlaps, no current values |

## Test Artifacts Created

### Publishers
- `valtest1` (prefix: `vt1_`) - Main test publisher
- `valtest2` (prefix: `vt2_`) - Secondary publisher for prefix mismatch testing

### Solutions
- `ValidationTest_Positive1` - Main positive test solution (publisher: valtest1)
- `ValidationTest_Positive2` - Secondary solution for overlap testing (publisher: valtest1)
- `ValidationTest_SystemPub` - Solution with system publisher
- `ValidationTest_Negative1` - Clean solution that should pass all validations

### Tables
- `vt1_testtable1` - For overlap testing
- `vt1_testtable2` - For metadata behavior testing
- `vt1_testtable3` - For negative test (no overlaps)
- `vt2_foreigntable` - For prefix mismatch testing

### Environment Variables
- `vt1_TestEnvVar` - With current value (should fail)
- `vt1_TestEnvVarNegative` - Without current value (should pass)

## Documentation Links

Each validation rule error now includes a link to detailed documentation. Links are automatically generated based on the Git remote:

- **Azure DevOps**: `https://dev.azure.com/{org}/{project}/_git/{repo}?path=/docs/validation-rules/{rule}.md&version=GB{branch}`
- **GitHub**: `https://github.com/{owner}/{repo}/blob/{branch}/docs/validation-rules/{rule}.md`

## Adding New Tests

1. Add the test scenario setup in `Setup-TestComponents` function
2. Update the test expectations in `Run-ValidationTests` function
3. Add documentation in `docs/validation-rules/` for any new rules
