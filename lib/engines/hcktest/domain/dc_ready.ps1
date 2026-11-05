if ($env:COMPUTERNAME -ine $dcName) { throw 'Unexpected DC hostname' }
Import-Module ActiveDirectory -WarningAction SilentlyContinue
$adDomain = Get-ADDomain -Server "$dcName.$domain" -Credential $credential
if ($adDomain.DNSRoot -ine $domain) { throw 'Unexpected AD domain' }
$address = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $dcIP)
if ($address.Count -ne 1) { throw 'DC address is not configured' }
foreach ($service in @('NTDS', 'DNS', 'Netlogon')) {
    if ((Get-Service $service).Status -ne 'Running') { throw 'Domain service is not running' }
}
$null = Get-SmbShare -Name SYSVOL,NETLOGON
@{ ready = $true } | ConvertTo-Json -Compress
