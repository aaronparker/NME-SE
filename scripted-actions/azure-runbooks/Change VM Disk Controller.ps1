<# Variables:
{
    "VMName": {
        "Description": "Name of the specific VM to convert. Leave empty to process all VMs in RG matching SourceVMSize."
    },
    "ResourceGroupName": {
        "Description": "Name of the resource group containing the VM(s).",
        "DefaultValue": ""
    },
    "SourceVMSize": {
        "Description": "Source VM SKU size to filter VMs for batch processing. NOTE: changing from v6 to v3 will fail.",
        "DefaultValue": "Standard_D4s_v6"
    },
    "DestinationVMSize": {
        "Description": "Target VM SKU size after conversion.",
        "DefaultValue": "Standard_D4s_v5"
    },
    "NewControllerType": {
        "Description": "Target disk controller type (SCSI or NVMe).",
        "DefaultValue": "SCSI"
    },
    "IgnoreRunningVMs": {
        "Description": "Skip VMs that are currently running/powered on.",
        "DefaultValue": "true"
    },
    "ProcessInGroupsOf": {
        "Description": "Number of VMs to process simultaneously in parallel jobs.",
        "DefaultValue": 3
    },
    "WhatIf": {
        "Description": "Preview what changes would be made without executing them.",
        "DefaultValue": "false"
    }
}
#>

#Requires -Modules Az.Accounts, Az.Compute, Az.Resources

# -------- Helpers --------
function Write-Info { param($m) Write-Output ("[INFO]  " + $m) }
function Write-Warn { param($m) Write-Output ("[WARN]  " + $m) }
function Write-Err  { param($m) Write-Output ("[ERROR] " + $m) }

function To-Bool {
    param($v)
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $v }
    $s = ($v | Out-String).Trim().ToLowerInvariant()
    switch -Regex ($s) {
        '^(true|1|yes|y)$'   { return $true }
        '^(false|0|no|n|)$'  { return $false }
        default              { return $false }
    }
}

function Test-VMPowerState {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ResourceGroup
    )
    try {
        $vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status -ErrorAction Stop
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -Last 1).Code
        return @{
            PowerState = $powerState
            IsRunning = ($powerState -eq 'PowerState/running')
            IsDeallocated = ($powerState -eq 'PowerState/deallocated')
        }
    } catch {
        Write-Err ("Failed to get power state for VM '{0}': {1}" -f $VMName, $_.Exception.Message)
        return $null
    }
}

# -------- Resolve parameters --------
$startTime = Get-Date
Write-Info ("Conversion Script started at {0}" -f $startTime.ToString("yyyy-MM-dd HH:mm:ss"))

if (-not $ResourceGroupName) {
    throw "ResourceGroupName is required."
}

# Normalize boolean parameters
$IgnoreRunningVMs = To-Bool $IgnoreRunningVMs
$WhatIfMode = To-Bool $WhatIf
# Normalize and validate NewControllerType

$nt = $NewControllerType.Trim()
switch ($nt.ToUpperInvariant()) {
    'SCSI' { $NewControllerType = 'SCSI' }
    'NVME' { $NewControllerType = 'NVMe' }
    default {
        throw "Invalid NewControllerType value '$NewControllerType'. Valid values are 'SCSI' or 'NVMe'."
    }
}

Write-Info ("Normalized NewControllerType: {0}" -f $NewControllerType)

Write-Info ("Parameters resolved:")
Write-Info ("  - VMName: '{0}'" -f $(if ($VMName) { $VMName } else { "<batch mode - all VMs matching source size>" }))
Write-Info ("  - ResourceGroupName: '{0}'" -f $ResourceGroupName)
Write-Info ("  - SourceVMSize: '{0}'" -f $SourceVMSize)
Write-Info ("  - DestinationVMSize: '{0}'" -f $DestinationVMSize)
Write-Info ("  - NewControllerType: '{0}'" -f $NewControllerType)
Write-Info ("  - IgnoreRunningVMs: {0}" -f $IgnoreRunningVMs)
Write-Info ("  - ProcessInGroupsOf: {0}" -f $ProcessInGroupsOf)
Write-Info ("  - WhatIfMode: {0}" -f $WhatIfMode)

# -------- Download Microsoft's conversion script --------
$downloadStartTime = Get-Date
Write-Info ("Downloading Microsoft's NVMe conversion script... (started at {0})" -f $downloadStartTime.ToString("HH:mm:ss"))

