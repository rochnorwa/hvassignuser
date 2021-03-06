$ErrorActionPreference = 'Stop'
<#
    .SYNOPSIS
    Assigns a Horizon Desktop machine

    .DESCRIPTION
    This script assigns a user to a Horizon desktop machine. This will only work with dedicated desktop pools.
    It will receive the connection server fqdn, Desktop pool and machine, login and domain names from the CU Console.

    .NOTES
    This script requires VMWare PowerCLI to be installed on the machine running the script.
    PowerCLI can be installed through PowerShell (PowerShell version 5 or higher required) by running the command 'Install-Module VMWare.PowerCLI -Force -AllowCLobber -Scope AllUsers' Or by using the 'Install VMware PowerCLI' script.
    Credentials can be set using the 'Prepare machine for Horizon View scripts' script.

    The account that runs the script needs to have at least read only administrator permissions in Horizon View and permissions to create folders and add machines in ControlUP
    Some functions require Powershell 5.1 or higher

    Modification history:   20/02/2020 - Wouter Kursten - First version
                            25/02/2020 - Wouter Kursten

    Changelog:
        -   25/02/2020 - CHanged output and fixed errors when assigning in manual pools.


    .LINK
    https://code.vmware.com/web/tool/11.3.0/vmware-powercli
    https://kb.vmware.com/s/article/2143853 (Horizon version and build numbers)


    .COMPONENT
    VMWare PowerCLI
#>

# Name of the Horizon View connection server. Passed from the ControlUp Console.
[string]$HVConnectionServerFQDN = $args[0]
# Name of the Horizon Desktop Pool. Passed from the ControlUp Console.
[string]$HVDesktopPoolname = $args[1]
# Name of the Horizon Machine that needs to be deleted. Passed from the ControlUp Console.
[string]$hvMachineName= $args[2]
# User loginname of the user that needs to be assigned the desktop. Passed from the ControlUp Console.
[string]$HVUserName= $args[3]
# Name of the active directory domain, NETBIOS or DNS. Passed from the ControlUp Console.
[string]$HVDomain= $args[4]


