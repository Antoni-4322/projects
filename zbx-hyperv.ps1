<#
    .SYNOPSIS
    Script for monitoring Hyper-V servers.

    .DESCRIPTION
    Provides LLD for Virtual Machines on the server and
    can retrieve JSON with found VMs parameters for dependent items.

    Works only with PowerShell 3.0 and above.
    
    .PARAMETER action
    What we want to do - make LLD or get full JSON with metrics.

    .PARAMETER version
    Print version number and exit.

    .EXAMPLE
    zbx-hyperv.ps1 lld
    {"data":[{"{#VM.NAME}":"vm01","{#VM.VERSION}":"5.0","{#VM.CLUSTERED}":0,"{#VM.HOST}":"hv01","{#VM.GEN}":2,"{#VM.ISREPLICA}":0,"{#VM.VCPUS}":2,"{#VM.MEMDEMAND}":1024,"{#VM.DISKSIZE}":10485760,"{#VM.USEDDISK}":5242880}]} 

    .EXAMPLE
    zbx-hyperv.ps1 full
    {"vm01":{"IntegrationServicesState":"","MemoryAssigned":0,"IntegrationServicesVersion":"","NumaSockets":1,"Uptime":0,"State":3,
    "NumaNodes":1,"CPUUsage":0,"Status":"Operating normally","ReplicationHealth":0,"ReplicationState":0,"VCPUs":2,"MemDemand":1024,"DiskSize":10485760,"UsedDisk":5242880}, ...}
    
    .NOTES
    Author: Khatsayuk Alexander
    Github: https://github.com/asand3r/
#>

Param (
    [switch]$version = $False,
    [Parameter(Position=0,Mandatory=$False)][string]$action
)

# Script version
$VERSION_NUM="0.2.8"
if ($version) {
    Write-Host $VERSION_NUM
    break
}

# Function to get disk size
function Get-DiskSize($vmName) {
    $vmHardDisks = Get-VMHardDiskDrive -VMName $vmName
    $totalDiskSize = 0

    foreach ($disk in $vmHardDisks) {
        if ($disk.Path -and (Test-Path $disk.Path)) {
            # Check if the file path is a VHD
            try {
                $vhd = Get-VHD -Path $disk.Path -ErrorAction Stop
                $totalDiskSize += $vhd.Size
            } catch {
                Write-Host "Failed to get size for virtual disk at path $($disk.Path) for VM $vmName. Error: $($_.Exception.Message)"
            }
        } else {
            # Handle physical disks or other types
            try {
                $diskId = (Get-VM -Name $vmName | Get-VMHardDiskDrive | Where-Object { $_.ControllerLocation -eq $disk.ControllerLocation }).DiskNumber
                if ($diskId -ne $null) {
                    $physicalDisk = Get-Disk -Number $diskId
                    $totalDiskSize += ($physicalDisk | Measure-Object -Property Size -Sum).Sum
                } else {
                    Write-Host "Could not determine disk number for VM $vmName. It may have a physical disk that is not accessible."
                }
            } catch {
                Write-Host "Failed to get size for physical disk associated with VM $vmName. Error: $($_.Exception.Message)"
            }
        }
    }
    return $totalDiskSize
}

# Function to get used disk size
function Get-UsedDiskSize($vmName) {
    $vmHardDisks = Get-VMHardDiskDrive -VMName $vmName
    $totalUsedDiskSize = 0

    foreach ($disk in $vmHardDisks) {
        if ($disk.Path -and (Test-Path $disk.Path)) {
            # Check if the file path is a VHD
            try {
                $vhd = Get-VHD -Path $disk.Path -ErrorAction Stop
                $totalUsedDiskSize += $vhd.FileSize
            } catch {
                Write-Host "Failed to get used size for virtual disk at path $($disk.Path) for VM $vmName. Error: $($_.Exception.Message)"
            }
        } else {
            # Handle physical disks or other types
            try {
                $diskId = (Get-VM -Name $vmName | Get-VMHardDiskDrive | Where-Object { $_.ControllerLocation -eq $disk.ControllerLocation }).DiskNumber
                if ($diskId -ne $null) {
                    $physicalDisk = Get-Partition -DiskNumber $diskId | Get-Volume | Measure-Object -Property SizeRemaining -Sum
                    $totalUsedDiskSize += ($physicalDisk.Sum)
                } else {
                    Write-Host "Could not determine disk number for VM $vmName. It may have a physical disk that is not accessible."
                }
            } catch {
                Write-Host "Failed to get used size for physical disk associated with VM $vmName. Error: $($_.Exception.Message)"
            }
        }
    }
    return $totalUsedDiskSize
}



