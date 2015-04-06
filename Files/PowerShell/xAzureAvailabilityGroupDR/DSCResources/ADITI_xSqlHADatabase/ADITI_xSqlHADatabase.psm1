#
# xSqlHADatabase: DSC resource to add database to a Sql High Availability (HA) Group.
#

#
# The Get-TargetResource cmdlet.
#
function Get-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNull()]
	    [string] $Database,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,

        [parameter(Mandatory)]
        [ValidateRange(2,5)]
        [Uint32] $NumberOfPrimaryDatacenterSQLNodes,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PrimaryDatacenterSQLNodeNamePrefix,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential	
  	)

    if ($Database.Count -lt 1)
    {
        throw "Parameter Database does not have any database"
    }    

    $returnValue = @{
 
        Database = $Database
        AvailabilityGroupName = $AvailabilityGroupName
        DatabaseBackupPath = $DatabaseBackupPath        
        SqlAdministratorCredential = $SqlAdministratorCredential.UserName
	}

	$returnValue
}

#
# The Set-TargetResource cmdlet.
#
function Set-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNull()]
	    [string] $Database,        

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,

        [parameter(Mandatory)]
        [ValidateRange(2,5)]
        [Uint32] $NumberOfPrimaryDatacenterSQLNodes,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PrimaryDatacenterSQLNodeNamePrefix,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential	
  	)
   
    if ($Database.Count -lt 1)
    {
        throw "Parameter Database does not have any database"
    }    

    $sa = $SqlAdministratorCredential.UserName
    $saPassword = $SqlAdministratorCredential.GetNetworkCredential().Password
    
    # restore database
    for($index = 1; $index -le $NumberOfPrimaryDatacenterSQLNodes; $index++)
    {
        $dbServer = $PrimaryDatacenterSQLNodeNamePrefix + $index
        ConfigureDatabaseWithAG -DbServer $dbServer -Database $Database -sa $sa -saPassword $saPassword `
                                -DatabaseBackupPath $DatabaseBackupPath -AvailabilityGroupName $AvailabilityGroupName
    }
    ConfigureDatabaseWithAG -DbServer '.' -Database $Database -sa $sa -saPassword $saPassword `
                                -DatabaseBackupPath $DatabaseBackupPath -AvailabilityGroupName $AvailabilityGroupName
}

#
# The Test-TargetResource cmdlet.
#
function Test-TargetResource
{
	param
	(	
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AvailabilityGroupName,

        [parameter(Mandatory)]
        [ValidateNotNull()]
	    [string] $Database,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
	    [string] $DatabaseBackupPath,

        [parameter(Mandatory)]
        [ValidateRange(2,5)]
        [Uint32] $NumberOfPrimaryDatacenterSQLNodes,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PrimaryDatacenterSQLNodeNamePrefix,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [PSCredential] $SqlAdministratorCredential	
  	)

    # Set-TargetResource is idempotent
    return $false
}

function ConfigureDatabaseWithAG
{
    param
    (
        [string] $DbServer,
        [string] $Database,
        [string] $sa,
        [string] $saPassword,
        [string] $DatabaseBackupPath,
        [string] $AvailabilityGroupName
    )
    
    $role = [int] (osql -S $DbServer -U $sa -P $saPassword -Q "select role from sys.dm_hadr_availability_replica_states where is_local = 1" -h-1)[0]
    $dbExists = [bool] [int](osql -S $DbServer -U $sa -P $saPassword -Q "select count(*) from master.sys.databases where name = '$Database'" -h-1)[0]
    $dbIsAddedToAg = [bool] [int](osql -S $DbServer -U $sa -P $saPassword -Q "select count(*) from sys.dm_hadr_database_replica_states inner join sys.databases on sys.databases.database_id = sys.dm_hadr_database_replica_states.database_id where sys.databases.name = '$Database'" -h-1)[0]

    if($role -eq 1) # If PRIMARY replica
    {            
        if(!$dbExists)
        {
            # create DB
            osql -S $DbServer -U $sa -P $saPassword -Q "create database $Database"
        }
        # take backup
        Write-Verbose -Message "Backup to $DatabaseBackupPath .."
        osql -S $DbServer -U $sa -P $saPassword -Q "backup database $Database to disk = '$DatabaseBackupPath\$Database.bak' with format"
        osql -S $DbServer -U $sa -P $saPassword -Q "backup log $Database to disk = '$DatabaseBackupPath\$Database.log' with noformat"

        if(!$dbIsAddedToAg)
        {
           osql -S $DbServer -U $sa -P $saPassword -Q "ALTER AVAILABILITY GROUP $AvailabilityGroupName ADD DATABASE $Database"                
        }
    }

    elseif($role -eq 2 -or $role -eq 0 ) # If SECONDARY replica or yet to be added as a replica
    {
        $isJoinedToAg = [bool] [int](osql -S $DbServer -U $sa -P $saPassword -Q "select count(*) from sys.availability_groups where name = '$AvailabilityGroupName'" -h-1)[0]
        if(!$isJoinedToAg)
        {
            # Join AG
            osql -S $DbServer -U $sa -P $saPassword -Q "ALTER AVAILABILITY GROUP $AvailabilityGroupName JOIN"
        }

        # Restore DB if not exists
        if(!$dbExists)
        {
            WaitForDatabase -DbName $Database -DbBackupFolder $DatabaseBackupPath

            $query = "restore database $Database from disk = '$DatabaseBackupPath\$Database.bak' with norecovery"
            Write-Verbose -Message "Query: $query"
            osql -S $DbServer -U $sa -P $saPassword -Q $query        

            $query = "restore log $Database from disk = '$DatabaseBackupPath\$Database.log' with norecovery"
            Write-Verbose -Message "Query: $query"
	        osql -S $DbServer -U $sa -P $saPassword -Q $query                
        }
                        
        if(!$dbIsAddedToAg)
        {
            # Add database to AG
	        osql -S $DbServer -U $sa -P $saPassword -Q "ALTER DATABASE $Database SET HADR AVAILABILITY GROUP = $AvailabilityGroupName"
        }
    }
}


function WaitForDatabase
{
    param
    (
        [string] $DbBackupFolder,
        [UInt64] $RetryIntervalSec = 60,
        [UInt32] $RetryCount = 10,
        [string] $DbName
    )
    $dbFound = $false
    for ($count = 0; $count -lt $RetryCount; $count++)
    {
        if((Test-Path $DbBackupFolder\$DbName.bak) -and (Test-Path $DbBackupFolder\$DbName.log))
        {
            $dbFound = $true
            break;
        }
        else
        {
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
    if (!$dbFound)
    {
        throw "Database $DbName in backup folder $DbBackupFolder not found afater $RetryCount attempt with $RetryIntervalSec sec interval"
    }
} 

Export-ModuleMember -Function *-TargetResource