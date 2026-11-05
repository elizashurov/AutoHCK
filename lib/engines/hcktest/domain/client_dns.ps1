if ($env:COMPUTERNAME -ine $clientName) { throw 'Unexpected client hostname' }
$address = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $controlIP)
if ($address.Count -ne 1) { throw 'Expected exactly one control interface' }
Set-DnsClientServerAddress -InterfaceIndex $address[0].InterfaceIndex -ServerAddresses $dcIP
Clear-DnsClientCache
@{ configured = $true } | ConvertTo-Json -Compress
