$rnwoodModule = Get-Module -Name Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1
if (-not $rnwoodModule) {
  $rnwoodModule = Get-Module -ListAvailable -Name Rnwood.Dataverse.Data.PowerShell |
    Sort-Object Version -Descending |
    Select-Object -First 1
  if (-not $rnwoodModule) {
    throw 'Rnwood.Dataverse.Data.PowerShell module is not installed.'
  }

  Import-Module $rnwoodModule.Path -Global -ErrorAction Stop
  $rnwoodModule = Get-Module -Name Rnwood.Dataverse.Data.PowerShell | Select-Object -First 1
}

$sdkAssemblyNames = @('Microsoft.Xrm.Sdk', 'Microsoft.Crm.Sdk.Proxy')
$loadedSdkAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies() |
  Where-Object { $sdkAssemblyNames -contains $_.GetName().Name } |
  Where-Object {
    $loadContext = [System.Runtime.Loader.AssemblyLoadContext]::GetLoadContext($_)
    $null -ne $loadContext -and $loadContext.Name -ne 'Default'
  }
$xrmSdkAssembly = $loadedSdkAssemblies |
  Where-Object { $_.GetName().Name -eq 'Microsoft.Xrm.Sdk' } |
  Select-Object -First 1
if (-not $xrmSdkAssembly) {
  throw 'Microsoft.Xrm.Sdk.dll was not loaded by Rnwood.Dataverse.Data.PowerShell.'
}
$rnwoodLoadContext = [System.Runtime.Loader.AssemblyLoadContext]::GetLoadContext($xrmSdkAssembly)

$typeAccelerators = [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.TypeAccelerators', $true)
$typeAcceleratorAdd = $typeAccelerators.GetMethod(
  'Add',
  [System.Reflection.BindingFlags]'Public,NonPublic,Static')
$typeAcceleratorMap = $typeAccelerators.GetProperty('Get').GetValue($null)
$registeredTypeCount = 0
foreach ($sdkAssemblyName in $sdkAssemblyNames) {
  $sdkAssembly = $loadedSdkAssemblies |
    Where-Object { $_.GetName().Name -eq $sdkAssemblyName } |
    Select-Object -First 1
  if (-not $sdkAssembly) {
    $sdkAssemblyPath = Get-ChildItem -LiteralPath $rnwoodModule.ModuleBase -Recurse -Filter "$sdkAssemblyName.dll" -File |
      Where-Object { $_.FullName -match '[\\/]loader[\\/]net' } |
      Select-Object -First 1
    if (-not $sdkAssemblyPath) {
      throw "$sdkAssemblyName was not loaded by Rnwood.Dataverse.Data.PowerShell and was not found under '$($rnwoodModule.ModuleBase)'."
    }
    $sdkAssembly = $rnwoodLoadContext.LoadFromAssemblyPath($sdkAssemblyPath.FullName)
  }

  $assemblyLoadContext = [System.Runtime.Loader.AssemblyLoadContext]::GetLoadContext($sdkAssembly)

  foreach ($sdkType in $sdkAssembly.GetExportedTypes()) {
    if (-not $typeAcceleratorMap.ContainsKey($sdkType.FullName)) {
      $typeAcceleratorAdd.Invoke($null, [object[]] @($sdkType.FullName, $sdkType)) | Out-Null
      $registeredTypeCount++
    }
  }
}
