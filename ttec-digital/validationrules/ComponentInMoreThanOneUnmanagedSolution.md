# ComponentInMoreThanOneUnmanagedSolution

## Overview

This validation rule detects when a component exists in more than one unmanaged solution with the "Include Subcomponents" (rootcomponentbehavior = 0) option enabled.

## Visual Representation

```mermaid
graph TD
    subgraph "❌ Violation"
        C1[Component: contoso_customer]
        S1[Solution: Contoso_Sales<br/>Include Subcomponents]
        S2[Solution: Contoso_Marketing<br/>Include Subcomponents]
        C1 -.-> S1
        C1 -.-> S2
        S1 -."❌ CONFLICT: Both export full component".-> S2
    end
    
    subgraph "✅ Correct Approach"
        C2[Component: contoso_customer]
        S3[Solution: Contoso_Sales<br/>Include Subcomponents]
        S4[Solution: Contoso_Marketing<br/>Shell Only]
        C2 --> S3
        C2 -.reference.-> S4
    end
    
    style S1 fill:#ffcccc
    style S2 fill:#ffcccc
    style S3 fill:#ccffcc
    style S4 fill:#ccffcc
    linkStyle 2 stroke:#ff0000,stroke-width:3px
```

## Why This Matters

When the same component exists in multiple unmanaged solutions with "Include Subcomponents" enabled:

1. **Export Conflicts**: When either solution is exported, both will include the full component definition, potentially creating version conflicts
2. **Deployment Issues**: Deploying these solutions to different environments may result in inconsistent component states
3. **Merge Complexity**: When both solutions modify the component, it becomes difficult to determine which version should be authoritative
4. **ALM Anti-pattern**: This pattern violates the principle of single ownership for components in Dataverse

## Component Behavior Types

| Behavior | Value | Description |
|----------|-------|-------------|
| Include Subcomponents | 0 | Exports the component and all its subcomponents (full export) |
| Shell and Metadata | 1 | Exports only the component shell and metadata |
| Shell Only | 2 | Exports only the component shell reference |

## Resolution

To resolve this issue:

1. **Identify the authoritative solution**: Determine which solution should "own" the component
2. **Remove from other solutions**: Remove the component from all other unmanaged solutions, or change their behavior to "Shell Only" or "Shell and Metadata"
3. **Use solution layering**: For shared components, consider using a base solution that owns the component, with other solutions referencing it via Shell Only

## Example

A table `contoso_customer` exists in both:
- `Contoso_Sales` solution (Include Subcomponents)
- `Contoso_Marketing` solution (Include Subcomponents)

**Fix**: Keep the table in `Contoso_Sales` with Include Subcomponents, and change `Contoso_Marketing` to use Shell Only for this table.

## Related Rules

- [ComponentInMoreThanOneUmanagedSolution-Metadata](ComponentInMoreThanOneUmanagedSolution-Metadata.md) - Same issue but for Shell and Metadata behavior
- [ComponentInMoreThanOneUmanagedSolution-NotShellOnly](ComponentInMoreThanOneUmanagedSolution-NotShellOnly.md) - Conflicting behaviors between solutions

## Additional Resources

- [Microsoft Docs: Solution component behavior](https://learn.microsoft.com/en-us/power-platform/alm/solution-concepts-alm)
- [Microsoft Docs: Solution layers](https://learn.microsoft.com/en-us/power-platform/alm/solution-layers-alm)