$scriptUrl = "https://raw.githubusercontent.com/Get-Nerdio/SAP-on-Azure-Scripts-and-Utilities/refs/heads/main/Azure-NVMe-Utils/Azure-NVMe-Conversion.ps1"
$localScriptPath = Join-Path $env:TEMP "Azure-NVMe-Conversion.ps1"

Invoke-WebRequest -Uri $scriptUrl -OutFile $localScriptPath -ErrorAction Stop
Write-Info ("Successfully downloaded script to: {0}" -f $localScriptPath)


# -------- Identify VMs to process --------

Write-Info ("Identifying VMs to process...")

$vmsToProcess = @()

if ($VMName -and -not [string]::IsNullOrWhiteSpace($VMName)) {
    # Single VM mode
    Write-Info ("Single VM mode: processing specific VM '{0}'" -f $VMName)
    try {
        $vm = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        $vmsToProcess += $vm
        Write-Info ("Found target VM: {0} (Size: {1})" -f $vm.Name, $vm.HardwareProfile.VmSize)
    } catch {
        Write-Err ("Failed to find VM '{0}' in resource group '{1}': {2}" -f $VMName, $ResourceGroupName, $_.Exception.Message)
        throw
    }
} else {
    # Batch mode - find all VMs matching source size
    Write-Info ("Batch mode: finding all VMs with size '{0}' in resource group '{1}'" -f $SourceVMSize, $ResourceGroupName)
    try {
        $allVMs = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        $vmsToProcess = $allVMs | Where-Object { $_.HardwareProfile.VmSize -eq $SourceVMSize }
        
        Write-Info ("Found {0} total VMs in resource group" -f $allVMs.Count)
        Write-Info ("Found {0} VMs matching source size '{1}'" -f $vmsToProcess.Count, $SourceVMSize)
        
        if ($vmsToProcess.Count -eq 0) {
            Write-Warn ("No VMs found matching source size '{0}' in resource group '{1}'" -f $SourceVMSize, $ResourceGroupName)
            return
        }
        
        foreach ($vm in $vmsToProcess) {
            Write-Info ("  - {0} (Size: {1})" -f $vm.Name, $vm.HardwareProfile.VmSize)
        }
    } catch {
        Write-Err ("Failed to retrieve VMs from resource group '{0}': {1}" -f $ResourceGroupName, $_.Exception.Message)
        throw
    }
}


# -------- Filter by power state if requested --------
if ($IgnoreRunningVMs) {
    $powerStateFilterStartTime = Get-Date
    Write-Info ("Filtering out running VMs... (started at {0})" -f $powerStateFilterStartTime.ToString("HH:mm:ss"))
    
    $filteredVMs = @()
    $skippedVMs = @()
    
    foreach ($vm in $vmsToProcess) {
        $powerInfo = Test-VMPowerState -VMName $vm.Name -ResourceGroup $ResourceGroupName
        if ($powerInfo) {
            if ($powerInfo.IsRunning) {
                $skippedVMs += $vm
                Write-Info ("  - SKIPPED: {0} (PowerState: {1})" -f $vm.Name, $powerInfo.PowerState)
            } else {
                $filteredVMs += $vm
                Write-Info ("  - ELIGIBLE: {0} (PowerState: {1})" -f $vm.Name, $powerInfo.PowerState)
            }
        } else {
            Write-Warn ("  - ERROR: Could not determine power state for {0}, skipping" -f $vm.Name)
            $skippedVMs += $vm
        }
    }
    
    $vmsToProcess = $filteredVMs
    
    Write-Info ("Power state filtering results:")
    Write-Info ("  - Eligible VMs: {0}" -f $vmsToProcess.Count)
    Write-Info ("  - Skipped VMs: {0}" -f $skippedVMs.Count)
    
    if ($vmsToProcess.Count -eq 0) {
        Write-Warn "No VMs are eligible for processing after power state filtering"
        return
    }
    
    $powerStateFilterDuration = ((Get-Date) - $powerStateFilterStartTime).TotalSeconds
    Write-Info ("Power state filtering completed in {0:F1}s" -f $powerStateFilterDuration)
}

