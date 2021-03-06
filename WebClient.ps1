<# 
.Synopsis
A script used to download update files for networking appliances.

.Description
Iterates through a list of network appliances from the equipment.config file
and fetches update/upgrade manifests for each appliance.  Downloads each update/upgrade from the manifest.
Adds all updates/upgrades to an archive file and moves archive to IIS server so appliances can access them.

Script Name: WebClient.ps1
Version: 1.4

Author: Johnny Wagner
Date: 2/27/2015
Email: johnny@johnnybu.com
#>


# PARAMETERS
[CmdletBinding()]
Param
(
    #Use this parameter to override the default Cisco update server.
    [Parameter(Mandatory = $False, Position = 0)]
    [String]$ciscoServer = "update-manifests.sco.cisco.com",
    
    #Use this parameter to specify the url of the source sever the files will be placed on.
    [Parameter(Mandatory = $True, Position = 1)]
    [String]$updateServer,

    #Use this parameter to override the default number of download retries.
    [Parameter(Mandatory = $False, Position = 2)]
    [int]$numberOfRetries = 3,

    #Use this switch to run the script in upgrade (OS) mode rather than update (Applications) mode.
    [Switch]$Upgrade,

    #Use this switch to turn off logging
    [Switch]$NoLogging
)

#End PARAMETERS

# VARIABLES

$versionNumber = "1.4"

# End VARIABLES

# FUNCTIONS

