```powershell
    # List of AAD mapped Dataverse Teams to create and assign roles to
    # Use a new GUID for each team ID
    # AadGroupId can contain $(Placeholders) to allow value to be env specific.
    # These are supplied during deployment.
    # Leave BU name empty to signify the root BU (as name varies across envs)
    # Leave Team name emtpy to singify the default/automatic team for the BU
    AadGroupTeams=@(
        # @{
        #     BusinessUnitName="";
        #     TeamId="a8c7cf63-d969-417c-aec6-4ae7ee16500e";
        #     TeamName="Managers";
        #     AadGroupId='$(ManagersAadGroupId)';
        #     RoleNames=@("Manager", "Basic User");
        # }
    );

    # List of BU default teams to assign roles to
    # Leave BU name empty to signify the root BU (as name varies across envs)
    BuDefaultTeams=@(
        # @{
        #     BusinessUnitName="";
        #     RoleNames=@("Manager", "Basic User");
        # }
    );

    # List of owner Teams to ensure exist and assign roles to
    # Use a new GUID for each team ID
    # Leave BU name empty to signify the root BU (as name varies across envs)
    OwnerTeams=@(
        # @{
        #     BusinessUnitName="";
        #     TeamId="fbccb489-90dd-4573-8f07-00398e60db55";
        #     TeamName="My Owner Team";
        #     RoleNames=@("Manager", "Basic User");
        # }
    );

    # List of access Teams to ensure exist
    # Use a new GUID for each team ID
    # Leave BU name empty to signify the root BU (as name varies across envs)
    AccessTeams=@(
        # @{
        #     BusinessUnitName="";
        #     TeamId="a8c7cf63-d969-417c-aec6-4ae7ee16500e";
        #     TeamName="My Access Team";
        # }
    );
```