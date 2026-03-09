Clear

# =======================
# INPUTS
# =======================
$CsvPath       = "\\fs01.corp.demolab.com\VMMlibrary\Install-SQL.cr\ListOfSQLServers.csv"
$DnsSuffix     = "corp.demolab.com"
$TemplateName  = "WS2025-SQL-AllwaysOn"
$HostGroupName = "All Hosts"

# Tier names as they exist in the Service Template
$TierNameA = "Site A"
$TierNameB = "Site B"

# =======================
# LOAD CSV + PICK CLUSTER (WSFC_Name) USING OUT-GRIDVIEW
# =======================
$rows = Import-Csv -Path $CsvPath

# Build a unique list of clusters for selection
# $clusterPick = $rows |
#     Where-Object { $_.WSFC_Name } |
#     Select-Object WSFC_Name, WSFC_IP, PrimarySQLName, SecondarySQLName, AG_Name, ListenerName |
#     Sort-Object WSFC_Name -Unique |
#     Out-GridView -Title "Select WSFC_Name (SQL Cluster) to deploy" -PassThru

$clusterPick = $rows |
    Where-Object { $_.WSFC_Name } |
    Sort-Object WSFC_Name -Unique |
    Out-GridView -Title "Select WSFC_Name (SQL Cluster) to deploy" -PassThru


if (-not $clusterPick) { throw "No cluster selected. Cancelled." }

$ServiceName = $clusterPick.WSFC_Name

# =======================
# COMPUTE DESIRED VM/COMPUTER NAMES
# =======================
$fqdnA = "$ServiceName-A.$DnsSuffix"
$fqdnB = "$ServiceName-B.$DnsSuffix"

# =======================
# CREATE SERVICE CONFIG (same as GUI: name + destination)
# =======================
$tmpl      = Get-SCServiceTemplate -Name $TemplateName | Where-Object { $PSItem.Release -eq "1.2" }
$hostGroup = Get-SCVMHostGroup -Name $HostGroupName

$svcCfg = New-SCServiceConfiguration -Name $ServiceName -ServiceTemplate $tmpl -VMHostGroup $hostGroup

# =======================
# SET VM NAME + COMPUTER NAME FOR EACH TIER INSTANCE
# =======================
$tierA = $svcCfg.ComputerTierConfigurations | Where-Object Name -eq $TierNameA
$tierB = $svcCfg.ComputerTierConfigurations | Where-Object Name -eq $TierNameB

if (-not $tierA) { throw "Tier '$TierNameA' not found in service configuration. Check the tier name in the template." }
if (-not $tierB) { throw "Tier '$TierNameB' not found in service configuration. Check the tier name in the template." }

# Each tier is Initial:1 so take index [0]
$vmCfgA = $tierA.VMConfigurations[0]
$vmCfgB = $tierB.VMConfigurations[0]

# Set both the VMM VM Name and the Guest OS Computer Name
Set-SCVMConfiguration -VMConfiguration $vmCfgA -Name $fqdnA -ComputerName $fqdnA | Out-Null
Set-SCVMConfiguration -VMConfiguration $vmCfgB -Name $fqdnB -ComputerName $fqdnB | Out-Null

# Optional quick verification before deploy
$svcCfg.ComputerTierConfigurations |
ForEach-Object {
    $_.Name
    $_.VMConfigurations | Select-Object Name, ComputerName
}

# =======================
# DEPLOY
# =======================
New-SCService -ServiceConfiguration $svcCfg