<#
Gets current operating directory
to be used with base path variable
#>
function Get-ScriptDirectory
{
    $Invocation = (Get-Variable MyInvocation -Scope 1).Value;
    if($Invocation.PSScriptRoot)
    {
        $Invocation.PSScriptRoot;
    }
    Elseif($Invocation.MyCommand.Path)
    {
        Split-Path $Invocation.MyCommand.Path
    }
    else
    {
        $Invocation.InvocationName.Substring(0,$Invocation.InvocationName.LastIndexOf("\"));
    }
}

<#
Gets the md5 hash of the file to check and compares it against the
hash supplied by the manifest xml file.  If the file matches,
it writes a host message saying so.  If the file does not match,
it deletes the file.
#>
function Check-FileHash
{
    param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$fileToCheck,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$md5
    )

    $fileHash = Get-FileHash $fileToCheck -Algorithm MD5

    Write-Log ("Matching the file hash: ", $fileHash.Hash," to the supplied hash: $md5" -join "")

    #Check the given md5 hash against the file hash.  Delete file if hash is not a match.
    if($fileHash.Hash.ToString() -eq $md5)
    {
        Write-Log "File successfully verified."
    }
    else
    {
        Write-Log "Hash not matched.  Deleteing File."
        if(Test-Path $fileToCheck)
        {
            Remove-Item $fileToCheck
        }
    } 
}

# Set the base script path
$basePath=Get-ScriptDirectory

# dot source Logging function
.$basePath\Logging.ps1

# dot source the xml validation function
.$basePath\XmlValidate.ps1

# dot source the Web Request function
.$basePath\WebRequest.ps1

#End FUNCTIONS

#SCRIPT MAIN

#Set up Logging if switch is used
if (-Not $NoLogging)
{
    $appendDate = get-date -UFormat "%Y%m%d%H%M%S";
    $loggingFilePreference="$basePath\Log\WebClient_Log_$appendDate.txt";
    $loggingPreference="continue";
    Write-Log "Creating logging directory; $basePath\Log, if it does not exist.";
    New-Item -ItemType "directory" -Path "$basePath\Log" -ErrorAction "Ignore";
    Write-Log "Logging turned on.  Setting variables.";
    Write-Log "loggingPreference is $loggingPreference.";
    Write-Log "Creating log file; $loggingFilePreference";
}

Write-Log "WebClient started.  Version: $versionNumber.";

Write-Log "basePath is $basePath.";

# Path for all files to transfer to offline webserver at conclusion of script
$httpdPath = $basePath, "httpd" -join "\"

Write-Log "httpdPath is $httpdPath.";

#Configuration file used for run-time parameters
Write-Log "Loading xml config file and validating the Xml."

[xml]$configFile = Test-Xml ($basePath, "equipment.config" -join "\") ($basePath, "equipment.xsd" -join "\")

## Fetch Server Update Manifest
foreach ($device in $configFile.Devices.Device)
{
    #Generate URL for Manifest Fetch
    If ($upgrade) 
    {
        $manifestType = "upgrade"
        $apps = "asyncos"

        Write-Log "Application is $apps."
    } 
    else 
    {
        for($i=0; $i -lt $device.Applications.Application.Length; $i++)
        {
            if($i -eq 0)
            {
                $apps = $device.Applications.Application[$i]
            }
            else
            {
                $apps += "," + $device.Applications.Application[$i]
            }
        }

        $manifestType = "update"

        Write-Log "Applications are $apps."
    }

    Write-Log "Manifest type is $manifestType."

    #build the uri for the manifest download
    $uri = "https://", $ciscoServer, "/fetch_manifest?", "&", $device.Type, "=", $device.SerialNumber, "&model=", `
    $device.Model, "&apps=", $apps, "&release_tag=", $device.Version -join ""

    Write-Log "Manifest uri is $uri."

    ## Load the Client Certificate from the Windows Certificate Store by query
    Write-Log "Loading the client pfx certificate."
    $cert = gci -Path cert:\* -Recurse -Eku "Digital Signature (80)" -SSLServerAuthentication | 
            ? {$_.HasPrivateKey -and $_.Issuer -eq "CN=Keymaster CA, OU=Security, O=Cisco Systems Inc., L=San Jose, S=California, C=US" }

    # force SSLv3, instead of TLS 1.0
    [Net.ServicePointManager]::SecurityProtocol = "ssl3"

    # Set the location of the manifest file
    $manifestLocation = $basePath, "\manifests\", $device.Model, ".", $device.Version, ".", $manifestType, "_manifest.xml" -join ""
    Write-Log "The manifest location is $manifestLocation."

    #Create the Manifest directory
    New-Item $basePath"\manifests\" -ItemType "directory" -ErrorAction "Ignore"

    # Invoke the web request only if the certificate variable is not null
    Write-Log "Downloading the server manifest file."

    Get-FileFromServer $uri $manifestLocation $numberOfRetries $cert

    #End Fetch Server Update Manifest

    # Parse Server Update Manifest

    #loads manifest xml file in to memory
    [xml]$manifest = gc $manifestLocation

    #traverses xml tree for file information and calls the Get-FileFromServer method for each file
    foreach ($application in $manifest.server_manifest.applications.application)
    {
        foreach ($component in $application.components.component)
        {
            foreach ($file in $component.files.file)
            {
			   # remove the file name
			   $winpath = Split-Path ($file.path -replace "/","\") -Parent

			   # make full OS directory path
			   $winpath = $httpdPath, "\", $winpath -join ""
			   
			   # make directories (quietly) if needed
			   New-Item $winpath -ItemType "Directory" -ErrorAction "Ignore"
								   
               $source = $file.scheme, "://", $file.server, "/", $file.path -join ""

			   $destination = $winpath, "\", $file.file_version -join ""
               
			   Write-Log "Attempting to download the file from $source."

               Get-FileFromServer $source $destination $numberOfRetries
               
               #Only check md5 hash if this is an update
               if (!($Upgrade))
               {
                    Check-FileHash $destination $file.md5 
               }
               else
               {
                    Write-Log "File hash not checked for Upgrade manifest type."
               }
               
               #Update the server(s) strings to the target update server parameter.
               $file.server = $updateServer
               $file.server2 = $updateServer
            }    
        }
    }# End Parse Server Manifest 
	
	# Write modified manifest data to the httpd base directory
	$newmanifestLocation = $httpdPath, "\", $device.SerialNumber , "_", $manifestType , ".xml" -join ""
	$manifest.Save($newmanifestLocation)

} # End Parse equipment Config file

Write-Log "Webclient script completed successfully."
Exit


# END SCRIPT MAIN