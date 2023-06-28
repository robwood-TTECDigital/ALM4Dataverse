# Per-branch setup

**Ensure [per repo setup](/Setup-and-Configuration/Per-Repo-Setup) has been completed first.**

Each branch needs separate setup.

Project will generally start with only one branch which is called `main`.

Each branch should have separate development and test environments.

## Deployment Config

Edit the pipeline/workflow `DEPLOY` YAML file and create a stage for each environment using the examples you can see in the file.

## What's next?

Complete the [Per Environment Setup](/Setup-and-Configuration/Per-Env-Setup) for each environment associated with the branch.