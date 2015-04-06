#
# xAzureCluster: DSC resource to configure SQL availability group listener.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
    param
    (	
		[parameter(Mandatory)]
        [string] $Name,
		
		[Parameter(Mandatory)]
		[string] $PrimaryAvailabilityGroupIPAddress,

        [Parameter(Mandatory)]
		[string] $SecondaryAvailabilityGroupIPAddress,
		
        [Parameter(Mandatory)]
        [string] $PrimarySQLNodeName,

		[Parameter(Mandatory=$true)]
		[string] $AvailabilityGroupName,	
	
		[UInt32] $PublicPort = 1433,	
	
		[UInt32] $LoadBalancerProbePort = 59999,
                
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential,
		
		[parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential		
    )    
    
    $retvalue = @{
        Name = $Name
        IPAddress = "someval"
    }
}

#
# The Set-TargetResource cmdlet.
#
function Set-TargetResource
{
    param
    (	
        [parameter(Mandatory)]
        [string] $Name,
		
		[Parameter(Mandatory)]
		[string] $PrimaryAvailabilityGroupIPAddress,

        [Parameter(Mandatory)]
		[string] $SecondaryAvailabilityGroupIPAddress,
		
        [Parameter(Mandatory)]
        [string] $PrimarySQLNodeName,

		[Parameter(Mandatory=$true)]
		[string] $AvailabilityGroupName,
	
		[UInt32] $PublicPort = 1433,	
	
		[UInt32] $LoadBalancerProbePort = 59999,
                
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential,
		
		[parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential
    )

	$sa = $SqlAdministratorCredential.UserName
    $saPassword = $SqlAdministratorCredential.GetNetworkCredential().Password
	
    try
    {
        ($oldToken, $context, $newToken) = ImpersonateAs -cred $DomainAdministratorCredential
		
		If (!(Get-ClusterResource "IP Address $PrimaryAvailabilityGroupIPAddress" -ErrorAction SilentlyContinue))
		{
			Write-Verbose "Creating Availability Group IP Address [$PrimaryAvailabilityGroupIPAddress]"
			$params = @{
				Address = $PrimaryAvailabilityGroupIPAddress
				ProbePort = $LoadBalancerProbePort
				SubnetMask = "255.255.255.255"
				Network = (Get-ClusterNetwork)[0].Name
				OverrideAddressMatch = 1
				EnableDhcp = 0
				}
			Add-ClusterResource "IP Address $PrimaryAvailabilityGroupIPAddress" -ResourceType "IP Address" -Group $AvailabilityGroupName -ErrorAction Stop | 
				Set-ClusterParameter -Multiple $params -ErrorAction Stop
		}

        If (!(Get-ClusterResource "IP Address $SecondaryAvailabilityGroupIPAddress" -ErrorAction SilentlyContinue))
		{
			Write-Verbose "Creating Availability Group IP Address [$SecondaryAvailabilityGroupIPAddress]"
			$params = @{
				Address = $SecondaryAvailabilityGroupIPAddress
				ProbePort = $LoadBalancerProbePort
				SubnetMask = "255.255.255.255"
				Network = (Get-ClusterNetwork)[0].Name
				OverrideAddressMatch = 1
				EnableDhcp = 0
				}
			Add-ClusterResource "IP Address $SecondaryAvailabilityGroupIPAddress" -ResourceType "IP Address" -Group $AvailabilityGroupName -ErrorAction Stop | 
				Set-ClusterParameter -Multiple $params -ErrorAction Stop
		}

		If (!(Get-ClusterResource $Name -ErrorAction SilentlyContinue))
		{
			Write-Verbose "Creating Availability Group Network Name [$Name]"
			$params= @{
				Name = $Name
				DnsName = $Name
				}
			Add-ClusterResource -Name $Name -ResourceType "Network Name" -Group $AvailabilityGroupName -ErrorAction Stop | 
				Set-ClusterParameter -Multiple $params -ErrorAction Stop
		}

		Write-Verbose "Setting the Network Name's dependency on the IP Address"
		Get-ClusterGroup $AvailabilityGroupName  | 
			Get-ClusterResource | where Name -eq $Name | 
			Set-ClusterResourceDependency "[IP Address $PrimaryAvailabilityGroupIPAddress] or [IP Address $SecondaryAvailabilityGroupIPAddress]" -ErrorAction Stop

		Write-Verbose "Starting the Network Name resource"
		Start-ClusterResource -Name $Name -ErrorAction Stop | Out-Null

		Write-Verbose "Setting the Availability Group resource group's dependency on the Network Name"
		Get-ClusterResource -Name @($AvailabilityGroupName) | 
			Set-ClusterResourceDependency "[$Name]" -ErrorAction Stop                
    }
    finally
    {
        if ($context)
        {
            $context.Undo()
            $context.Dispose()
            CloseUserToken($newToken)
        }
    }
	
	Write-Verbose "Setting the Availability Group Listener port to [$PublicPort]"
	$query = @"
                ALTER AVAILABILITY GROUP $AvailabilityGroupName
				MODIFY LISTENER '$Name'
				(
					PORT = $PublicPort
				)
"@
				
	Write-Verbose -Message "Query: $query"	
    osql -S $PrimarySQLNodeName -U $sa -P $saPassword -Q $query
}

# 
# Test-TargetResource
#
function Test-TargetResource  
{
    param
    (	
        [parameter(Mandatory)]
        [string] $Name,
		
		[Parameter(Mandatory)]
		[string] $PrimaryAvailabilityGroupIPAddress,

        [Parameter(Mandatory)]
		[string] $SecondaryAvailabilityGroupIPAddress,
		
        [Parameter(Mandatory)]
        [string] $PrimarySQLNodeName,

		[Parameter(Mandatory=$true)]
		[string] $AvailabilityGroupName,
	
		[UInt32] $PublicPort = 1433,	
	
		[UInt32] $LoadBalancerProbePort = 59999,
                
        [parameter(Mandatory)]
        [PSCredential] $DomainAdministratorCredential,
		
		[parameter(Mandatory)]
        [PSCredential] $SqlAdministratorCredential
    )
	
	# Set-TargetResource is idempotent.. return false
    return $false
}


function Get-ImpersonatetLib
{
    if ($script:ImpersonateLib)
    {
        return $script:ImpersonateLib
    }

    $sig = @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword, int dwLogonType, int dwLogonProvider, ref IntPtr phToken);

[DllImport("kernel32.dll")]
public static extern Boolean CloseHandle(IntPtr hObject);
'@ 
   $script:ImpersonateLib = Add-Type -PassThru -Namespace 'Lib.Impersonation' -Name ImpersonationLib -MemberDefinition $sig 

   return $script:ImpersonateLib
    
}

function ImpersonateAs([PSCredential] $cred)
{
    [IntPtr] $userToken = [Security.Principal.WindowsIdentity]::GetCurrent().Token
    $userToken
    $ImpersonateLib = Get-ImpersonatetLib

    $bLogin = $ImpersonateLib::LogonUser($cred.GetNetworkCredential().UserName, $cred.GetNetworkCredential().Domain, $cred.GetNetworkCredential().Password, 
    9, 0, [ref]$userToken)
    
    if ($bLogin)
    {
        $Identity = New-Object Security.Principal.WindowsIdentity $userToken
        $context = $Identity.Impersonate()
    }
    else
    {
        throw "Can't Logon as User $cred.GetNetworkCredential().UserName."
    }
    $context, $userToken
}

function CloseUserToken([IntPtr] $token)
{
    $ImpersonateLib = Get-ImpersonatetLib

    $bLogin = $ImpersonateLib::CloseHandle($token)
    if (!$bLogin)
    {
        throw "Can't close token"
    }
}