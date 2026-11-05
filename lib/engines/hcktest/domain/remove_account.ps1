if ($env:COMPUTERNAME -ine $dcName) { throw 'Unexpected DC hostname' }
if ($clientName -notin $allowedClients -or $clientName -ieq $dcName) { throw 'Account is outside the client allowlist' }
Import-Module ActiveDirectory -WarningAction SilentlyContinue
$adServer = "$dcName.$domain"
if ((Get-ADDomain -Server $adServer -Credential $credential).DNSRoot -ine $domain) { throw 'Unexpected AD domain' }
$sam = $clientName + '$'
$accounts = @(Get-ADComputer -LDAPFilter "(sAMAccountName=$sam)" -Server $adServer -Credential $credential `
    -Properties DNSHostName,userAccountControl,isCriticalSystemObject)
if ($accounts.Count -gt 1) { throw 'Ambiguous AD computer account' }
foreach ($account in $accounts) {
    if ($account.Name -ine $clientName -or $account.SamAccountName -ine $sam) { throw 'Unexpected AD identity' }
    if ($account.isCriticalSystemObject -or ($account.userAccountControl -band 8192) -or
        -not ($account.userAccountControl -band 4096)) { throw 'Refusing to remove a protected or DC account' }
    if ($account.DNSHostName -and $account.DNSHostName -ine "$clientName.$domain") { throw 'Unexpected AD DNS hostname' }
    Remove-ADComputer -Identity $account.ObjectGUID -Server $adServer -Credential $credential -Confirm:$false
}
@{ removed = ($accounts.Count -eq 1) } | ConvertTo-Json -Compress
