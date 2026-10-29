#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    RDS (Terminal Server) lisanslama grace period süresini sorgular ve 120 güne sıfırlar.

.DESCRIPTION
    HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod anahtarının
    sahipliğini alır, yedeğini çıkarır, siler ve RDS servislerini yeniden başlatır.
    Yerel ya da uzak (WinRM / Invoke-Command) sunucularda çalışır.

.PARAMETER ComputerName
    Hedef sunucu(lar). Varsayılan: yerel bilgisayar.

.PARAMETER QueryOnly
    Sadece kalan gün sayısını gösterir, hiçbir değişiklik yapmaz.

.PARAMETER NoRestart
    Sıfırlamadan sonra RDS servislerini yeniden başlatmaz.

.PARAMETER Force
    Onay sormadan sıfırlar.

.PARAMETER BackupPath
    Silinmeden önce anahtarın .reg yedeğinin yazılacağı klasör (hedef sunucuda).

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -QueryOnly

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -ComputerName RDS01,RDS02 -Force

.EXAMPLE
    .\Reset-TSGracePeriod.ps1 -WhatIf

.NOTES
    Orijinal: Prakash Kumar (2016). Geliştirilmiş sürüm.
    UYARI: Grace period'u sıfırlamak lisans (RDS CAL) yerine geçmez. Üretim ortamında
    CAL olmadan sürekli kullanım Microsoft lisans koşullarına aykırıdır; test/lab
    ortamları veya CAL temini beklenirken geçici kullanım içindir.
    Önce test ortamında deneyin.
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
    # Hedef makinede (yerel veya uzak) çalışan asıl iş
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
                $result.Message = 'Gun sayisi alinamadi (RD Session Host rolu yok veya grace period baslamamis).'
            }
            else { $result.Message = 'Yalnizca sorgu.' }
            return [pscustomobject]$result
        }

        $keyPath = 'SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'
        $psPath  = "HKLM:\$keyPath"

        if (-not (Test-Path -LiteralPath $psPath)) {
            $result.Message = 'GracePeriod anahtari bulunamadi; sifirlanacak bir sey yok.'
            return [pscustomobject]$result
        }

        # SeTakeOwnershipPrivilege'i etkinleştir (doğru imza: ULONG + 1 baytlık BOOLEAN)
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
            throw ('SeTakeOwnershipPrivilege etkinlestirilemedi (NTSTATUS 0x{0:X8})' -f $status)
        }

        # Dil bağımsız: BUILTIN\Administrators (Türkçe Windows'ta "Yöneticiler")
        $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $hklm     = [Microsoft.Win32.Registry]::LocalMachine
        $rwTree   = [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
        $rights   = [System.Security.AccessControl.RegistryRights]

        # 1) Sahipliği al
        $key = $hklm.OpenSubKey($keyPath, $rwTree, $rights::TakeOwnership)
        try {
            $acl = New-Object System.Security.AccessControl.RegistrySecurity
            $acl.SetOwner($adminSid)
            $key.SetAccessControl($acl)
        }
        finally { $key.Close() }

        # 2) Administrators'a Tam Denetim ver (yeni handle ile)
        $key = $hklm.OpenSubKey($keyPath, $rwTree, ($rights::ChangePermissions -bor $rights::ReadPermissions))
        try {
            $acl  = $key.GetAccessControl()
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $adminSid, 'FullControl', 'ContainerInherit', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            $key.SetAccessControl($acl)
        }
        finally { $key.Close() }

        # 3) Yedek al
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        }
        $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backup = Join-Path $BackupPath "GracePeriod_$($env:COMPUTERNAME)_$stamp.reg"
        & reg.exe export "HKLM\$keyPath" $backup /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Kayit defteri yedegi alinamadi: $backup" }
        $result.Backup = $backup

        # 4) Anahtarı sil -> sayaç 120 güne döner
        Remove-Item -LiteralPath $psPath -Recurse -Force
        $result.Reset = $true

        # 5) Servisleri yeniden başlat
        if (-not $NoRestart) {
            try {
                Restart-Service -Name TermService -Force          # UmRdpService gibi bağımlılar da yeniden başlar
                Restart-Service -Name SessionEnv -Force -ErrorAction SilentlyContinue
                $result.ServicesRestarted = $true
                Start-Sleep -Seconds 5
            }
            catch {
                $result.Message = "Servisler yeniden baslatilamadi ($($_.Exception.Message)). Sunucuyu yeniden baslatin."
            }
        }

        $result.DaysAfter = Get-GraceDays
        if (-not $result.Message) {
            $result.Message = if ($result.ServicesRestarted) { 'Sifirlandi.' }
                              else { 'Sifirlandi. Etkin olmasi icin RDS servislerini yeniden baslatin veya sunucuyu yeniden baslatin.' }
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
            $days = if ($null -ne $q.DaysBefore) { $q.DaysBefore } else { 'alinamadi' }
            Write-Host -ForegroundColor Green ("[{0}] Kalan RDS grace period: {1} gün" -f $computer, $days)

            if ($QueryOnly) { $results.Add($q); continue }

            $noRst = [bool]$NoRestart
            if ($isLocal -and -not $NoRestart -and $env:SESSIONNAME -like 'RDP-Tcp*') {
                Write-Warning "Bu script RDP oturumundan çalışıyor. TermService yeniden başlatılırsa bağlantınız kopar; servis yeniden başlatma atlanacak. İşlemden sonra sunucuyu yeniden başlatın."
                $noRst = $true
            }

            if ($PSCmdlet.ShouldProcess($computer, "RDS grace period'u 120 güne sıfırla (şu an: $days gün)")) {
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
