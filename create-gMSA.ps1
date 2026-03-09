Import-Module ActiveDirectory

# 0) Prereqs / one-time checks (Domain Controller)
##################################################
Get-KdsRootKey
# If no output, create one:
# Add-KdsRootKey -EffectiveImmediately

# 1) Create / ensure the “allowed computers” group
##################################################
$GroupName = "GRP-SQL-gMSA-AllowedComputers"
$GroupPath = "CN=Users,DC=corp,DC=demolab,DC=com"  # <-- adjust to your OU/container
$GroupDescription = "Computers allowed to use sqlsvcgmsa$ gMSA for SQL services"

$group = Get-ADGroup -Identity $GroupName -ErrorAction SilentlyContinue
if (-not $group) {
    New-ADGroup -Name $GroupName `
        -SamAccountName $GroupName `
        -GroupScope Global `
        -GroupCategory Security `
        -Path $GroupPath `
        -Description $GroupDescription

    $group = Get-ADGroup -Identity $GroupName -ErrorAction Stop
} else {
    # Ensure description matches (safe, low-impact drift correction)
    if ($group.Description -ne $GroupDescription) {
        Set-ADGroup -Identity $GroupName -Description $GroupDescription
    }
}

# 2) Ensure AD computer accounts exist (create DISABLED if missing with CORP\djoin),
#    then ensure they are members of the allowed group
######################################################################################################
$CsvPath    = "\\fs01\VMMlibrary\Install-SQL.cr\ListOfSQLServers.csv"  # CSV with column 'ComputerName'
$TargetPath = "CN=Computers,DC=corp,DC=demolab,DC=com"                 # where to (pre)create accounts
$Creator    = "CORP\djoin"                                             # delegated account for creation

if (-not (Test-Path $CsvPath)) {
    throw "CSV not found at '$CsvPath'. Please verify the path."
}

# Prompt once for CORP\djoin creds (only if we actually need to create objects)
$creatorCred = $null

# Build desired computer SAMs from CSV → distinct ComputerName → sAMAccountName with trailing '$'
$desiredComputers =
    Import-Csv -Path $CsvPath |
    Select-Object -ExpandProperty ComputerName |
    Where-Object { $_ -and $_.Trim() -ne '' } |
    Sort-Object -Unique |
    ForEach-Object {
        [PSCustomObject]@{
            ComputerName   = $_
            SamAccountName = "$_`$"
        }
    }

# --- OPTIONAL INTERACTIVE STEP: Select which computer accounts you want to DISABLE ---
# Requires running in Windows PowerShell with Out-GridView available (e.g., on a management server/DC with RSAT/GUI).

if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {

    $selectedToDisable = $desiredComputers |
        Select-Object ComputerName, SamAccountName |
        Out-GridView -Title "Select computer accounts to DISABLE (multi-select) OK/Cancel" -PassThru

    if ($selectedToDisable) {
        foreach ($item in $selectedToDisable) {
            try {
                # Disable only if it exists; ignore if not found yet (creation may happen later in the script)
                $adComp = Get-ADComputer -LDAPFilter "(sAMAccountName=$($item.SamAccountName))" -ErrorAction SilentlyContinue
                if ($adComp) {
                    Disable-ADAccount -Identity $adComp.DistinguishedName -ErrorAction Stop
                    Write-Host "Disabled: $($item.ComputerName) [$($item.SamAccountName)]"
                } else {
                    Write-Warning "Not found in AD yet (will be created later if missing): $($item.ComputerName) [$($item.SamAccountName)]"
                }
            }
            catch {
                Write-Warning "Failed to disable $($item.ComputerName) [$($item.SamAccountName)] : $($_.Exception.Message)"
            }
        }
    } else {
        Write-Host "No accounts selected for disabling (skipping)."
    }

} else {
    Write-Warning "Out-GridView is not available in this session. Skipping interactive disable selection."
}

$created = @()
$skipped = @()

# Ensure each computer exists (create disabled if missing)
foreach ($c in $desiredComputers) {

    $existing = Get-ADComputer -LDAPFilter "(sAMAccountName=$($c.SamAccountName))" -ErrorAction SilentlyContinue
    if ($existing) { continue }

    if (-not $creatorCred) {
        $creatorCred = Get-Credential -Message "Enter credentials for $Creator" -UserName $Creator
    }

    try {
        $NewADComputerParams = @{
            Name           = $c.ComputerName
            SamAccountName = $c.SamAccountName
            Path           = $TargetPath
            Enabled        = $false          # create DISABLED
            Credential     = $creatorCred
        }
        New-ADComputer @NewADComputerParams

        $created += $c.ComputerName
    }
    catch {
        Write-Warning "Failed to create AD computer '$($c.ComputerName)' in '$TargetPath' : $($_.Exception.Message)"
        $skipped += $c.ComputerName
    }
}

# Ensure group membership is exactly "add missing" (idempotent)
$desiredSam = $desiredComputers.SamAccountName

$currentMembersSam =
    Get-ADGroupMember -Identity $GroupName -Recursive |
    Where-Object { $_.objectClass -eq 'computer' } |
    Select-Object -ExpandProperty SamAccountName

$missingMembers = $desiredSam | Where-Object { $_ -notin $currentMembersSam }

if ($missingMembers.Count -gt 0) {
    Add-ADGroupMember -Identity $GroupName -Members $missingMembers -ErrorAction Stop
    Write-Host "Added $($missingMembers.Count) missing computer(s) to group '$GroupName'."
} else {
    Write-Host "No missing computers to add to group '$GroupName'."
}

if ($created.Count) { Write-Host "`nCreated (disabled) accounts: $($created -join ', ')" }
if ($skipped.Count) { Write-Warning "Skipped (create failed): $($skipped -join ', ')" }

# 3) Create / ensure the gMSA: sqlsvcgmsa$
##########################################
Import-Module ActiveDirectory

$gMSAName      = "sqlsvcgmsa"
$DomainFqdn    = "corp.demolab.com"
$AllowedGroup  = "GRP-SQL-gMSA-AllowedComputers"
$DnsHostName   = "$gMSAName.$DomainFqdn"
$PwdInterval   = 30

$gmsa = Get-ADServiceAccount -Identity $gMSAName -ErrorAction SilentlyContinue

if (-not $gmsa) {
    # Create (ManagedPasswordIntervalInDays is supported here in your environment)
    New-ADServiceAccount -Name $gMSAName `
        -DNSHostName $DnsHostName `
        -PrincipalsAllowedToRetrieveManagedPassword $AllowedGroup `
        -ManagedPasswordIntervalInDays $PwdInterval `
        -Enabled $true
}
else {
    # Update only the properties we can safely set on all module versions
    Set-ADServiceAccount -Identity $gMSAName `
        -DNSHostName $DnsHostName `
        -PrincipalsAllowedToRetrieveManagedPassword $AllowedGroup

    # Ensure enabled
    $gmsaNow = Get-ADServiceAccount -Identity $gMSAName -Properties Enabled
    if (-not $gmsaNow.Enabled) {
        Enable-ADAccount -Identity $gMSAName
    }

    # NOTE: Do NOT set ManagedPasswordIntervalInDays here; your Set-ADServiceAccount doesn't support it.
}

# Verify the gMSA properties
Get-ADServiceAccount $gMSAName -Properties DNSHostName,Enabled,ManagedPasswordIntervalInDays,PrincipalsAllowedToRetrieveManagedPassword |
    Format-List DNSHostName,Enabled,ManagedPasswordIntervalInDays,PrincipalsAllowedToRetrieveManagedPassword
