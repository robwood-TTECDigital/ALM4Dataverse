```powershell
    # List of Canvas apps to share with AAD Groups
    # Each AAD group ID can contain $(Placeholders) to allow value to be env specific
    # These are supplied during deployment.
    CanvasAppSharing=@(
        # @{
        #     UniqueName="myco_someapp_d832a";
        #     AadGroupIds=@('$(ManagersAadGroupId)');
        # }      
    );

    # List of Flows to share with AAD Groups
    # Each AAD group ID can contain $(Placeholders) to allow value to be env specific
    # These are supplied during deployment.
    FlowAppSharing=@(
        # @{
        #     WorkflowId="9179688d-bd23-4e32-b58f-52068f19a322";
        #     AadGroupIds=@('$(ManagersAadGroupId)');
        # }      
    );    # List of Canvas apps to share with AAD Groups
    # Each AAD group ID can contain $(Placeholders) to allow value to be env specific
    # These are supplied during deployment.
    CanvasAppSharing=@(
        # @{
        #     UniqueName="myco_someapp_d832a";
        #     AadGroupIds=@('$(ManagersAadGroupId)');
        # }      
    );

    # List of Flows to share with AAD Groups
    # Each AAD group ID can contain $(Placeholders) to allow value to be env specific
    # These are supplied during deployment.
    FlowAppSharing=@(
        # @{
        #     WorkflowId="9179688d-bd23-4e32-b58f-52068f19a322";
        #     AadGroupIds=@('$(ManagersAadGroupId)');
        # }      
    );
```