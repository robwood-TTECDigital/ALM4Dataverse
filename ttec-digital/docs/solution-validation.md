# Solution Validation

## Overview

The ALM framework includes a comprehensive solution validation system that runs automatically during the export process. This validation helps ensure solution quality, consistency, and compliance with best practices by checking for common issues before solutions are deployed.

## When Validation Runs

Solution validation executes automatically during the **export pipeline** after solutions are exported from the source environment. Each solution configured in `alm-config.psd1` is validated before the export process completes.

The validation process:
1. Uses the existing connection to the source Dataverse environment
2. Executes all enabled validation rules against the environment
3. Reports any violations as pipeline errors or warnings

Rules run in parallel by default, with up to four rules at once configured by `validation.maxParallel`; set `validation.parallel = $false` for sequential rules. Validation still runs for unchanged solutions and respects existing error, warning and disabled settings, including rule and component overrides.

Validation can overlap solution exports, subject to the shared `export.maxConcurrentOperations` limit (default `4`). Status messages identify the solution and rule, and findings are reported in rule order. Rule execution errors appear directly in the standard log with a solution/rule prefix. Detailed logs and findings are retained in the `export-logs` artifact directory, with a final per-solution summary. See [Export Processing](../../docs/config/alm-config.md#export-processing) for concurrency settings and [Export Logs](../../docs/usage/exporting-changes.md#export-logs) for log formats and artifacts.

## Available Validation Rules

The framework includes multiple validation rules that check for specific issues in your solutions. Complete documentation for each rule, including what it checks and how to remediate issues, is available in the `ttec-digital/validationrules` folder.

Each rule file includes both the PowerShell implementation (`.ps1`) and detailed documentation (`.md`) explaining:
- What the rule validates
- Why the check is important
- How to fix violations
- Common scenarios

## Validation Errors and Warnings

When validation rules detect issues:

- **In Azure DevOps/GitHub Pipelines**: 
  - Errors are logged as pipeline errors (`##vso[task.logissue type=error]`) and the pipeline fails
  - Warnings are logged as pipeline warnings (`##vso[task.logissue type=warning]`) and the pipeline continues
- **In Local Development**: 
  - Errors are written to PowerShell error stream
  - Warnings are written to PowerShell warning stream
- **Documentation Links**: Each error/warning includes a link to the rule's documentation for remediation guidance

## Validation Modes

The validation system supports three modes of operation:

1. **Error Mode (Default)**: Validation failures cause the pipeline to fail
2. **Warning Mode**: Validation failures are reported as warnings only - pipeline continues
3. **Disabled Mode**: No validation is performed

These modes can be configured globally for a solution or individually for specific validation rules and components.

## Configuring Validation Behavior

You can customize how validation behaves for specific solutions, rules, and components. This should be used thoughtfully and only when necessary.

### ⚠️ Important Warning

Changing validation behavior bypasses or softens important quality checks. Only modify validation when:
- You have a specific business justification
- You understand the risks
- The issue cannot be resolved through proper solution configuration
- You treat skips/warnings as technical debt to be addressed

### Global Validation Mode for a Solution

Control validation behavior for an entire solution using the `validationMode` property:

```powershell
solutions = @(
    # Error mode (default) - validation failures cause pipeline to fail
    @{
        name = 'MySolution'
        validationMode = 'error'
    },
    
    # Warning mode - validation failures are reported as warnings only
    @{
        name = 'MyLegacySolution'
        validationMode = 'warning'
    },
    
    # Disabled mode - no validation is performed
    @{
        name = 'MyTestSolution'
        validationMode = 'disabled'
    }
)
```

**Validation Modes:**
- `'error'` (default): Validation failures cause pipeline to fail
- `'warning'`: All validation issues are reported as warnings; pipeline continues
- `'disabled'`: No validation is performed; warning message is displayed

### Configure Individual Validation Rules

You can control behavior for specific validation rules using the `skipValidationRules` property with the `mode` setting:

#### Skip a Rule Entirely

```powershell
solutions = @(
    @{
        name = 'MySolution'
        skipValidationRules = @(
            @{
                ruleName = 'SolutionUsesSystemPublisher'
                mode = 'skip'  # Don't run this rule at all
            }
        )
    }
)
```

#### Run a Rule in Warning Mode

```powershell
solutions = @(
    @{
        name = 'MySolution'
        skipValidationRules = @(
            @{
                ruleName = 'ComponentInMoreThanOneUnmanagedSolution'
                mode = 'warning'  # Run rule but report as warnings
            }
        )
    }
)
```

**Mode Options:**
- `'skip'` (default): Don't run the rule
- `'warning'`: Run the rule but report findings as warnings instead of errors
- `'error'`: Run the rule normally (rarely needed as this is the default)

### Component-Specific Configuration

Apply validation modes to specific components by type, ID, or schema name:

#### By Component Type

```powershell
solutions = @(
    @{
        name = 'MySolution'
        skipValidationRules = @(
            @{
                ruleName = 'ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix'
                componentType = 1  # Only applies to entities (type 1)
                mode = 'warning'   # Warn instead of error
            }
        )
    }
)
```

Common component type numbers:
- `1` - Entity (Table)
- `2` - Attribute (Column)
- `9` - Option Set
- `29` - Process (Workflow/Flow)
- `60` - System Form
- `61` - Web Resource
- `80` - Plugin Step
- `90` - Plugin Type
- `300` - Canvas App
- `380` - Environment Variable Definition
- `381` - Environment Variable Value

For a complete list, see [Microsoft's component type reference](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/solutioncomponent-entity).

#### By Component ID

```powershell
solutions = @(
    @{
        name = 'MySolution'
        skipValidationRules = @(
            @{
                ruleName = 'ComponentInMoreThanOneUnmanagedSolution'
                componentType = 1
                componentId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
                mode = 'skip'  # Skip for this specific component
            }
        )
    }
)
```

#### By Component Schema Name

```powershell
solutions = @(
    @{
        name = 'MySolution'
        skipValidationRules = @(
            @{
                ruleName = 'ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix'
                componentType = 1  # Entity
                componentSchemaName = 'legacy_customtable'
                mode = 'warning'  # Warn for this legacy component
            }
        )
    }
)
```

### Combined Configurations

You can combine multiple configurations for fine-grained control:

```powershell
solutions = @(
    @{
        name = 'MySolution'
        validationMode = 'error'  # Global mode for this solution
        skipValidationRules = @(
            # Skip entire rule
            @{
                ruleName = 'SolutionUsesSystemPublisher'
                mode = 'skip'
            },
            # Warning mode for all components
            @{
                ruleName = 'ComponentInMoreThanOneUnmanagedSolution'
                mode = 'warning'
            },
            # Warning for specific component type
            @{
                ruleName = 'ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix'
                componentType = 61  # Web Resources
                mode = 'warning'
            },
            # Skip for specific component by ID
            @{
                ruleName = 'DependencyOnSolutionNotAllowed'
                componentType = 1
                componentId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
                mode = 'skip'
            },
            # Warning for specific component by name
            @{
                ruleName = 'EnvironmentVariableCurrentValueInSolution'
                componentType = 380
                componentSchemaName = 'legacy_envvar'
                mode = 'warning'
            }
        )
    }
)
```

### Mode Precedence

When multiple configurations could apply, the most specific wins:

1. Component-specific mode (by ID, type, or schema name)
2. Rule-level mode (applies to all components for that rule)
3. Solution-level `validationMode`
4. Default ('error' mode)

## Configuration Reference

### Solution Configuration Properties

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `name` | string | Yes | Unique solution name |
| `deployUnmanaged` | boolean | No | Whether to deploy unmanaged version |
| `serviceAccountUpnConfigKey` | string | No | Environment config key for service account UPN |
| `validationMode` | string | No | Validation mode: 'error' (default), 'warning', or 'disabled' |
| `skipValidationRules` | array | No | Array of rule configurations (see below) |

### Validation Rule Configuration

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `ruleName` | string | Yes | Name of the validation rule |
| `mode` | string | Yes | 'skip', 'warning', or 'error' - controls how rule violations are handled |
| `componentType` | integer | No | Apply only for this component type number |
| `componentId` | string (GUID) | No | Apply only for this specific component GUID (include componentType) |
| `componentSchemaName` | string | No | Apply only for component with this schema name (include componentType) |

**Note**: If only `ruleName` and `mode` are specified (no component filters), the mode applies to the entire rule. When using `componentId` or `componentSchemaName`, also include `componentType` for better performance and clarity.

## Best Practices

1. **Prefer Fixing Over Configuring**: Address validation errors by fixing the underlying issues rather than changing validation behavior
2. **Use Warning Mode for Migration**: When working with legacy solutions, use warning mode to maintain visibility while not blocking deployments
3. **Document Justification**: Add comments in `alm-config.psd1` explaining why validation behavior is modified
4. **Use Granular Configurations**: Prefer component-specific configurations over solution-wide or rule-wide changes
5. **Review Regularly**: Periodically review validation configurations to see if issues have been resolved
6. **Track Technical Debt**: Treat validation skips and warning overrides as technical debt to be addressed in future sprints
7. **Start Strict**: Begin with default error mode and only relax validation when there's a clear business justification

## Troubleshooting

### Finding Component IDs

To find a component's GUID, check the validation error/warning output. The message includes the component ID in the format `[RuleName : ComponentId]`.

### Finding Component Types

Component type numbers are included in validation error/warning messages. You can also query the `solutioncomponent` table in Dataverse to see component types for your solution.

### Validation Runs Locally But Fails in Pipeline

Ensure your local environment matches the source environment in the pipeline. Validation connects to the Dataverse environment, so environmental differences can cause different results.

### Warnings Not Showing in Pipeline

Check your pipeline output settings. Warnings are logged using `##vso[task.logissue type=warning]` and should appear in the pipeline logs.

### Understanding Mode Precedence

If validation behavior seems unexpected, check for multiple configurations. Component-specific modes override rule-level modes, which override solution-level modes.

## See Also

- Individual validation rule documentation in `ttec-digital/validationrules/`
- [ALM Configuration Guide](../docs/config/alm-config.md)
- [Solution Component Types Reference](https://learn.microsoft.com/en-us/power-apps/developer/data-platform/solutioncomponent-entity)
