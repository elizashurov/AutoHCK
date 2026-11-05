if ($env:COMPUTERNAME -ine $clientName) { throw 'Unexpected client hostname' }
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw 'Client is already a domain member' }
$result = Add-Computer -DomainName $domain -Server "$dcName.$domain" -Credential $credential -PassThru -Force -WarningAction SilentlyContinue
if (-not $result.HasSucceeded) { throw 'Domain join failed' }
@{ joined = $true } | ConvertTo-Json -Compress