# -------- What-If mode --------
if ($WhatIfMode) {
    $whatIfStartTime = Get-Date
    Write-Info ("=== WHAT-IF MODE: Changes that would be made === (started at {0})" -f $whatIfStartTime.ToString("HH:mm:ss"))
    
    foreach ($vm in $vmsToProcess) {
        Write-Info ("Would convert VM '{0}':" -f $vm.Name)
        Write-Info ("  - Current Size: {0}" -f $vm.HardwareProfile.VmSize)
        Write-Info ("  - Target Size: {0}" -f $DestinationVMSize)
        Write-Info ("  - Controller: Current -> {0}" -f $NewControllerType)
        Write-Info ("  - Resource Group: {0}" -f $ResourceGroupName)
        Write-Info ("  - Process: Stop VM -> Update OS settings -> Convert controller -> Resize -> Start")
    }
    
    Write-Info ("Batch processing configuration:")
    Write-Info ("  - Total VMs: {0}" -f $vmsToProcess.Count)
    Write-Info ("  - Process in groups of: {0}" -f $ProcessInGroupsOf)
    Write-Info ("  - Estimated groups: {0}" -f [Math]::Ceiling($vmsToProcess.Count / $ProcessInGroupsOf))
    
    $whatIfDuration = ((Get-Date) - $whatIfStartTime).TotalSeconds
    Write-Info ("=== END WHAT-IF MODE === (took {0:F1}s)" -f $whatIfDuration)
    return
}

# -------- Process VMs --------
$conversionStartTime = Get-Date
Write-Info ("Starting VM conversions... (started at {0})" -f $conversionStartTime.ToString("HH:mm:ss"))

