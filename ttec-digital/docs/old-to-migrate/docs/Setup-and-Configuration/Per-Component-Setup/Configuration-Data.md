

1) Use the [Microsoft Configuration Migration Tool](https://learn.microsoft.com/en-us/power-platform/alm/configure-and-deploy-tools) to create a schema XML file for the tables you want to migrate data for bearing in mind:

- `UpdateCompare`=true should be set on the primary key column on most tables. [See this article for more info](https://www.develop1.net/public/post/2015/03/25/Using-the-Configuration-Data-Migration-Tool-with-non-unique-display-name-values)

- For tables where records are generated automatically by the platform such as `Team`, primary name values must be unique as the system will generate a different ID for the same logical record per environment. The name being unique is how the records can be identified.

2) Commit the schema file to `data/<name>/schema.xml` in source control, where `<name>` is a folder that doesn't already exist.

3) Edit `almconfig.ps1` file in source control and add `<name>` to the list of datasets. In the example below `config` is the name. Multiple datasets are supported and should be listed like this `"config1", "config2"`

## Setup
```powershell
    # List of Configuration Migration Tool data sets to manage
    # Put the schema.xml file in data/<name>/ and add <name> to the list below
    # <name> is anything unique.
    DataSets=@(
        "config"
    );
```

##Making changes

1) Edit the records in the DEV - branchname environment.

2) Run the `EXPORT` pipeline. This will export the changes from the dev environment associated with the branch and commit them into source control. You will see the files add/changed in the `data/<name>` path.

##Deployment

A zip file is generated and included in the build assets. The CMT tool is used to deploy the changes to the target environment when deployment runs.

An additional custom deletion step also runs. This will delete any records that are in the table in the target environment but not in the data set being deployed. This applies only to:
- tables that have not filtering conditions set up in the CMT schema
- non many-to-many (internal) tables.