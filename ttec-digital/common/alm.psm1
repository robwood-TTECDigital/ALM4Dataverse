#Requires -PSEdition Core
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

# Load all scripts in functions folder
get-childitem $PSScriptRoot -Filter *.ps1 | foreach-object {
  . $_.FullName
}