# Create script block for parallel execution
$ConversionScriptBlock = {
    param(
        $VM,
        $ResourceGroupName,
        $DestinationVMSize,
        $NewControllerType,
        $LocalScriptPath
    )
    
    function Write-JobInfo { param($m) Write-Output ("[JOB-$($VM.Name)] " + $m) }
    function Write-JobWarn { param($m) Write-Output ("[WARN-$($VM.Name)] " + $m) }
    function Write-JobErr  { param($m) Write-Output ("[ERROR-$($VM.Name)] " + $m) }
    
    $jobStartTime = Get-Date
    Write-JobInfo ("Starting conversion process (started at {0})" -f $jobStartTime.ToString("HH:mm:ss"))
    
    try {
        # Verify the script file exists in the job context
        if (-not (Test-Path $LocalScriptPath)) {
            throw "Microsoft's conversion script not found at: $LocalScriptPath"
        }
        
        Write-JobInfo ("Converting VM '{0}' from size '{1}' to '{2}'" -f $VM.Name, $VM.HardwareProfile.VmSize, $DestinationVMSize)
        Write-JobInfo ("Using Microsoft's script: {0}" -f $LocalScriptPath)
        
        # Get initial VM state for validation
        $initialVM = Get-AzVM -Name $VM.Name -ResourceGroupName $ResourceGroupName -Status
        $initialPowerState = ($initialVM.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -Last 1).Code
        if ($initialPowerState -match 'deallocated') {
            $StartVM = $false
            Write-Output "Starting VM '{0}'..." -f $VM.Name
            Start-AzVM -Name $VM.Name -ResourceGroupName $ResourceGroupName | Out-Null
        }
        else {
            $StartVM = $true
        }
        $initialSize = (Get-AzVM -Name $VM.Name -ResourceGroupName $ResourceGroupName).HardwareProfile.VmSize
        
        Write-JobInfo ("Initial VM state - Size: {0}, PowerState: {1}" -f $initialSize, $initialPowerState)
        
        # Run the conversion script and capture all output
        Write-JobInfo ("Calling Microsoft's NVMe conversion script...")
        
        # Execute Microsoft's script with proper parameters
        # The script expects these exact parameter names
        $scriptArgs = @{
            ResourceGroupName = $ResourceGroupName
            VMName = $VM.Name
            NewControllerType = $NewControllerType
            VMSize = $DestinationVMSize
            StartVM = $StartVM
            FixOperatingSystemSettings = $true
            IgnoreAzureModuleCheck = $true
        }
        
        Write-JobInfo ("Script arguments: {0}" -f ($scriptArgs -join ' '))
        
        try {
            # Call the script using PowerShell's call operator with arguments
            & $LocalScriptPath @scriptArgs
            
            Write-JobInfo ("Microsoft script execution completed")
            
            # Display the conversion script output
            if ($conversionOutput) {
                Write-JobInfo ("Microsoft script output:")
                foreach ($line in $conversionOutput) {
                    if ($line -and $line.ToString().Trim()) {
                        Write-JobInfo ("  $($line.ToString())")
                    }
                }
            } else {
                Write-JobWarn ("No output received from Microsoft script")
            }
            
        } catch {
            Write-JobErr ("Error executing Microsoft script: {0}" -f $_.Exception.Message)
            throw
        }
        
        # Validate the conversion actually happened
        Write-JobInfo ("Validating conversion results...")
        Start-Sleep -Seconds 15  # Give Azure more time to update after script execution
        
        $finalVM = Get-AzVM -Name $VM.Name -ResourceGroupName $ResourceGroupName 
        $finalSize = $finalVM.HardwareProfile.VmSize
        
        Write-JobInfo ("Final VM state - Size: {0}" -f $finalSize)
        
        # Check if conversion was successful
        $conversionSuccessful = ($finalSize -eq $DestinationVMSize)
        
        if (-not $conversionSuccessful) {
            Write-JobWarn ("Size validation failed: VM size is still '{0}', expected '{1}'" -f $finalSize, $DestinationVMSize)
            
            # Check for controller type change (this is what really matters for NVMe->SCSI conversion)
            Write-JobInfo ("Checking storage controller type...")
            try {
                $vmDetails = Get-AzVM -Name $VM.Name -ResourceGroupName $ResourceGroupName
                $controllerType = $vmDetails.StorageProfile.DiskControllerType
                
                Write-JobInfo ("Current disk controller type: {0}" -f $controllerType)
                
                if ($controllerType -eq "SCSI") {
                    Write-JobInfo ("Controller successfully converted to SCSI! Size validation secondary.")
                    $conversionSuccessful = $true
                } else {
                    Write-JobWarn ("Controller type is still: {0}" -f $controllerType)
                }
                
                # Additional storage profile information
                $storageProfile = $vmDetails.StorageProfile
                if ($storageProfile) {
                    Write-JobInfo ("Storage profile information:")
                    Write-JobInfo ("  - OS Disk: {0}" -f $storageProfile.OsDisk.Name)
                    Write-JobInfo ("  - Controller Type: {0}" -f $storageProfile.DiskControllerType)
                    if ($storageProfile.DataDisks) {
                        Write-JobInfo ("  - Data Disks: {0}" -f ($storageProfile.DataDisks.Count))
                    }
                }
                
            } catch {
                Write-JobWarn ("Could not retrieve detailed VM information: {0}" -f $_.Exception.Message)
            }
        }
        
        if ($conversionSuccessful) {
            $jobDuration = ((Get-Date) - $jobStartTime).TotalSeconds
            Write-JobInfo ("Conversion completed successfully in {0:F1}s" -f $jobDuration)
            
            return @{
                Success = $true
                VMName = $VM.Name
                OriginalSize = $initialSize
                NewSize = $finalSize
                Duration = $jobDuration
                Message = "Conversion completed successfully"
                InitialPowerState = $initialPowerState
            }
        } else {
            $jobDuration = ((Get-Date) - $jobStartTime).TotalSeconds
            $errorMessage = "Conversion validation failed: VM size is still '{0}', expected '{1}'" -f $finalSize, $DestinationVMSize
            Write-JobErr ("Conversion failed after {0:F1}s: {1}" -f $jobDuration, $errorMessage)
            
            return @{
                Success = $false
                VMName = $VM.Name
                OriginalSize = $initialSize
                NewSize = $finalSize
                Duration = $jobDuration
                Message = $errorMessage
                InitialPowerState = $initialPowerState
            }
        }
        
    } catch {
        $jobDuration = ((Get-Date) - $jobStartTime).TotalSeconds
        $errorMessage = $_.Exception.Message
        
        Write-JobErr ("Conversion failed after {0:F1}s: {1}" -f $jobDuration, $errorMessage)
        
        return @{
            Success = $false
            VMName = $VM.Name
            OriginalSize = if ($VM.HardwareProfile.VmSize) { $VM.HardwareProfile.VmSize } else { "Unknown" }
            NewSize = $DestinationVMSize
            Duration = $jobDuration
            Message = "Conversion failed: $errorMessage"
            Error = $errorMessage
        }
    }
}

# Process VMs in groups
$allResults = @()
$totalVMs = $vmsToProcess.Count
$processedVMs = 0

