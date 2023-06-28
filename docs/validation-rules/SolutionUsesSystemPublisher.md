# SolutionUsesSystemPublisher

## Overview

This validation rule detects when a solution uses a publisher that was created by the SYSTEM user. System-created publishers are typically default or out-of-box publishers that should not be used for custom solutions.

## Why This Matters

1. **No Control Over Prefix**: System publishers use generic prefixes that don't identify your organization
2. **Namespace Conflicts**: Multiple organizations using the same system publisher create component naming conflicts
3. **Professional Standards**: Production-ready solutions should use custom publishers with organization-specific prefixes
4. **Support and Maintenance**: Microsoft support and partner troubleshooting is easier with properly named publishers
5. **Solution Upgrades**: Managed solution upgrades work better with dedicated publishers

## Common System Publishers

Publishers created by SYSTEM that trigger this rule:
- **Default Publisher** (`DefaultPublisher`)
- **CDS Default Publisher** (`CdsDefaultPublisher`)
- **Microsoft** (`microsoftdynamic`)

## Resolution

To resolve this issue:

1. **Create a custom publisher**:
   - Go to Power Apps maker portal → Solutions
   - Click on Publishers
   - Create a new publisher with:
     - Your organization name
     - A unique prefix (e.g., `contoso`)
     - Contact information

2. **Create a new solution** with your custom publisher

3. **Migrate components**:
   - Add existing components to the new solution
   - For components with wrong prefix, create new versions with correct prefix
   - Update references and migrate data as needed

4. **Delete the old solution** once migration is complete

## Example

Your solution `MyBusinessApp` uses the "Default Publisher" (created by SYSTEM).

**Problem**: 
- Components get the generic `new_` or `cr000_` prefix
- Can't be distinguished from other organizations' components
- May conflict with Microsoft updates

**Fix**: Create a custom publisher `Contoso` with prefix `contoso_` and create a new solution using it.

## Best Practices for Publishers

| Attribute | Recommendation |
|-----------|---------------|
| Name | Your organization or project name |
| Display Name | Human-readable organization name |
| Prefix | 3-5 lowercase letters unique to your org |
| Option Value Prefix | Unique 5-digit number (10000-99999) |
| Contact Information | Valid email for the solution owner |

## Related Rules

- [ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix](ComponentSchemaNamePrefixDoesNotMatchPublisherPrefix.md) - Components with wrong prefix

## Additional Resources

- [Microsoft Docs: Solution publisher](https://learn.microsoft.com/en-us/power-platform/alm/solution-concepts-alm#solution-publisher)
- [Microsoft Docs: Create a solution publisher](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-solution#create-a-solution-publisher)
- [Microsoft Docs: Solution publisher prefix](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-solution#solution-publisher-prefix)
