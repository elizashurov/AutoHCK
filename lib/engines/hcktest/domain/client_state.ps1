$computer = Get-CimInstance Win32_ComputerSystem
@{ name = $computer.Name; member = [bool]$computer.PartOfDomain; domain = $computer.Domain } |
    ConvertTo-Json -Compress