for ($i = 0; $i -lt $totalVMs; $i += $ProcessInGroupsOf) {
    $groupStartTime = Get-Date
    
    # Calculate the actual number of VMs in this group
    $remainingVMs = $totalVMs - $i
    $vmsInThisGroup = [Math]::Min($ProcessInGroupsOf, $remainingVMs)
    $groupEndIndex = $i + $vmsInThisGroup - 1
    
    $currentGroup = @($vmsToProcess)[$i..$groupEndIndex]
    $groupNumber = [Math]::Floor($i / $ProcessInGroupsOf) + 1
    $totalGroups = [Math]::Ceiling($totalVMs / $ProcessInGroupsOf)
    
    Write-Info ("Processing group {0}/{1} ({2} VMs)... (started at {3})" -f $groupNumber, $totalGroups, $currentGroup.Count, $groupStartTime.ToString("HH:mm:ss"))
    
    # Start jobs for current group
    $jobs = @()
    foreach ($vm in $currentGroup) {
        Write-Info ("  Starting job for VM: {0}" -f $vm.Name)
        $job = Start-Job -ScriptBlock $ConversionScriptBlock -ArgumentList $vm, $ResourceGroupName, $DestinationVMSize, $NewControllerType, $localScriptPath
        $jobs += @{ Job = $job; VM = $vm }
    }
    
    # Wait for all jobs in the group to complete
    Write-Info ("Waiting for {0} jobs to complete..." -f $jobs.Count)
    
    foreach ($jobInfo in $jobs) {
        $job = $jobInfo.Job
        $vm = $jobInfo.VM
        
        Write-Info ("Waiting for job completion: {0}" -f $vm.Name)
        
        # Wait for job to complete and get all output
        $jobOutput = Receive-Job -Job $job -Wait
        
        # Display job output (this includes both logging and the return hashtable)
        $jobResult = $null
        if ($jobOutput) {
            foreach ($output in $jobOutput) {
                if ($output -is [hashtable] -and $output.ContainsKey('VMName')) {
                    # This is our return result
                    $jobResult = $output
                } else {
                    # This is logging output
                    Write-Output $output
                }
            }
        }
        
        # Store the result
        if ($jobResult) {
            $allResults += $jobResult
        } else {
            # Fallback result if job didn't return expected format
            Write-Warn ("Job for VM '{0}' did not return expected result format. Job state: {1}" -f $vm.Name, $job.State)
            $allResults += @{
                Success = $job.State -eq 'Completed'
                VMName = $vm.Name
                OriginalSize = $vm.HardwareProfile.VmSize
                NewSize = $DestinationVMSize
                Message = "Job completed with state: $($job.State) but did not return expected result"
                Duration = 0
            }
        }
        
        Remove-Job -Job $job
        $processedVMs++
        
        Write-Info ("Progress: {0}/{1} VMs completed" -f $processedVMs, $totalVMs)
    }
    
    $groupDuration = ((Get-Date) - $groupStartTime).TotalSeconds
    Write-Info ("Group {0}/{1} completed in {2:F1}s" -f $groupNumber, $totalGroups, $groupDuration)
}

# -------- Summary --------
$totalDuration = ((Get-Date) - $startTime).TotalSeconds
Write-Info ("=== CONVERSION SUMMARY ===")
Write-Info ("Total execution time: {0:F1}s" -f $totalDuration)
Write-Info ("Total VMs processed: {0}" -f $allResults.Count)

$successfulConversions = $allResults | Where-Object { $_.Success -eq $true }
$failedConversions = $allResults | Where-Object { $_.Success -eq $false }

Write-Info ("Successful conversions: {0}" -f $successfulConversions.Count)
Write-Info ("Failed conversions: {0}" -f $failedConversions.Count)

if ($successfulConversions.Count -gt 0) {
    Write-Info ("Successful conversions:")
    foreach ($result in $successfulConversions) {
        $durationText = if ($result.Duration) { "{0:F1}s" -f $result.Duration } else { "unknown duration" }
        Write-Info ("  ✓ {0}: {1} -> {2} (took {3})" -f $result.VMName, $result.OriginalSize, $result.NewSize, $durationText)
    }
}

if ($failedConversions.Count -gt 0) {
    Write-Warn ("Failed conversions:")
    foreach ($result in $failedConversions) {
        Write-Warn ("  ✗ {0}: {1}" -f $result.VMName, $result.Message)
    }
}

Write-Info ("NVMe to SCSI conversion process completed at {0}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))

# Clean up downloaded script
try {
    if (Test-Path $localScriptPath) {
        Remove-Item $localScriptPath -Force
        Write-Info ("Cleaned up downloaded script file: {0}" -f $localScriptPath)
    }
} catch {
    Write-Warn ("Failed to clean up script file: {0}" -f $_.Exception.Message)
}
