$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Name -ine $clientName -or -not $computer.PartOfDomain -or $computer.Domain -ine $domain) {
    throw 'Unexpected domain membership'
}
$address = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $controlIP)
if ($address.Count -ne 1) { throw 'Expected exactly one control interface' }
$dns = @((Get-DnsClientServerAddress -InterfaceIndex $address[0].InterfaceIndex -AddressFamily IPv4).ServerAddresses)
if ($dns.Count -ne 1 -or $dns[0] -ne $dcIP) { throw 'Unexpected control DNS configuration' }
$hostRecords = @(Resolve-DnsName -Name "$dcName.$domain" -Type A -DnsOnly)
if ($dcIP -notin $hostRecords.IPAddress) { throw 'DC DNS address does not match' }
$srv = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" -Type SRV -DnsOnly)
$matching = @($srv | Where-Object { $_.Type -eq 'SRV' -and $_.NameTarget.TrimEnd('.') -ieq "$dcName.$domain" -and $_.Port -eq 389 })
if ($matching.Count -eq 0) { throw 'Domain locator SRV record does not match' }
if (-not (Test-ComputerSecureChannel -Server "$dcName.$domain")) { throw 'Domain secure channel is broken' }
@{ verified = $true } | ConvertTo-Json -Compress
