#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Queries and resets the Remote Desktop Services (RDS) licensing grace period to 120 days.

.DESCRIPTION
    Takes ownership of the registry key
    HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod,
    backs it up, deletes it and restarts the RDS services.
    Works on the local computer or on remote servers via WinRM (Invoke-Command).

.PARAMETER ComputerName
    Target server(s). Default: the local computer.

.PARAMETER QueryOnly
    Only displays the remaining grace period days. Makes no changes.

.PARAMETER NoRestart
    Does not restart the RDS services after the reset.

.PARAMETER Force
    Resets without asking for confirmation.

.PARAMETER BackupPath
    Folder (on the target server) where a .reg backup of the key is written before deletion.

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -QueryOnly

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -ComputerName RDS01,RDS02 -Force

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -WhatIf

.NOTES
    Original: Prakash Kumar (2016). Improved version.
    WARNING: Resetting the grace period is not a substitute for RDS CALs. Continuous use
    in production without CALs violates Microsoft licensing terms. Intended for test/lab
    environments or temporary use while CALs are being procured.
    Test in a non-production environment first.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('CN', 'ServerName')]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [switch]$QueryOnly,
    [switch]$NoRestart,
    [switch]$Force,

    [string]$BackupPath = 'C:\Windows\Temp'
)

begin {
    if ($Force -and -not $WhatIfPreference) { $ConfirmPreference = 'None' }

    $results = [System.Collections.Generic.List[object]]::new()

    # ------------------------------------------------------------------
    # Core logic that runs on the target machine (local or remote)
    # ------------------------------------------------------------------
    $core = {
        param([bool]$Reset, [bool]$NoRestart, [string]$BackupPath)

        $ErrorActionPreference = 'Stop'

        function Get-GraceDays {
            try {
                $ts = Get-CimInstance -Namespace root/CIMV2/TerminalServices -ClassName Win32_TerminalServiceSetting
                (Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays).DaysLeft
            }
            catch { $null }
        }

        $result = [ordered]@{
            ComputerName      = $env:COMPUTERNAME
            DaysBefore        = Get-GraceDays
            DaysAfter         = $null
            Reset             = $false
            ServicesRestarted = $false
            Backup            = $null
            Message           = ''
        }

        if (-not $Reset) {
            if ($null -eq $result.DaysBefore) {
                $result.Message = 'Could not read remaining days (RD Session Host role not installed or grace period not started).'
            }
            else { $result.Message = 'Query only.' }
            return [pscustomobject]$result
        }

        $keyPath = 'SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'
        $psPath  = "HKLM:\$keyPath"

        if (-not (Test-Path -LiteralPath $psPath)) {
            $result.Message = 'GracePeriod key not found; nothing to reset.'
            return [pscustomobject]$result
        }

        # Enable SeTakeOwnershipPrivilege (correct signature: ULONG + 1-byte BOOLEAN)
        if (-not ('RdsGrace.TokenPriv' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RdsGrace {
    public static class TokenPriv {
        [DllImport("ntdll.dll")]
        public static extern int RtlAdjustPrivilege(
            uint Privilege,
            [MarshalAs(UnmanagedType.U1)] bool Enable,
            [MarshalAs(UnmanagedType.U1)] bool CurrentThread,
            [MarshalAs(UnmanagedType.U1)] out bool Enabled);
    }
}
'@
        }
        $prev = $false
        $status = [RdsGrace.TokenPriv]::RtlAdjustPrivilege(9, $true, $false, [ref]$prev)
        if ($status -ne 0) {
            throw ('Failed to enable SeTakeOwnershipPrivilege (NTSTATUS 0x{0:X8})' -f $status)
        }

        # Language-independent: BUILTIN\Administrators by well-known SID
        # (the group name differs on localized Windows, e.g. "Yoneticiler" on Turkish)
        $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $hklm     = [Microsoft.Win32.Registry]::LocalMachine
        $rwTree   = [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        $rights   = [System.Security.AccessControl.RegistryRights]

        # 1) Take ownership of the key
        $key = $hklm.OpenSubKey($keyPath, $rwTree, $rights::TakeOwnership)
        try {
            $acl = New-Object System.Security.AccessControl.RegistrySecurity
            $acl.SetOwner($adminSid)
            $key.SetAccessControl($acl)
        }
        finally { $key.Close() }

        # 2) Grant Full Control to Administrators (using a new handle)
        $key = $hklm.OpenSubKey($keyPath, $rwTree, ($rights::ChangePermissions -bor $rights::ReadPermissions))
        try {
            $acl  = $key.GetAccessControl()
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $adminSid, 'FullControl', 'ContainerInherit', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            $key.SetAccessControl($acl)
        }
        finally { $key.Close() }

        # 3) Back up the key
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        }
        $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backup = Join-Path $BackupPath "GracePeriod_$($env:COMPUTERNAME)_$stamp.reg"
        & reg.exe export "HKLM\$keyPath" $backup /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to back up registry key to: $backup" }
        $result.Backup = $backup

        # 4) Delete the key -> counter resets to 120 days
        Remove-Item -LiteralPath $psPath -Recurse -Force
        $result.Reset = $true

        # 5) Restart RDS services
        if (-not $NoRestart) {
            try {
                Restart-Service -Name TermService -Force          # dependents such as UmRdpService restart too
                Restart-Service -Name SessionEnv -Force -ErrorAction SilentlyContinue
                $result.ServicesRestarted = $true
                Start-Sleep -Seconds 5
            }
            catch {
                $result.Message = "Could not restart services ($($_.Exception.Message)). Please reboot the server."
            }
        }

        $result.DaysAfter = Get-GraceDays
        if (-not $result.Message) {
            $result.Message = if ($result.ServicesRestarted) { 'Reset completed.' }
                              else { 'Reset completed. Restart the RDS services or reboot the server for it to take effect.' }
        }
        return [pscustomobject]$result
    }

    function Invoke-Core {
        param([string]$Computer, [bool]$Local, [bool]$Reset, [bool]$NoRst)
        $argList = @($Reset, $NoRst, $BackupPath)
        if ($Local) { & $core @argList }
        else {
            Invoke-Command -ComputerName $Computer -ScriptBlock $core -ArgumentList $argList -ErrorAction Stop
        }
    }
}

process {
    foreach ($computer in $ComputerName) {
        $isLocal = $computer -in @('.', 'localhost', $env:COMPUTERNAME) -or
                   ($env:USERDNSDOMAIN -and $computer -eq "$env:COMPUTERNAME.$env:USERDNSDOMAIN")

        try {
            $q    = Invoke-Core -Computer $computer -Local $isLocal -Reset $false -NoRst $true
            $days = if ($null -ne $q.DaysBefore) { $q.DaysBefore } else { 'unknown' }
            Write-Host -ForegroundColor Green ("[{0}] RDS grace period days remaining: {1}" -f $computer, $days)

            if ($QueryOnly) { $results.Add($q); continue }

            $noRst = [bool]$NoRestart
            if ($isLocal -and -not $NoRestart -and $env:SESSIONNAME -like 'RDP-Tcp*') {
                Write-Warning "Running from an RDP session. Restarting TermService would drop your connection, so the service restart will be skipped. Reboot the server after the reset."
                $noRst = $true
            }

            if ($PSCmdlet.ShouldProcess($computer, "Reset RDS grace period to 120 days (currently: $days days)")) {
                $r = Invoke-Core -Computer $computer -Local $isLocal -Reset $true -NoRst $noRst
                $color = if ($r.Reset) { 'Cyan' } else { 'Yellow' }
                Write-Host -ForegroundColor $color ("[{0}] {1}" -f $computer, $r.Message)
                $results.Add($r)
            }
            else {
                $results.Add($q)
            }
        }
        catch {
            Write-Error "[$computer] $($_.Exception.Message)"
        }
    }
}

end {
    $results | Select-Object ComputerName, DaysBefore, DaysAfter, Reset, ServicesRestarted, Backup, Message
}
