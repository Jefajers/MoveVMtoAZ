# Parameters
param (
	[Parameter(Mandatory = $true)]
	$subscriptionId,
	[Parameter(Mandatory = $true)]
	$resourceGroup,
	[Parameter(Mandatory = $true)]
	$vmName,
	[Parameter(Mandatory = $true)]
	$location,
	[Parameter(Mandatory = $true)]
	[ValidateSet("1","2","3")]
	$zone,
	[switch]
	[Parameter(Mandatory = $false)]
	$execute,
	[Parameter(Mandatory = $true)]
	[System.IO.FileInfo]$logPath
)

# Create Timer
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

# Check Az
$access = Get-AzContext
if (-not $access) {
	Write-Error "No Azure Context Found"
	throw
}

# Select scope
Select-AzSubscription -Subscriptionid $subscriptionId

# Get the details of the VM to be converted
$originalVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName
if ($originalVM.Location -ne $location) {
	Write-Error "VM is not in stated target location:$location, instead its located in:$($originalVM.Location)"
	throw
}
if ($originalVM.Zones) {
	Write-Error "VM already in a Zone:$($originalVM.Id)"
	throw
}
if ($originalVM.NetworkProfile.NetworkInterfaces.DeleteOption -ne 'Detach') {
	Write-Error "VM NIC DeleteOption set to:$($originalVM.NetworkProfile.NetworkInterfaces.DeleteOption)"
	throw
}
if ($originalVM.StorageProfile.OsDisk.DeleteOption -ne 'Detach') {
	Write-Error "VM OS disk DeleteOption set to:$($originalVM.StorageProfile.OsDisk.DeleteOption)"
	throw
}
if ($originalVM.StorageProfile.DataDisks) {
	if ($originalVM.StorageProfile.DataDisks.DeleteOption -ne 'Detach') {
		Write-Error "VM Data disk DeleteOption set to:$($originalVM.StorageProfile.DataDisks.DeleteOption)"
		throw
	}
}

# Log VM details in file
if (-not (Test-Path $logpath)) {
	Write-Error "Cannot find log path:$logpath"
	throw
}
try {
    # Create File and input data
    $childPath = $originalVM.Name + '_' + $(Get-Date -f yyyy-MM-dd-HH-mm-ss) + '.json'
    $useLogPath = Join-Path -Path $logPath -ChildPath $childPath -ErrorAction Stop
    $originalVM | ConvertTo-Json -Depth 100 | Set-Content -Path $useLogPath -Force -ErrorAction Stop
}
catch {
    Write-Error "Log VM details to file, got error:$_)"
    throw
}

if ($execute) {
	try {
	    # Stop the VM to take snapshot
	    Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop
    }
    catch {
	    Write-Error "VM not stopped, got error:$_)"
	    throw
    }

    try {
	    # Create a SnapShot of the OS disk and then, create an Azure Disk in Zone
	    $snapshotOSConfig = New-AzSnapshotConfig -SourceUri $originalVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
	    $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $resourceGroup -ErrorAction Stop

	    $diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName Premium_LRS -Zone $zone -ErrorAction Stop
	    $OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName ($originalVM.StorageProfile.OsDisk.Name + "zone") -ErrorAction Stop

	    if ($originalVM.StorageProfile.DataDisks) {
		    # Create a Snapshot from the Data Disks and the Azure Disks with Zone information
		    foreach ($disk in $originalVM.StorageProfile.DataDisks) {
   			    $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
   			    $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup -ErrorAction Stop

   			    $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName Premium_LRS -Zone $zone -ErrorAction Stop
   			    $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone") -ErrorAction Stop
		    }
	    }
    }
    catch {
	    Write-Error "Issue with snapshot or disk operation, got error:$_)"
	    throw
    }

    try {
	    # Remove the original VM
	    Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force -ErrorAction Stop
    }
    catch {
	    Write-Error "Issue with removal of original VM object, got error:$_)"
	    throw
    }

    try {
	    # Create the basic configuration for the replacement VM
	    $newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize -Zone $zone -ErrorAction Stop

	    # Add the pre-existed OS disk 
	    Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows -ErrorAction Stop

	    # Add the pre-existed data disks
	    foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
    		    $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone") -ErrorAction Stop
    		    Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop
	    }
    }
    catch {
	    Write-Error "Issue with creation of new VM object, got error:$_)"
	    throw
    }

    try {
	    # Add NIC(s) and keep the same NIC as primary
	    foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {	
		    if ($nic.Primary -eq "True") {
      		    Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -Primary -ErrorAction Stop
   		    }
   		    else {
      	    Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -ErrorAction Stop
		    }
	    }
    }
    catch {
	    Write-Error "Issue with adding nic to new VM object, got error:$_)"
	    throw
    }

    # Recreate the VM
    New-AzVM -ResourceGroupName $resourceGroup -Location $originalVM.Location -VM $newVM -DisableBginfoExtension
}
$stopWatch.Stop()
Write-Host "Job for VM: $($originalVM.Name) took:$($stopWatch.Elapsed)"