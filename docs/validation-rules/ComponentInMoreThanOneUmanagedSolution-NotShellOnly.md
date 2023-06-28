# ComponentInMoreThanOneUmanagedSolution-NotShellOnly

## Overview

This validation rule detects when a component exists in the target solution with "Shell and Metadata" or "Shell Only" behavior, but also exists in another unmanaged solution with "Include Subcomponents" behavior. This creates a conflict where the other solution will export subcomponents that your solution expects to manage separately.

## Why This Matters

This conflict occurs when:
- Your solution includes a component as Shell Only or Shell and Metadata (expecting minimal export)
- Another unmanaged solution includes the same component with Include Subcomponents (exporting everything)

The problems this causes:

1. **Subcomponent Ownership Conflict**: The other solution exports subcomponents that may conflict with your solution's intent
2. **Unexpected Deployment Behavior**: When the other solution is deployed, it may overwrite subcomponents you manage elsewhere
3. **Solution Segmentation Broken**: Your solution's strategy of separating shell from subcomponents is undermined

## Component Behavior Types

| Behavior | Value | Description |
|----------|-------|-------------|
| Include Subcomponents | 0 | Exports the component and all its subcomponents (full export) |
| Shell and Metadata | 1 | Exports only the component shell and metadata |
| Shell Only | 2 | Exports only the component shell reference |

## Resolution

To resolve this issue:

1. **Align behaviors**: Ensure all solutions containing the component use consistent behavior settings
2. **Change the conflicting solution**: Update the other solution to use Shell Only or Shell and Metadata
3. **Consolidate solutions**: If the conflict can't be resolved, consider merging the solutions or re-architecting the solution structure

## Example

Your solution `Contoso_Forms` includes the `contoso_customer` table as Shell and Metadata (to manage forms separately).
Another solution `Contoso_Core` includes `contoso_customer` with Include Subcomponents.

**Problem**: When `Contoso_Core` is exported, it will include all subcomponents including forms, conflicting with your `Contoso_Forms` solution.

**Fix**: Change `Contoso_Core` to use Shell Only for `contoso_customer` if the forms should be managed by `Contoso_Forms`.

## Related Rules

- [ComponentInMoreThanOneUnmanagedSolution](ComponentInMoreThanOneUnmanagedSolution.md) - Multiple solutions with Include Subcomponents
- [ComponentInMoreThanOneUmanagedSolution-Metadata](ComponentInMoreThanOneUmanagedSolution-Metadata.md) - Multiple solutions with Shell and Metadata

## Additional Resources

- [Microsoft Docs: Solution component behavior](https://learn.microsoft.com/en-us/power-platform/alm/solution-concepts-alm)
- [Microsoft Docs: Segmented solutions](https://learn.microsoft.com/en-us/power-platform/alm/segmented-solutions-alm)