Function Out-CUConsole {
    <# This function provides feedback in the console on errors or progress, and aborts if error has occured.
      If only Message is passed this message is displayed
      If Warning is specified the message is displayed in the warning stream (Message must be included)
      If Stop is specified the stop message is displayed in the warning stream and an exception with the Stop message is thrown (Message must be included)
      If an Exception is passed a warning is displayed and the exception is thrown
      If an Exception AND Message is passed the Message message is displayed in the warning stream and the exception is thrown
    #>

    Param (
        [Parameter(Mandatory = $false)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [switch]$Warning,
        [Parameter(Mandatory = $false)]
        [switch]$Stop,
        [Parameter(Mandatory = $false)]
        $Exception
    )

    # Throw error, include $Exception details if they exist
    if ($Exception) {
        # Write simplified error message to Warning stream, Throw exception with simplified message as well
        If ($Message) {
            Write-Warning -Message "$Message`n$($Exception.CategoryInfo.Category)`nPlease see the Error tab for the exception details."
            Write-Error "$Message`n$($Exception.Exception.Message)`n$($Exception.CategoryInfo)`n$($Exception.Exception.ErrorRecord)" -ErrorAction Stop
        }
        Else {
            Write-Warning "There was an unexpected error: $($Exception.CategoryInfo.Category)`nPlease see the Error tab for details."
            Throw $Exception
        }
    }
    elseif ($Stop) {
        # Write simplified error message to Warning stream, Throw exception with simplified message as well
        Write-Warning -Message "There was an error.`n$Message"
        Throw $Message
    }
    elseif ($Warning) {
        # Write the warning to Warning stream, thats it. It's a warning.
        Write-Warning -Message $Message
    }
    else {
        # Not an exception or a warning, output the message
        Write-Output -InputObject $Message
    }
}


function Get-CUStoredCredential {
    param (
        [parameter(Mandatory = $true,
            HelpMessage = "The system the credentials will be used for.")]
        [string]$System
    )
    # Get the stored credential object
    [string]$strCUCredFolder = "$([environment]::GetFolderPath('CommonApplicationData'))\ControlUp\ScriptSupport"
    Import-Clixml $strCUCredFolder\$($env:USERNAME)_$($System)_Cred.xml
}

function Load-VMWareModules {
    <# Imports VMware modules
    NOTES:
    - The required modules to be loaded are passed as an array.
    - In versions of PowerCLI below 6.5 some of the modules can't be imported (below version 6 it is Snapins only) using so Add-PSSnapin is used (which automatically loads all VMWare modules)
    #>

    param (
        [parameter(Mandatory = $true,
            HelpMessage = "The VMware module to be loaded. Can be single or multiple values (as array).")]
        [array]$Components
    )

    # Try Import-Module for each passed component, try Add-PSSnapin if this fails (only if -Prefix was not specified)
    # Import each module, if Import-Module fails try Add-PSSnapin
    foreach ($component in $Components) {
        try {
            $null = Import-Module -Name VMware.$component
        }
        catch {
            try {
                $null = Add-PSSnapin -Name VMware
            }
            catch {
                Out-CUConsole -Message 'The required VMWare modules were not found as modules or snapins. Please check the .NOTES and .COMPONENTS sections in the Comments of this script for details.' -Stop
            }
        }
    }
}

Function Test-ArgsCount {
    <# This function checks that the correct amount of arguments have been passed to the script. As the arguments are passed from the Console or Monitor, the reason this could be that not all the infrastructure was connected to or there is a problem retreiving the information.
    This will cause a script to fail, and in worst case scenarios the script running but using the wrong arguments.
    The possible reason for the issue is passed as the $Reason.
    Example: Test-ArgsCount -ArgsCount 3 -Reason 'The Console may not be connected to the Horizon View environment, please check this.'
    Success: no ouput
    Failure: "The script did not get enough arguments from the Console. The Console may not be connected to the Horizon View environment, please check this.", and the script will exit with error code 1
    Test-ArgsCount -ArgsCount $args -Reason 'Please check you are connectect to the XXXXX environment in the Console'
    #>
    Param (
        [Parameter(Mandatory = $true)]
        [int]$ArgsCount,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )
}

function Connect-HorizonConnectionServer {
    param (
        [parameter(Mandatory = $true,
            HelpMessage = "The FQDN of the Horizon View Connection server. IP address may be used.")]
        [string]$HVConnectionServerFQDN,
        [parameter(Mandatory = $true,
            HelpMessage = "The PSCredential object used for authentication.")]
        [PSCredential]$Credential
    )
    # Try to connect to the Connection server
    try {
        Connect-HVServer -Server $HVConnectionServerFQDN -Credential $Credential
    }
    catch {
        Out-CUConsole -Message 'There was a problem connecting to the Horizon View Connection server.' -Exception $_
    }
}

function Disconnect-HorizonConnectionServer {
    param (
        [parameter(Mandatory = $true,
            HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )
    # Try to connect from the connection server
    try {
        Disconnect-HVServer -Server $HVConnectionServer -Confirm:$false
    }
    catch {
        Out-CUConsole -Message 'There was a problem disconnecting from the Horizon View Connection server.' -Exception $_
    }
}

function Get-HVDesktopPool {
    param (
        [parameter(Mandatory = $true,
        HelpMessage = "Displayname of the Desktop Pool.")]
        [string]$HVPoolName,
        [parameter(Mandatory = $true,
        HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )
    # Try to get the Desktop pools in this pod
    try {
        # create the service object first
        [VMware.Hv.QueryServiceService]$queryService = New-Object VMware.Hv.QueryServiceService
        # Create the object with the definiton of what to query
        [VMware.Hv.QueryDefinition]$defn = New-Object VMware.Hv.QueryDefinition
        # entity type to query
        $defn.queryEntityType = 'DesktopSummaryView'
        # Filter on the correct displayname
        $defn.Filter = New-Object VMware.Hv.QueryFilterEquals -property @{'memberName'='desktopSummaryData.displayName'; 'value' = "$HVPoolname"}
        # Perform the actual query
        [array]$queryResults= ($queryService.queryService_create($HVConnectionServer.extensionData, $defn)).results
        # Remove the query
        $queryService.QueryService_DeleteAll($HVConnectionServer.extensionData)
        # Return the results
        if (!$queryResults){
            Out-CUConsole -message "Can't find $HVPoolName, exiting." -Exception "$HVPoolname not found" 
            exit
        }
        else {
            return $queryResults
        }
    }
    catch {
        Out-CUConsole -Message 'There was a problem retreiving the Horizon View Desktop Pool.' -Exception $_
    }
}

function Get-HVDesktopMachine {
    param (
        [parameter(Mandatory = $true,
        HelpMessage = "ID of the Desktop Pool.")]
        [VMware.Hv.DesktopId]$HVPoolID,
        [parameter(Mandatory = $true,
        HelpMessage = "Name of the Desktop machine.")]
        [string]$HVMachineName,
        [parameter(Mandatory = $true,
        HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )

    try {
        # create the service object first
        [VMware.Hv.QueryServiceService]$queryService = New-Object VMware.Hv.QueryServiceService
        # Create the object with the definiton of what to query
        [VMware.Hv.QueryDefinition]$defn = New-Object VMware.Hv.QueryDefinition
        # entity type to query
        $defn.queryEntityType = 'MachineDetailsView'
        # Filter so we get the correct machine in the correct pool
        $poolfilter = New-Object VMware.Hv.QueryFilterEquals -property @{'memberName'='desktopData.id'; 'value' = $HVPoolID}
        $machinefilter = New-Object VMware.Hv.QueryFilterEquals -property @{'memberName'='data.name'; 'value' = "$HVMachineName"}
        $filterlist = @()
        $filterlist += $poolfilter
        $filterlist += $machinefilter
        $filterAnd = New-Object VMware.Hv.QueryFilterAnd
        $filterAnd.Filters = $filterlist
        $defn.Filter = $filterAnd
        # Perform the actual query
        [array]$queryResults= ($queryService.queryService_create($HVConnectionServer.extensionData, $defn)).results
        # Remove the query
        $queryService.QueryService_DeleteAll($HVConnectionServer.extensionData)
        # Return the results
        if (!$queryResults){
            Out-CUConsole -message "Can't find $HVPoolName, exiting." -Exception "$HVPoolname not found"
            exit
        }
        else {
            return $queryResults
        }
    }
    catch {
        Out-CUConsole -Message 'There was a problem retreiving the Horizon View Desktop Pool.' -Exception $_
    }
}

function get-hvpoolspec{
    param (
        [parameter(Mandatory = $true,
            HelpMessage = "ID of the Desktop Pool.")]
        [VMware.Hv.DesktopId]$HVPoolID,
        [parameter(Mandatory = $true,
            HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )
    # Retreive the details of the desktop pool
    try {
        $HVConnectionServer.ExtensionData.Desktop.Desktop_Get($HVPoolID)
    }
    catch {
        Out-CUConsole -Message 'There was a problem retreiving the desktop pool details.' -Exception $_
    }
}

function new-hvdesktopassignment {
    param (
        [parameter(Mandatory = $true,
        HelpMessage = "ID of the machine.")]
        [VMware.Hv.MachineId]$HVMachineID,
        [parameter(Mandatory = $true,
        HelpMessage = "ID of the user.")]
        [VMware.Hv.UserOrGroupId]$HVUserID,
        [parameter(Mandatory = $true,
            HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )
    try{
        # Assignments are done by using the machineservice
        $machineservice=new-object vmware.hv.machineservice
        $machineinfohelper=$machineservice.read($HVConnectionServer.extensionData, $HVMachineID)
        $machineinfohelper.getbasehelper().setuser($HVUserID)
        $machineservice.update($HVConnectionServer.extensionData, $machineinfohelper)
    }
    catch {
        Out-CUConsole -Message 'There was a error setting the desktop assignment.' -Exception $_
    }
}

function Get-HVUser {
    param (
        [parameter(Mandatory = $true,
        HelpMessage = "User loginname..")]
        [string]$HVUserLoginName,
        [parameter(Mandatory = $true,
        HelpMessage = "Name of the Domain.")]
        [string]$HVDomain,
        [parameter(Mandatory = $true,
        HelpMessage = "The Horizon View Connection server object.")]
        [VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$HVConnectionServer
    )

    try {
        # create the service object first
        [VMware.Hv.QueryServiceService]$queryService = New-Object VMware.Hv.QueryServiceService
        # Create the object with the definiton of what to query
        [VMware.Hv.QueryDefinition]$defn = New-Object VMware.Hv.QueryDefinition
        # entity type to query
        $defn.queryEntityType = 'ADUserOrGroupSummaryView'
        # Filter to get the correct user
        $userloginnamefilter = New-Object VMware.Hv.QueryFilterEquals -property @{'memberName'='base.loginName'; 'value' = $HVUserLoginName}
        $domainfilter = New-Object VMware.Hv.QueryFilterEquals -property @{'memberName'='base.domain'; 'value' = "$HVDomain"}
        $filterlist = @()
        $filterlist += $userloginnamefilter
        $filterlist += $domainfilter
        $filterAnd = New-Object VMware.Hv.QueryFilterAnd
        $filterAnd.Filters = $filterlist
        $defn.Filter = $filterAnd
        # Perform the actual query
        [array]$queryResults= ($queryService.queryService_create($HVConnectionServer.extensionData, $defn)).results
        # Remove the query
        $queryService.QueryService_DeleteAll($HVConnectionServer.extensionData)
        # Return the results
        if (!$queryResults){
            Out-CUConsole -message "Can't find user $HVUserLoginName in domain $HVDomain, exiting." -Exception "$HVUserLoginName not found in domain $HVDomain"
            exit
        }
        else {
            return $queryResults
        }
    }
    catch {
        Out-CUConsole -Message 'There was a problem retreiving the user.' -Exception $_
    }
}

# Test arguments
Test-ArgsCount -ArgsCount 3 -Reason 'The Console or Monitor may not be connected to the Horizon View environment, please check this.'

# Set the credentials location
[string]$strCUCredFolder = "$([environment]::GetFolderPath('CommonApplicationData'))\ControlUp\ScriptSupport"

# Import the VMware PowerCLI modules
Load-VMwareModules -Components @('VimAutomation.HorizonView')

# Get the stored credentials for running the script
[PSCredential]$CredsHorizon = Get-CUStoredCredential -System 'HorizonView'

# Connect to the Horizon View Connection Server
[VMware.VimAutomation.HorizonView.Impl.V1.ViewObjectImpl]$objHVConnectionServer = Connect-HorizonConnectionServer -HVConnectionServerFQDN $HVConnectionServerFQDN -Credential $CredsHorizon

# Retreive the Desktop Pool details
$HVPool=Get-HVDesktopPool -HVPoolName $HVDesktopPoolname -HVConnectionServer $objHVConnectionServer

# But we only need the ID
$HVPoolID=($HVPool).id

# Retreive the pool spec to get the type
$HVPoolSpec=Get-HVPoolSpec -HVConnectionServer $objHVConnectionServer -HVPoolID $HVPoolID

# Retreive the details for the machine
$HVMachine=Get-HVDesktopMachine -HVConnectionServer $objHVConnectionServer -HVPoolID $HVPoolID -HVMachineName $hvMachineName

# Again we only need the id
$HVMachineID=($HVMachine).id

$HVUser=Get-HVUser -HVConnectionServer $objHVConnectionServer -HVUserLoginName $HVUserName -HVDomain $HVDomain

# Yes the ID is what we need

$HVUserID=($HVUser).id

# Desktop assignments are only possible with deicated desktop pools
if ($HVPoolSpec.type -eq "AUTOMATED" -and $HVPoolSpec.AutomatedDesktopData.userassignment.userassignment -ne "DEDICATED") {
    Out-CUConsole -Message "This is not a dedicated desktop so can't assign desktops."
    exit
}
elseif ($HVPoolSpec.type -eq "MANUAL" -and $HVPoolSpec.ManualDesktopData.userassignment.userassignment -ne "DEDICATED" ) {
    Out-CUConsole -Message "This is not a dedicated desktop so can't assign desktops."
    exit
}
else {
    new-hvdesktopassignment -HVConnectionServer $objHVConnectionServer -HVMachineID $HVMachineID -HVUserID $HVUserID
    Out-CUConsole -Message "Desktop assigned succesfully."
}

# Disconnect from the connection server
Disconnect-HorizonConnectionServer -HVConnectionServer $objHVConnectionServer