# Low-Level Discovery function
function Make-LLD() {
    $vms = Get-VM | Select-Object @{Name = "{#VM.NAME}"; e={$_.VMName}},
                                  @{Name = "{#VM.VERSION}"; e={$_.Version}},
                                  @{Name = "{#VM.CLUSTERED}"; e={[int]$_.IsClustered}},
                                  @{Name = "{#VM.HOST}"; e={$_.ComputerName}},
                                  @{Name = "{#VM.GEN}"; e={$_.Generation}},
                                  @{Name = "{#VM.ISREPLICA}"; e={[int]$_.ReplicationMode}},
                                  @{Name = "{#VM.NOTES}"; e={$_.Notes}},
                                  @{Name = "{#VM.VCPUS}"; e={$_.ProcessorCount}},
                                  @{Name = "{#VM.MEMDEMAND}"; e={$_.MemoryDemand}},
                                  @{Name = "{#VM.DISKSIZE}"; e={Get-DiskSize $_.VMName}},
                                  @{Name = "{#VM.USEDDISK}"; e={Get-UsedDiskSize $_.VMName}},
                                  @{Name = "{#VM.IP}"; e={ Get-VMNetworkAdapter -VMName $_.VMName |Where-Object { $_.Status -ne "LostCommunication" } | Select-Object -ExpandProperty IPAddresses |Where-Object { $_ -match '\d{1,3}(\.\d{1,3}){3}' }}},
                                  @{Name = "{#HYPERV.NAME}"; e={ hostname }}
                               
    return ConvertTo-Json @{"data" = [array]$vms} -Compress
}

# JSON for dependent items
function Get-FullJSON() {
    $to_json = @{}
    
    # Because of IntegrationServicesState is string, I've made a dict to map it to int (better for Zabbix):
    # 0 - Up to date
    # 1 - Update required
    # 2 - unknown state
    $integrationSvcState = @{
        "Up to date" = 0;
        "Update required" = 1;
        "" = 2
    }

    Get-VM | ForEach-Object {
        $vm_data = [psobject]@{"State" = [int]$_.State;
                               "Uptime" = [math]::Round($_.Uptime.TotalSeconds);
                               "NumaNodes" = $_.NumaNodesCount;
                               "NumaSockets" = $_.NumaSocketCount;
                               "IntSvcVer" = [string]$_.IntegrationServicesVersion;
                               "IntSvcState" = $integrationSvcState[$_.IntegrationServicesState];
                               "CPUUsage" = $_.CPUUsage;
                               "Memory" = $_.MemoryAssigned;
                               "ReplMode" = [int]$_.ReplicationMode;
                               "ReplState" = [int]$_.ReplicationState;
                               "ReplHealth" = [int]$_.ReplicationHealth;
                               "StopAction" = [int]$_.AutomaticStopAction;
                               "StartAction" = [int]$_.AutomaticStartAction;
                               "CritErrAction" = [int]$_.AutomaticCriticalErrorAction;
                               "IsClustered" = [int]$_.IsClustered;
                               "VCPUs" = $_.ProcessorCount;
                               "MemDemand" = $_.MemoryDemand;
                               "DiskSize" = Get-DiskSize $_.VMName;
                               "UsedDisk" = Get-UsedDiskSize $_.VMName
                               }
        $to_json += @{$_.VMName = $vm_data}
    }
    return ConvertTo-Json $to_json -Compress
}

# Main switch
switch ($action) {
    "lld" {
        Write-Host $(Make-LLD)
    }
    "full" {
        Write-Host $(Get-FullJSON)
    }
    Default {Write-Host "Syntax error: Use 'lld' or 'full' as first argument"}
}
