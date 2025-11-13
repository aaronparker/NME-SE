<#
.SYNOPSIS
  Adds DestroyAfter tags to resource groups that don't have DoNotDestroy or DestroyAfter tags.
.DESCRIPTION
  This script finds all resource groups in the current Azure context that do not have 
  either "DoNotDestroy" or "DestroyAfter" tags, and adds a "DestroyAfter" tag with 
  a datetime value of one day ago in ISO 8601 format.
.PARAMETER WhatIf
  If specified, shows what would be done without making any changes.
.EXAMPLE
  .\Add-DestroyAfterTags.ps1
  .\Add-DestroyAfterTags.ps1 -WhatIf
#>

param(
    [Parameter(Mandatory=$false)]
    [switch] $WhatIf
)

# Calculate one day ago in UTC with the required format
$oneDayAgo = (Get-Date).AddDays(-1).ToUniversalTime()
$destroyAfterValue = $oneDayAgo.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

Write-Output "[INFO] Current UTC time: $((Get-Date).ToUniversalTime())"
Write-Output "[INFO] DestroyAfter tag value will be set to: $destroyAfterValue"

# Get current Azure context
$context = Get-AzContext
if (-not $context) {
    Write-Output "[ERROR] No Azure context found. Please run Connect-AzAccount first."
    exit 1
}

Write-Output "[INFO] Using subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"

# Get all resource groups
$resourceGroups = Get-AzResourceGroup
Write-Output "[INFO] Found $($resourceGroups.Count) resource groups total."

$processedCount = 0
$skippedCount = 0

foreach ($rg in $resourceGroups) {
    $rgName = $rg.ResourceGroupName
    $tags = $rg.Tags
    
    # Check if RG has DoNotDestroy tag
    $hasDoNotDestroy = $false
    if ($tags -and $tags.ContainsKey("DoNotDestroy")) {
        $hasDoNotDestroy = $true
    }
    
    # Check if RG has DestroyAfter tag
    $hasDestroyAfter = $false
    if ($tags -and $tags.ContainsKey("DestroyAfter")) {
        $hasDestroyAfter = $true
    }
    
    # Skip if either tag is present
    if ($hasDoNotDestroy) {
        Write-Output "[SKIP] RG '$rgName' has 'DoNotDestroy' tag - skipping."
        $skippedCount++
        continue
    }
    
    if ($hasDestroyAfter) {
        Write-Output "[SKIP] RG '$rgName' already has 'DestroyAfter' tag - skipping."
        $skippedCount++
        continue
    }
    
    # Add DestroyAfter tag
    if ($WhatIf) {
        Write-Output "[WHATIF] Would add 'DestroyAfter' tag to RG '$rgName' with value '$destroyAfterValue'"
    } else {
        try {
            # Get current tags or initialize empty hashtable
            $newTags = @{}
            if ($tags) {
                $newTags = $tags.Clone()
            }
            
            # Add the DestroyAfter tag
            $newTags["DestroyAfter"] = $destroyAfterValue
            
            # Update the resource group tags
            Set-AzResourceGroup -Name $rgName -Tag $newTags | Out-Null
            Write-Output "[SUCCESS] Added 'DestroyAfter' tag to RG '$rgName' with value '$destroyAfterValue'"
        }
        catch {
            Write-Output "[ERROR] Failed to add tag to RG '$rgName': $_"
            continue
        }
    }
    
    $processedCount++
}

Write-Output ""
Write-Output "[SUMMARY] Operation completed."
Write-Output "  Total resource groups: $($resourceGroups.Count)"
Write-Output "  Resource groups processed: $processedCount"
Write-Output "  Resource groups skipped: $skippedCount"
