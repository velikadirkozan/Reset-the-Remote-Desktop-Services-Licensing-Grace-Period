# Reset the Remote Desktop Services Licensing Grace Period

**[English](#english) | [Türkçe](#türkçe)**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Windows Server](https://img.shields.io/badge/Windows%20Server-2012%20R2%20%7C%202016%20%7C%202019%20%7C%202022%20%7C%202025-0078D6?logo=windows&logoColor=white)

---

## English

A PowerShell script that queries and resets the **Remote Desktop Services (RDS) licensing grace period** on Windows Server back to **120 days**. It works on the local server or on multiple remote servers over WinRM.

> [!WARNING]
> Resetting the grace period is **not** a substitute for RDS CALs. Continuous production use without proper CALs violates Microsoft licensing terms. This tool is intended for **test/lab environments** or for **temporary use while CALs are being procured**. Always test in a non-production environment first.

### Features

- Shows the remaining grace period days (`-QueryOnly`)
- Resets the grace period to 120 days by removing the `GracePeriod` registry key
- Backs up the registry key (`.reg`) before deleting it
- Restarts the RDS services automatically (skipped when run from an RDP session, so your connection is not dropped)
- Runs against multiple remote servers (`-ComputerName`) or a server list from a file
- Supports `-WhatIf`, `-Confirm` and `-Force`
- Language-independent: uses the well-known Administrators SID, so it works on localized Windows (e.g. Turkish)
- Returns a result table per server (days before/after, backup path, status)

### Repository Contents

| Path | Description |
|------|-------------|
| `EN/` | English version of the script |
| `TR/` | Turkish version of the script |
| `1-Docs-EN.txt` | Documentation (English) |
| `1-Docs-TR.txt` | Documentation (Turkish) |
| `en-reset-scirpt.txt` | Script source as plain text (English) |
| `tr-reset-script.txt` | Script source as plain text (Turkish) |
| `powershell-command.txt` | Ready-to-use PowerShell commands |
| `script-usage.txt` | Step-by-step usage guide |
| `Script-Kullanimi.docx` | Usage guide (Word document) |

### Requirements

- Windows Server with the **RD Session Host** role installed
- Windows PowerShell **5.1** or later
- PowerShell started **as Administrator**
- For remote servers: WinRM enabled on the targets (`Enable-PSRemoting -Force`)

### Usage

1. Copy `Reset-TSGracePeriod.ps1` to the server, for example `C:\Scripts`.
2. Open **Windows PowerShell as Administrator**.
3. Unblock the file and allow scripts for the current session only:

```powershell
cd C:\Scripts
Unblock-File .\Reset-TSGracePeriod.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

4. Run the script:

```powershell
# Show remaining days only (no changes)
.\Reset-TSGracePeriod.ps1 -QueryOnly

# Show what would happen (no changes)
.\Reset-TSGracePeriod.ps1 -WhatIf

# Reset with confirmation prompt
.\Reset-TSGracePeriod.ps1

# Reset without confirmation
.\Reset-TSGracePeriod.ps1 -Force

# Remote servers
.\Reset-TSGracePeriod.ps1 -ComputerName RDS01,RDS02 -Force

# Server list from a file (one name per line)
Get-Content .\servers.txt | .\Reset-TSGracePeriod.ps1 -Force

# Reset without restarting services
.\Reset-TSGracePeriod.ps1 -Force -NoRestart
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `-ComputerName` | Target server(s). Default: local computer. Aliases: `CN`, `ServerName` |
| `-QueryOnly` | Only displays remaining days, makes no changes |
| `-NoRestart` | Does not restart RDS services after the reset |
| `-Force` | Resets without asking for confirmation |
| `-BackupPath` | Backup folder on the target server. Default: `C:\Windows\Temp` |
| `-WhatIf` / `-Confirm` | Standard PowerShell safety switches |

### How It Works

1. Reads the remaining days from `Win32_TerminalServiceSetting`.
2. Enables `SeTakeOwnershipPrivilege` and takes ownership of
   `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod`.
3. Grants Full Control to the Administrators group.
4. Exports a `.reg` backup of the key.
5. Deletes the key, which resets the counter to 120 days.
6. Restarts `TermService` and `SessionEnv`, then reads the remaining days again.

### Verifying and Rolling Back

- In the result table, `Reset = True` and `DaysAfter = 120` indicate success.
- If the services were not restarted (e.g. run over RDP), reboot the server: `Restart-Computer -Force`
- To restore the original key:

```powershell
reg import "C:\Windows\Temp\GracePeriod_SERVERNAME_yyyyMMdd_HHmmss.reg"
```

### Notes

- Restarting `TermService` disconnects **all** RDP sessions on that server. Run it outside working hours.
- Based on the original script by Prakash Kumar (2016); rewritten and improved.

---

## Türkçe

Windows Server üzerinde **Uzak Masaüstü Hizmetleri (RDS) lisanslama grace period** süresini sorgulayan ve **120 güne** sıfırlayan bir PowerShell script'idir. Yerel sunucuda veya WinRM üzerinden birden fazla uzak sunucuda çalışır.

> [!WARNING]
> Grace period'u sıfırlamak RDS CAL yerine **geçmez**. Üretim ortamında CAL olmadan sürekli kullanım Microsoft lisans koşullarına aykırıdır. Bu araç **test/lab ortamları** veya **CAL temini beklenirken geçici kullanım** içindir. Her zaman önce test ortamında deneyin.

### Özellikler

- Kalan grace period gün sayısını gösterir (`-QueryOnly`)
- `GracePeriod` kayıt defteri anahtarını silerek süreyi 120 güne sıfırlar
- Silmeden önce anahtarın `.reg` yedeğini alır
- RDS servislerini otomatik yeniden başlatır (RDP oturumundan çalıştırıldığında bağlantınız kopmasın diye bu adım atlanır)
- Birden fazla uzak sunucuda (`-ComputerName`) veya dosyadaki sunucu listesinde çalışır
- `-WhatIf`, `-Confirm` ve `-Force` desteği
- Dil bağımsız: Administrators grubunu SID ile bulur, Türkçe Windows'ta ("Yöneticiler") sorunsuz çalışır
- Her sunucu için sonuç tablosu döner (önceki/sonraki gün, yedek yolu, durum)

### Depo İçeriği

| Yol | Açıklama |
|-----|----------|
| `EN/` | Script'in İngilizce sürümü |
| `TR/` | Script'in Türkçe sürümü |
| `1-Docs-EN.txt` | Dokümantasyon (İngilizce) |
| `1-Docs-TR.txt` | Dokümantasyon (Türkçe) |
| `en-reset-scirpt.txt` | Script kaynağı, düz metin (İngilizce) |
| `tr-reset-script.txt` | Script kaynağı, düz metin (Türkçe) |
| `powershell-command.txt` | Hazır PowerShell komutları |
| `script-usage.txt` | Adım adım kullanım kılavuzu |
| `Script-Kullanimi.docx` | Kullanım kılavuzu (Word belgesi) |

### Gereksinimler

- **RD Session Host** rolü kurulu Windows Server
- Windows PowerShell **5.1** veya üzeri
- PowerShell'in **Yönetici olarak** açılmış olması
- Uzak sunucular için: hedeflerde WinRM açık olmalı (`Enable-PSRemoting -Force`)

### Kullanım

1. `Reset-TSGracePeriod.ps1` dosyasını sunucuya kopyalayın, örneğin `C:\Scripts`.
2. **Windows PowerShell'i Yönetici olarak** açın.
3. Dosyanın engelini kaldırın ve yalnızca bu oturum için script çalıştırmaya izin verin:

```powershell
cd C:\Scripts
Unblock-File .\Reset-TSGracePeriod.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

4. Script'i çalıştırın:

```powershell
# Sadece kalan günü göster (değişiklik yapmaz)
.\Reset-TSGracePeriod.ps1 -QueryOnly

# Ne yapılacağını göster (değişiklik yapmaz)
.\Reset-TSGracePeriod.ps1 -WhatIf

# Onay sorarak sıfırla
.\Reset-TSGracePeriod.ps1

# Onay sormadan sıfırla
.\Reset-TSGracePeriod.ps1 -Force

# Uzak sunucular
.\Reset-TSGracePeriod.ps1 -ComputerName RDS01,RDS02 -Force

# Dosyadan sunucu listesi (her satırda bir sunucu adı)
Get-Content .\sunucular.txt | .\Reset-TSGracePeriod.ps1 -Force

# Servisleri yeniden başlatmadan sıfırla
.\Reset-TSGracePeriod.ps1 -Force -NoRestart
```

### Parametreler

| Parametre | Açıklama |
|-----------|----------|
| `-ComputerName` | Hedef sunucu(lar). Varsayılan: yerel bilgisayar. Takma adlar: `CN`, `ServerName` |
| `-QueryOnly` | Sadece kalan günü gösterir, değişiklik yapmaz |
| `-NoRestart` | Sıfırlamadan sonra RDS servislerini yeniden başlatmaz |
| `-Force` | Onay sormadan sıfırlar |
| `-BackupPath` | Hedef sunucudaki yedek klasörü. Varsayılan: `C:\Windows\Temp` |
| `-WhatIf` / `-Confirm` | Standart PowerShell güvenlik parametreleri |

### Nasıl Çalışır

1. Kalan gün sayısını `Win32_TerminalServiceSetting` üzerinden okur.
2. `SeTakeOwnershipPrivilege` yetkisini etkinleştirir ve
   `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod` anahtarının sahipliğini alır.
3. Administrators grubuna Tam Denetim verir.
4. Anahtarın `.reg` yedeğini alır.
5. Anahtarı siler; sayaç 120 güne döner.
6. `TermService` ve `SessionEnv` servislerini yeniden başlatır ve kalan günü tekrar okur.

### Doğrulama ve Geri Alma

- Sonuç tablosunda `Reset = True` ve `DaysAfter = 120` ise işlem başarılıdır.
- Servisler yeniden başlatılmadıysa (örneğin RDP ile çalıştırıldıysa) sunucuyu yeniden başlatın: `Restart-Computer -Force`
- Orijinal anahtarı geri yüklemek için:

```powershell
reg import "C:\Windows\Temp\GracePeriod_SUNUCUADI_yyyyMMdd_HHmmss.reg"
```

### Notlar

- `TermService` yeniden başlatıldığında o sunucudaki **tüm** RDP oturumları kopar. Mesai dışında çalıştırın.
- Prakash Kumar'ın orijinal script'i (2016) temel alınarak yeniden yazılmış ve geliştirilmiştir.

---

## Disclaimer / Sorumluluk Reddi

**EN:** This script is provided "as is", without warranty of any kind. Use it at your own risk. The author is not responsible for any damage or licensing violations resulting from its use.

**TR:** Bu script herhangi bir garanti olmaksızın "olduğu gibi" sunulmaktadır. Kullanım riski size aittir. Kullanımından doğabilecek zararlardan veya lisans ihlallerinden yazar sorumlu değildir.

## Author / Yazar

**Veli Kadir KOZAN** – [@velikadirkozan](https://github.com/velikadirkozan)
