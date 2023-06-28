**“Simple Mode” Development Process**

This model provides:
-	A shared development environment used by all developers working on the same version of the product.
-	Source control of changes – but all changes made in the environment during the sprint will be captured as a single set of changes each time it is run.

This model does not provide:
   - Isolation of each developer from each other. 
   - The ability to strictly separate each individual change/feature and review or deploy them separately. Make sure to consider this, but often this is not really required and instead you can use other methods to control when features become available to users.

Simple mode does not require a BUILD environment.

**“Advanced Mode” Development Process**

Choose this model if you must have:
-	Developers working in isolation from each other either on a per developer or per feature basis
-	The ability to strictly separate each individual change or different streams of work/changes like the support/maintenance of a version that is in production versus a longer term project.
- Strict review process before changes are integrated. (Note: If you don't need strict review, you don't need this).

Advanced mode requires:
- Azure DevOps. (Has not yet been extended to GitHub) 
- More dev and test environments.
- A BUILD environment.

# How to pick?

We recommend two approaches depending on the needs of the project. 

Projects should default to the simple mode unless or until there is a genuine need for the features in the advanced mode model and time has been factored into the project to deliver these. These features do not come for free and add a large overhead to the activities of the team on a daily basis.

It’s important to make sure the cost of these overheads results in a real benefit to the project as opposed to just blindly following general rules that say these are always required.

Even when the advanced mode is needed for isolation, try keep it simple. Minimise the number of different branches.


# When is isolation required?

Multiple branches are needed if you need to isolate (keep separate) changes made to different versions of the product. For instance, to be able to maintain (make bug fixes to) a version that is in production whilst continued development of a future version is still in progress. 

Without isolation, there would be no reliable way of testing and deploying only the small bug fix change that needs to go into production quickly without the other bigger and untested changes. Attempting to capture and deploy only the changed component(s) in an environment containing other changes is dangerous and any testing is invalid because the environment does not reflect the state of the target production environment.

Wherever possible, use only a single branch. Avoid parallel working scenarios if possible and if you cannot, reduce the amount of time where there is an overlap. Every branch adds overhead, and the longer branches exist for, the more overhead there is. 
Move to the higher complexity model by branching only once needed and remove it once no longer needed.  Most projects will only need branching once a version goes into production and only if major development work continues.

If multiple branches are used, merge frequently to minimise divergence and try plan to avoid large conflicting changes. For instance, try avoid making large changes in a support branch and instead put them on the backlog for the next major version.

Branches cannot share environments. Dedicated DEV environments are needed for each branch. Name the environments clearly so there is no confusion. For instance, include the branch name in the name. Dedicated test (normally SAT and UAT) environment are also required if you want to test the changes before merging.
