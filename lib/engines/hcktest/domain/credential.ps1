# Used for Add-Computer and AD cmdlets so remoting needs no credential delegation.
$securePassword = ConvertTo-SecureString $domainPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($domainUser, $securePassword)
