# Taskless: подключение агентов на этом компьютере.
#
# Один файл, его отдают как https://taskless.ru/connect.ps1 и запускают
# `irm https://taskless.ru/connect.ps1 | iex`. Рядом ничего нет.
# Логика — зеркало connect.sh: те же режимы, те же тексты, те же маркеры в файлах.
#
# Запуск файлом — в PowerShell 7 (pwsh). Windows PowerShell 5.1 читает файл без BOM
# как ANSI и не разбирает русские строки, там — только irm | iex.
#
#   pwsh -NoProfile -File connect.ps1
#   pwsh -NoProfile -File connect.ps1 -dry-run     не то: флаги с двумя минусами
#   pwsh -NoProfile -File connect.ps1 --dry-run
#   pwsh -NoProfile -File connect.ps1 --only claude-code,codex
#   pwsh -NoProfile -File connect.ps1 --status
#   pwsh -NoProfile -File connect.ps1 --uninstall
#
# Ключ — Windows Credential Manager (target taskless-device, user taskless).
# Если записать его не вышло — файл ~/.config/taskless/device-key,
# на Windows с ACL только для текущего пользователя, иначе права 600.
#
# Адаптер — найти / прописать / снять. Правка только блоком
# `# >>> taskless:<id>` … `# <<< taskless:<id>`, до неё копия *.bak-taskless.
# Настоящие клиенты — задачи MCP-105 и MCP-106. Сейчас поиск отвечает «нет»,
# кроме заглушки TASKLESS_CONNECT_STUB=1.
#
# TASKLESS_URL — база API, по умолчанию https://taskless.ru/api.
# Кодировка файла — UTF-8 без BOM: публичная команда irm | iex получает текст
# с charset=utf-8. `exit` только когда скрипт запущен файлом, не из iex:
# иначе закрылся бы сеанс человека.
# Тело в & { } — после irm | iex в сеансе не остаются функции и ErrorActionPreference.
# Состояние — в хеш-таблице $tl, локальной для & { }, а не в $script:: под iex
# в консоли область script — это глобальная, и ключ остался бы в $Token сеанса.

& {
$ErrorActionPreference = "Stop"
$tl = @{}
$tl.LaunchArgs = @($args)
# Нативные команды (браузер, cmdkey) ставят глобальный $LASTEXITCODE. Под iex
# вернём его как было, чтобы в сеансе не появилось ни одной новой переменной.
$tl.HadLastExit = Test-Path variable:global:LASTEXITCODE
if ($tl.HadLastExit) { $tl.LastExit = $global:LASTEXITCODE }

$tl.ClientVersion = "0.1.0"
$tl.ClientId = "taskless-device"
$tl.AgentIds = @(
  "claude-code", "codex", "grok", "zcode", "cursor",
  "gemini", "opencode", "copilot", "qwen", "kimi"
)
$tl.Names = @{
  "claude-code" = "Claude Code"
  "codex"       = "Codex"
  "grok"        = "Grok"
  "zcode"       = "ZCode"
  "cursor"      = "Cursor"
  "gemini"      = "Gemini CLI"
  "opencode"    = "OpenCode"
  "copilot"     = "Copilot CLI"
  "qwen"        = "Qwen Code"
  "kimi"        = "Kimi CLI"
}
$tl.Aliases = @{
  "claude"      = "claude-code"
  "claude-code" = "claude-code"
  "codex"       = "codex"
  "grok"        = "grok"
  "zcode"       = "zcode"
  "z-code"      = "zcode"
  "cursor"      = "cursor"
  "gemini"      = "gemini"
  "opencode"    = "opencode"
  "open-code"   = "opencode"
  "copilot"     = "copilot"
  "qwen"        = "qwen"
  "kimi"        = "kimi"
}
$tl.Manuals = @{
  "claude-code" = "перезапусти Claude Code"
  "codex"       = "в Codex одобри хуки командой /hooks"
}

$tl.Dry = $false
$tl.DoStatus = $false
$tl.DoUninstall = $false
$tl.Only = @()
$tl.Token = ""
$tl.StoreKind = ""
$tl.DidHelp = $false

try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
} catch {}

function Test-WindowsOs {
  if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
  return [bool]$IsWindows
}

function Get-HomeDir {
  if ($env:HOME) { return $env:HOME }
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  return ""
}

function Say([string]$text) {
  Write-Host $text
}

function Die([string]$text) {
  Say $text
  throw "taskless-die"
}

function Show-Usage {
  Say @"
Taskless: подключение агентов на этом компьютере.

  powershell -NoProfile -File connect.ps1
  powershell -NoProfile -File connect.ps1 --dry-run
  powershell -NoProfile -File connect.ps1 --only claude-code,codex
  powershell -NoProfile -File connect.ps1 --status
  powershell -NoProfile -File connect.ps1 --uninstall
"@
}

function Get-AgentName([string]$id) {
  if ($tl.Names.ContainsKey($id)) { return $tl.Names[$id] }
  return $id
}

function ConvertTo-CanonId([string]$raw) {
  $key = $raw.Trim().ToLowerInvariant()
  if ($tl.Aliases.ContainsKey($key)) { return $tl.Aliases[$key] }
  return ""
}

function Format-Names([string[]]$ids) {
  $parts = @()
  foreach ($id in $ids) { $parts += (Get-AgentName $id) }
  return ($parts -join ", ")
}

function Format-Tilde([string]$path) {
  $homeDir = Get-HomeDir
  if ($homeDir -and ($path -eq $homeDir -or $path.StartsWith($homeDir + [IO.Path]::DirectorySeparatorChar) -or $path.StartsWith($homeDir + "/"))) {
    $rel = $path.Substring($homeDir.Length).TrimStart("\", "/")
    if (-not $rel) { return "~" }
    return "~/" + ($rel -replace "\\", "/")
  }
  return $path
}

function Set-OnlyList([string]$raw) {
  $tl.Only = @()
  foreach ($item in ($raw -split "[,\s]+")) {
    if (-not $item) { continue }
    $id = ConvertTo-CanonId $item
    if (-not $id) { Die "Не знаю агента: $item" }
    if ($tl.Only -notcontains $id) { $tl.Only += $id }
  }
  if ($tl.Only.Count -eq 0) { Die "После --only нужен список агентов." }
}

function Read-Args([string[]]$argv) {
  $i = 0
  while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    switch ($a) {
      "--dry-run" { $tl.Dry = $true }
      "--status" { $tl.DoStatus = $true }
      "--uninstall" { $tl.DoUninstall = $true }
      "--only" {
        $i++
        if ($i -ge $argv.Count) { Die "После --only нужен список агентов." }
        Set-OnlyList ([string]$argv[$i])
      }
      "-h" { Show-Usage; $tl.DidHelp = $true }
      "--help" { Show-Usage; $tl.DidHelp = $true }
      default {
        if ($a.StartsWith("--only=")) { Set-OnlyList $a.Substring(7) }
        else { Die "Не знаю аргумент: $a" }
      }
    }
    $i++
  }
  if ($tl.DoStatus -and $tl.DoUninstall) { Die "Укажи что-то одно: --status или --uninstall." }
  if ($tl.DoStatus -and $tl.Dry) { Die "--status ничего не меняет и без --dry-run." }
}

function Test-WantId([string]$id) {
  if ($tl.Only.Count -eq 0) { return $true }
  return $tl.Only -contains $id
}

function Test-StubWants([string]$id) {
  if ($env:TASKLESS_CONNECT_STUB -ne "1") { return $false }
  $raw = $env:TASKLESS_STUB_AGENTS
  if (-not $raw) { $raw = "claude-code" }
  $list = @($raw -split "[,\s]+" | Where-Object { $_ })
  return $list -contains $id
}

function Get-StubFile([string]$id) {
  return (Join-Path (Join-Path (Get-HomeDir) ".taskless-stub") "$id.conf")
}

function Test-AgentFound([string]$id) {
  # Настоящий поиск — в адаптере следующей задачи. Пока клиента нет.
  return (Test-StubWants $id)
}

function Get-PlatformName {
  if ($env:TASKLESS_PLATFORM) { return $env:TASKLESS_PLATFORM }
  if (Test-WindowsOs) { return "windows" }
  if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) { return "macos" }
  if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) { return "linux" }
  return "windows"
}

function Get-CleanName([string]$raw) {
  if (-not $raw) { $raw = "" }
  $text = [regex]::Replace($raw, "[\u0000-\u001f]", " ")
  $text = $text -replace "[<>]", " "
  $text = [regex]::Replace($text, "\s+", " ").Trim()
  if (-not $text) { return "computer" }
  $chars = $text.ToCharArray()
  if ($chars.Length -gt 64) { return -join $chars[0..63] }
  return $text
}

function Get-DeviceName {
  if ($env:TASKLESS_DEVICE_NAME) { return (Get-CleanName $env:TASKLESS_DEVICE_NAME) }
  $name = $env:COMPUTERNAME
  if (-not $name) { $name = [Environment]::MachineName }
  if (-not $name) { $name = "computer" }
  return (Get-CleanName $name)
}

function Get-OsVersion {
  $ver = $env:TASKLESS_OS_VERSION
  if (-not $ver) {
    try { $ver = [Environment]::OSVersion.Version.ToString() } catch { $ver = "" }
  }
  if ($ver -and $ver -match "^[0-9A-Za-z .()_-]{1,32}$") { return $ver }
  return ""
}

function Get-Utf8 {
  return (New-Object System.Text.UTF8Encoding $false)
}

function Join-Bytes {
  param($parts)
  $len = 0
  foreach ($p in $parts) { if ($p) { $len += $p.Length } }
  $out = New-Object byte[] $len
  $o = 0
  foreach ($p in $parts) {
    if (-not $p -or $p.Length -eq 0) { continue }
    [Array]::Copy($p, 0, $out, $o, $p.Length)
    $o += $p.Length
  }
  return ,$out
}

function Slice-Bytes([byte[]]$data, [int]$start, [int]$len) {
  if ($len -le 0) { return ,[byte[]]@() }
  $out = New-Object byte[] $len
  [Array]::Copy($data, $start, $out, 0, $len)
  return ,$out
}

function Test-BytesEqual([byte[]]$a, [byte[]]$b) {
  if ($null -eq $a -and $null -eq $b) { return $true }
  if ($null -eq $a -or $null -eq $b) { return $false }
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($a[$i] -ne $b[$i]) { return $false }
  }
  return $true
}

function Find-Bytes([byte[]]$hay, [byte[]]$needle, [int]$start) {
  if (-not $needle -or $needle.Length -eq 0) { return $start }
  $last = $hay.Length - $needle.Length
  for ($i = $start; $i -le $last; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $needle.Length; $j++) {
      if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break }
    }
    if ($ok) { return $i }
  }
  return -1
}

function Find-LineStart([byte[]]$data, [byte[]]$needle, [int]$start) {
  $pos = $start
  while ($pos -le $data.Length) {
    $i = Find-Bytes $data $needle $pos
    if ($i -lt 0) { return -1 }
    if ($i -eq 0 -or $data[$i - 1] -eq 10) { return $i }
    $pos = $i + 1
  }
  return -1
}

# Строка-метка с `n или `r`n: файл могли пересохранить с CRLF. Ближняя из двух.
# Возвращает @(позиция, длина строки с переводом) или @(-1, 0). Как find_mark в connect.sh.
function Find-Mark([byte[]]$data, [string]$mark, [int]$start) {
  $enc = Get-Utf8
  $best = @(-1, 0)
  foreach ($nl in @("`n", "`r`n")) {
    $needle = $enc.GetBytes($mark + $nl)
    $i = Find-LineStart $data $needle $start
    if ($i -ge 0 -and ($best[0] -lt 0 -or $i -lt $best[0])) { $best = @($i, $needle.Length) }
  }
  return ,$best
}

function Set-OwnerMode([string]$path, [int]$mode) {
  $oct = [Convert]::ToString($mode, 8)
  if (Get-Command chmod -ErrorAction SilentlyContinue) {
    & chmod $oct $path | Out-Null
    return
  }
  if (-not (Test-WindowsOs)) { return }
  # 600-подобный режим: только текущий пользователь. Для 644 ACL не сужаем.
  if (($mode -band 63) -ne 0) { return }
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  & icacls.exe $path /inheritance:r /grant:r "${user}:(R,W)" | Out-Null
}

# Конфиг-симлинк (stow): куда писать — в конечную цель, ссылка остаётся.
# Как realpath в connect.sh. Не ссылка — сам путь.
function Resolve-LinkPath([string]$path) {
  $fi = New-Object IO.FileInfo $path
  if ($fi.PSObject.Methods["ResolveLinkTarget"]) {
    # pwsh 7 (.NET 6+). Битая ссылка тоже даёт цель, файла там может не быть.
    if (-not $fi.LinkTarget) { return $path }
    $t = $fi.ResolveLinkTarget($true)
    if ($t) { return $t.FullName }
    return $path
  }
  # Windows PowerShell 5.1: ResolveLinkTarget нет, идём по Target сами.
  $cur = $path
  for ($i = 0; $i -lt 40; $i++) {
    $item = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne "SymbolicLink") { return $cur }
    $target = @($item.Target)[0]
    if (-not $target) { return $cur }
    if (-not [IO.Path]::IsPathRooted($target)) {
      $target = Join-Path ([IO.Path]::GetDirectoryName($cur)) $target
    }
    $cur = [IO.Path]::GetFullPath($target)
  }
  return $cur
}

function Write-AtomicBytes([string]$path, [byte[]]$data, [int]$mode) {
  $dest = Resolve-LinkPath $path
  $dir = [IO.Path]::GetDirectoryName($dest)
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $tmp = Join-Path $dir (".taskless-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
  [IO.File]::WriteAllBytes($tmp, $data)
  Set-OwnerMode $tmp $mode
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
  Move-Item -LiteralPath $tmp -Destination $dest
}

# Тот же текст, что у connect.sh: файл не трогаем, выход 1.
function Die-OpenBlock([string]$path) {
  Die "В файле $path есть метка начала и нет метки конца. Файл не меняю."
}

function Apply-Block([string]$path, [string]$begin, [string]$end, [byte[]]$inner, [bool]$dry, [int]$mode) {
  $enc = Get-Utf8
  $beginB = $enc.GetBytes($begin + "`n")
  $endB = $enc.GetBytes($end + "`n")
  $body = $inner
  if ($body.Length -gt 0 -and $body[$body.Length - 1] -ne 10) {
    $body = Join-Bytes @($body, $enc.GetBytes("`n"))
  }
  $block = Join-Bytes @($beginB, $body, $endB)
  $exists = Test-Path -LiteralPath $path -PathType Leaf
  $old = $null
  if ($exists) { $old = [IO.File]::ReadAllBytes($path) }
  if ($null -eq $old) {
    $next = $block
  } else {
    $b = Find-Mark $old $begin 0
    $bpos = $b[0]
    if ($bpos -lt 0) {
      $sep = [byte[]]@()
      if ($old.Length -gt 0 -and $old[$old.Length - 1] -ne 10) { $sep = $enc.GetBytes("`n") }
      $next = Join-Bytes @($old, $sep, $block)
    } else {
      $e = Find-Mark $old $end ($bpos + $b[1])
      $epos = $e[0]
      # Без метки конца не знаем, где кончается наш блок: срезали бы чужой хвост.
      if ($epos -lt 0) { Die-OpenBlock $path }
      $tail = Slice-Bytes $old ($epos + $e[1]) ($old.Length - ($epos + $e[1]))
      $next = Join-Bytes @((Slice-Bytes $old 0 $bpos), $block, $tail)
    }
  }
  $changed = ($null -eq $old) -or -not (Test-BytesEqual $old $next)
  $result = @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  if (-not $changed) { return $result }
  $bak = "$path.bak-taskless"
  $backup = ""
  if ($null -ne $old -and -not (Test-Path -LiteralPath $bak)) { $backup = $bak }
  $result.Changed = $true
  $result.Backup = $backup
  $result.Created = ($null -eq $old)
  if ($dry) { return $result }
  if ($backup) {
    $dir = [IO.Path]::GetDirectoryName($path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($bak, $old)
  }
  $fileMode = $mode
  Write-AtomicBytes $path $next $fileMode
  return $result
}

function Remove-Block([string]$path, [string]$begin, [string]$end, [bool]$dry) {
  $result = @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
  $enc = Get-Utf8
  $old = [IO.File]::ReadAllBytes($path)
  $b = Find-Mark $old $begin 0
  $bpos = $b[0]
  if ($bpos -lt 0) { return $result }
  $e = Find-Mark $old $end ($bpos + $b[1])
  $epos = $e[0]
  if ($epos -lt 0) { Die-OpenBlock $path }
  $tail = Slice-Bytes $old ($epos + $e[1]) ($old.Length - ($epos + $e[1]))
  $stripped = Join-Bytes @((Slice-Bytes $old 0 $bpos), $tail)
  $bakPath = "$path.bak-taskless"
  $bak = $null
  if (Test-Path -LiteralPath $bakPath -PathType Leaf) { $bak = [IO.File]::ReadAllBytes($bakPath) }
  $next = $stripped
  if ($null -ne $bak) {
    $same = Test-BytesEqual $stripped $bak
    $withNl = $false
    if (-not $same -and $bak.Length -gt 0 -and $bak[$bak.Length - 1] -ne 10) {
      $withNl = Test-BytesEqual $stripped (Join-Bytes @($bak, $enc.GetBytes("`n")))
    }
    if ($same -or $withNl) { $next = $bak }
  }
  $result.Changed = $true
  # Удаляем, только если файла до нас не было (копии нет). Был пустым — пустым
  # и остаётся, как в connect.sh.
  $result.Deleted = ($next.Length -eq 0 -and $null -eq $bak)
  if ($dry) { return $result }
  if ($result.Deleted) {
    Remove-Item -LiteralPath $path -Force
  } else {
    Write-AtomicBytes $path $next 420
  }
  if ($null -ne $bak -and (Test-BytesEqual $next $bak) -and (Test-Path -LiteralPath $bakPath)) {
    Remove-Item -LiteralPath $bakPath -Force
  }
  return $result
}

function Apply-Stub([string]$id, [bool]$dry) {
  $file = Get-StubFile $id
  $inner = (Get-Utf8).GetBytes("taskless=1`nagent=$id`n")
  return (Apply-Block $file "# >>> taskless:$id" "# <<< taskless:$id" $inner $dry 420)
}

function Remove-Agent([string]$id, [bool]$dry) {
  if (Test-StubWants $id) {
    $file = Get-StubFile $id
    return (Remove-Block $file "# >>> taskless:$id" "# <<< taskless:$id" $dry)
  }
  return @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
}

function Show-Preview([string]$id) {
  $name = Get-AgentName $id
  if (Test-StubWants $id) {
    $edit = Apply-Stub $id $true
    $file = Get-StubFile $id
    if ($edit.Changed) {
      Say "$name`: прописал бы $(Format-Tilde $file)"
      if ($edit.Backup) { Say "  копия конфига: $(Format-Tilde $edit.Backup)" }
    } else {
      Say "$name`: уже прописан, без изменений"
    }
    return
  }
  Say "$name`: адаптер ещё не подключает клиент"
}

function Install-Agent([string]$id) {
  $name = Get-AgentName $id
  if (Test-StubWants $id) {
    $edit = Apply-Stub $id $false
    if ($edit.Changed) {
      Say "$name`: тестовая запись прописана"
      if ($edit.Backup) { Say "  копия конфига: $(Format-Tilde $edit.Backup)" }
    } else {
      Say "$name`: уже прописан"
    }
    return
  }
  Say "$name`: адаптер ещё не подключает клиент"
}

function Show-Manuals([string[]]$found) {
  $n = 1
  $any = $false
  # Макет «Терминал»: сначала шаг Codex, потом перезапуск Claude Code.
  $order = @("codex", "claude-code")
  foreach ($id in $tl.AgentIds) {
    if ($order -notcontains $id) { $order += $id }
  }
  foreach ($id in $order) {
    if ($found -notcontains $id) { continue }
    if (-not (Test-StubWants $id)) { continue }
    if (-not $tl.Manuals.ContainsKey($id)) { continue }
    if (-not $any) { Say "Сделай руками:"; $any = $true }
    Say "  $n. $($tl.Manuals[$id])"
    $n++
  }
}

function Show-Missing([string[]]$missing) {
  if ($missing.Count -gt 0) { Say "Не найдены: $(Format-Names $missing)" }
}

$tl.CredType = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TasklessCred {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct CREDENTIAL {
    public uint Flags;
    public uint Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
  }
  [DllImport("advapi32", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredWrite(ref CREDENTIAL cred, uint flags);
  [DllImport("advapi32", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredRead(string target, uint type, uint flags, out IntPtr cred);
  [DllImport("advapi32", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool CredDelete(string target, uint type, uint flags);
  [DllImport("advapi32")]
  public static extern void CredFree(IntPtr cred);
  public static bool WriteToken(string target, string user, string secret) {
    byte[] bytes = Encoding.UTF8.GetBytes(secret);
    CREDENTIAL cred = new CREDENTIAL();
    cred.Type = 1;
    cred.TargetName = target;
    cred.UserName = user;
    cred.Comment = "Taskless device key";
    cred.Persist = 2;
    cred.CredentialBlobSize = (uint)bytes.Length;
    cred.CredentialBlob = Marshal.AllocHGlobal(bytes.Length);
    try {
      Marshal.Copy(bytes, 0, cred.CredentialBlob, bytes.Length);
      return CredWrite(ref cred, 0);
    } finally {
      Marshal.FreeHGlobal(cred.CredentialBlob);
    }
  }
  public static string ReadToken(string target) {
    IntPtr p;
    if (!CredRead(target, 1, 0, out p) || p == IntPtr.Zero) return null;
    try {
      CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return null;
      byte[] bytes = new byte[cred.CredentialBlobSize];
      Marshal.Copy(cred.CredentialBlob, bytes, 0, (int)cred.CredentialBlobSize);
      return Encoding.UTF8.GetString(bytes);
    } finally {
      CredFree(p);
    }
  }
  public static void DeleteToken(string target) {
    CredDelete(target, 1, 0);
  }
}
"@

function Ensure-CredType {
  if (-not (Test-WindowsOs)) { return $false }
  try {
    if (-not ("TasklessCred" -as [type])) { Add-Type -TypeDefinition $tl.CredType | Out-Null }
    return $true
  } catch {
    return $false
  }
}

function Set-PrivateTree([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (Get-Command chmod -ErrorAction SilentlyContinue) {
    & chmod 700 $dir | Out-Null
  }
}

function Write-SecretFile([string]$path, [string]$content) {
  $dir = [IO.Path]::GetDirectoryName($path)
  Set-PrivateTree $dir
  $bytes = (Get-Utf8).GetBytes($content + "`n")
  Write-AtomicBytes $path $bytes 384
  Set-OwnerMode $path 384
}

function Save-Key([string]$token) {
  $tl.Token = $token
  $forced = $env:TASKLESS_KEY_STORE
  if (-not $forced) { $forced = "auto" }
  if ($forced -ne "file" -and (Ensure-CredType)) {
    try {
      if ([TasklessCred]::WriteToken("taskless-device", "taskless", $token)) {
        $tl.StoreKind = "cred"
        if (Test-Path -LiteralPath $tl.KeyFile) { Remove-Item -LiteralPath $tl.KeyFile -Force }
        return
      }
    } catch {}
  }
  Write-SecretFile $tl.KeyFile $token
  $tl.StoreKind = "file"
}

function Clear-Key {
  if (Ensure-CredType) {
    try { [TasklessCred]::DeleteToken("taskless-device") } catch {}
  }
  if (Test-Path -LiteralPath $tl.KeyFile) { Remove-Item -LiteralPath $tl.KeyFile -Force }
}

function Read-KeyFile {
  if (-not (Test-Path -LiteralPath $tl.KeyFile -PathType Leaf)) { return "" }
  $text = [IO.File]::ReadAllText($tl.KeyFile)
  return ($text -replace "[\r\n]", "")
}

function Load-Key {
  $tl.Token = ""
  $tl.StoreKind = ""
  $forced = $env:TASKLESS_KEY_STORE
  if (-not $forced) { $forced = "auto" }
  if ($forced -eq "file") {
    $got = Read-KeyFile
    if (-not $got) { return $false }
    $tl.Token = $got
    $tl.StoreKind = "file"
    return $true
  }
  if (Ensure-CredType) {
    try {
      $got = [TasklessCred]::ReadToken("taskless-device")
      if ($got) {
        $tl.Token = ($got -replace "[\r\n]", "")
        if ($tl.Token) {
          $tl.StoreKind = "cred"
          return $true
        }
      }
    } catch {}
  }
  $got = Read-KeyFile
  if (-not $got) { return $false }
  $tl.Token = $got
  $tl.StoreKind = "file"
  return $true
}

function Show-KeySaved {
  if ($tl.StoreKind -eq "cred") {
    Say "Вход подтверждён, ключ сохранён в связке ключей."
  } else {
    Say "Вход подтверждён, ключ сохранён в файле ~/.config/taskless/device-key."
  }
}

function Show-KeyStatus {
  switch ($tl.StoreKind) {
    "cred" { Say "Ключ: в связке ключей" }
    "file" { Say "Ключ: в файле ~/.config/taskless/device-key" }
    default { Say "Ключ: нет" }
  }
}

function Get-UnixNow {
  $utc = [DateTime]::UtcNow
  $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
  return [int64]($utc - $epoch).TotalSeconds
}

function Get-ApiBase {
  $base = $env:TASKLESS_URL
  if (-not $base) { $base = "https://taskless.ru/api" }
  $base = $base.TrimEnd("/")
  # http:// только на петле: иначе подменённый TASKLESS_URL ушёл бы на чужой хост.
  # -cmatch, [0-9] и \z — как case в connect.sh: регистр важен, цифры только ASCII,
  # перевод строки в конце не проходит ($ в .NET пропустил бы его).
  if ($base -cmatch "^https://") { return $base }
  if ($base -cmatch "^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/|\z)") { return $base }
  if ($base -cmatch "^http://") {
    Die "TASKLESS_URL с http:// разрешён только для localhost и 127.0.0.1."
  }
  Die "TASKLESS_URL должен начинаться с https://."
}

function Invoke-TasklessApi([string]$method, [string]$url, $payload, [string]$token) {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = $method
  $req.Accept = "application/json"
  $req.Timeout = 30000
  if ($token) { $req.Headers["Authorization"] = "Bearer $token" }
  if ($null -ne $payload) {
    $json = $payload | ConvertTo-Json -Compress -Depth 6
    $bytes = (Get-Utf8).GetBytes($json)
    $req.ContentType = "application/json"
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
  }
  $resp = $null
  try {
    $resp = $req.GetResponse()
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) {
      $resp = $_.Exception.Response
    } else {
      return @{ Status = 0; Retry = ""; Net = $_.Exception.Message; Json = $null }
    }
  }
  $status = [int]$resp.StatusCode
  $retry = ""
  try { $retry = [string]$resp.Headers["Retry-After"] } catch { $retry = "" }
  $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
  $text = $reader.ReadToEnd()
  $reader.Close()
  $resp.Close()
  $parsed = $null
  if ($text) {
    try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null }
  }
  return @{ Status = $status; Retry = $retry; Net = ""; Json = $parsed }
}

function Get-JsonField($json, [string]$name) {
  if ($null -eq $json) { return "" }
  $prop = $json.PSObject.Properties[$name]
  if (-not $prop) { return "" }
  if ($null -eq $prop.Value) { return "" }
  return [string]$prop.Value
}

function New-DevicePayload([string[]]$agents) {
  $payload = @{
    client_id      = $tl.ClientId
    device_name    = (Get-DeviceName)
    agents         = @($agents)
    client_version = $tl.ClientVersion
  }
  $platform = Get-PlatformName
  if ($platform -in @("macos", "linux", "windows")) { $payload.platform = $platform }
  $osVer = Get-OsVersion
  if ($osVer) { $payload.os_version = $osVer }
  return $payload
}

# 0 жив, 1 не принят, 2 не спросили.
function Test-KeyLive {
  $res = Invoke-TasklessApi "GET" ((Get-ApiBase) + "/auth/me") $null $tl.Token
  if ($res.Status -eq 0) { return 2 }
  if ($res.Status -in 200, 201, 204) { return 0 }
  if ($res.Status -in 401, 403) { return 1 }
  return 2
}

function Open-Browser([string]$url) {
  if ($env:TASKLESS_BROWSER) {
    try { & $env:TASKLESS_BROWSER $url | Out-Null } catch {}
    return
  }
  try {
    if (Test-WindowsOs) { Start-Process $url | Out-Null; return }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) { & open $url | Out-Null; return }
    if (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $url | Out-Null }
  } catch {}
}

function Invoke-DeviceLogin([string[]]$found) {
  $res = Invoke-TasklessApi "POST" ((Get-ApiBase) + "/oauth/device_authorization") (New-DevicePayload $found) ""
  if ($res.Status -ne 200) {
    $err = Get-JsonField $res.Json "error"
    if (-not $err) { $err = $res.Net }
    Die "Не получил код подключения (HTTP $($res.Status)). $err"
  }
  $userCode = Get-JsonField $res.Json "user_code"
  $deviceCode = Get-JsonField $res.Json "device_code"
  if (-not $userCode -or -not $deviceCode) { Die "Не получил код подключения (HTTP $($res.Status))." }
  $uri = Get-JsonField $res.Json "verification_uri_complete"
  if (-not $uri) { $uri = "https://taskless.ru/connect?code=$userCode" }
  $interval = 5
  $intervalRaw = Get-JsonField $res.Json "interval"
  if ($intervalRaw -match "^\d+$") { $interval = [int]$intervalRaw }
  $expires = 600
  $expiresRaw = Get-JsonField $res.Json "expires_in"
  if ($expiresRaw -match "^\d+$") { $expires = [int]$expiresRaw }
  $deadline = (Get-UnixNow) + $expires
  Say "Код подключения: $userCode"
  Say "Открываю браузер: $uri"
  Say "Если браузер не открылся, открой ссылку сам. Код живёт 10 минут."
  Say "Жду подтверждения в браузере…"
  Open-Browser $uri
  # continue внутри switch выходит только из switch, не из while.
  # Без метки authorization_pending и slow_down падают в «HTTP 400».
  :poll while ($true) {
    if ((Get-UnixNow) -ge $deadline) {
      Die "Код устарел. Запусти установщик ещё раз."
    }
    if ($interval -gt 0) { Start-Sleep -Seconds $interval }
    $body = @{
      grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
      device_code = $deviceCode
      client_id   = $tl.ClientId
    }
    $poll = Invoke-TasklessApi "POST" ((Get-ApiBase) + "/oauth/token") $body ""
    if ($poll.Status -eq 200) {
      $token = Get-JsonField $poll.Json "access_token"
      if (-not $token) { Die "Сервер не отдал ключ." }
      $tl.Token = $token
      return
    }
    if ($poll.Status -eq 400) {
      $err = Get-JsonField $poll.Json "error"
      switch ($err) {
        "authorization_pending" { continue poll }
        "slow_down" {
          $interval += 5
          if ($interval -gt 60) { $interval = 60 }
          continue poll
        }
        "access_denied" { Die "Вход отклонён. Ключ не сохранён." }
        "expired_token" { Die "Код устарел. Запусти установщик ещё раз." }
        "invalid_grant" { Die "Код не принят. Запусти установщик ещё раз." }
        default {
          if (-not $err) { $err = "неизвестная ошибка" }
          Die "Не получилось войти: $err"
        }
      }
    }
    if ($poll.Status -eq 429) {
      $wait = 5
      if ($poll.Retry -match "^\d+$") { $wait = [int]$poll.Retry }
      Start-Sleep -Seconds $wait
      continue
    }
    if ($poll.Status -eq 0) { Die "Не достучался до Taskless: $($poll.Net)" }
    Die "Не получилось войти (HTTP $($poll.Status))."
  }
}

function Confirm-Token([string[]]$found) {
  if (Load-Key) {
    $live = Test-KeyLive
    if ($live -eq 0) {
      Say "Ключ уже есть, вход не прошу."
      return
    }
    if ($live -eq 1) {
      Clear-Key
      $tl.Token = ""
    } else {
      Die "Не смог проверить ключ. Не достучался до Taskless."
    }
  }
  Invoke-DeviceLogin $found
  Say ""
  Save-Key $tl.Token
  Show-KeySaved
}

function Save-Meta([string[]]$connected) {
  $dir = $tl.ConfigDir
  Set-PrivateTree $dir
  $obj = @{
    device_name = (Get-DeviceName)
    platform    = (Get-PlatformName)
    store       = $tl.StoreKind
    agents      = @($connected)
  }
  $json = ($obj | ConvertTo-Json -Depth 4) + "`n"
  Write-AtomicBytes $tl.MetaFile ((Get-Utf8).GetBytes($json)) 384
}

function Read-Meta {
  if (-not (Test-Path -LiteralPath $tl.MetaFile -PathType Leaf)) { return $null }
  try { return ([IO.File]::ReadAllText($tl.MetaFile) | ConvertFrom-Json) } catch { return $null }
}

function Test-AgentConnected([string]$id) {
  if (-not (Test-StubWants $id)) { return $false }
  $file = Get-StubFile $id
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($file)
  return $text.Contains("# >>> taskless:$id")
}

function Invoke-Install([string[]]$found, [string[]]$missing) {
  Say "Taskless: подключение агентов"
  Say ""
  if ($tl.Dry) { Say "Только показ: ничего не меняю." }
  Say "Нашёл: $(Format-Names $found)"
  if ($tl.Dry) {
    if (Load-Key) { Say "Ключ уже есть, вход не прошу." }
    else { Say "Ключ: попросит вход по коду" }
    foreach ($id in $found) { Show-Preview $id }
    Say ""
    Show-Manuals $found
    Show-Missing $missing
    return 0
  }
  Confirm-Token $found
  Say ""
  foreach ($id in $found) { Install-Agent $id }
  Say ""
  Say "Подключены: $(Format-Names $found)"
  Show-Manuals $found
  Show-Missing $missing
  Save-Meta $found
  return 0
}

function Invoke-Status([string[]]$searched) {
  Say "Taskless: подключение агентов"
  Say ""
  $meta = Read-Meta
  $device = ""
  if ($meta) { $device = [string]$meta.device_name }
  if ($device) { Say "Устройство: $device" } else { Say "Устройство: нет" }
  if (Load-Key) {
    Show-KeyStatus
    $live = Test-KeyLive
    if ($live -eq 0) { Say "Ключ жив." }
    elseif ($live -eq 1) { Say "Ключ не принят, запусти подключение ещё раз." }
    else { Say "Не смог проверить ключ." }
  } else {
    Say "Ключ: нет"
  }
  foreach ($id in $searched) {
    $name = Get-AgentName $id
    if (Test-AgentConnected $id) { Say "$name`: подключён" }
    elseif (Test-AgentFound $id) { Say "$name`: найден, не подключён" }
    else { Say "$name`: не найден" }
  }
  return 0
}

function Invoke-Uninstall([string[]]$searched) {
  Say "Taskless: подключение агентов"
  Say ""
  if ($tl.Dry) { Say "Только показ: ничего не меняю." }
  Say "Снимаю поставленное."
  foreach ($id in $searched) {
    $edit = Remove-Agent $id $tl.Dry
    if ($edit.Changed) {
      $name = Get-AgentName $id
      if ($tl.Dry) { Say "$name`: снял бы" } else { Say "$name`: снято" }
    }
  }
  if (Load-Key) {
    if ($tl.Dry) {
      Say "Ключ: отозвал бы."
      return 0
    }
    $body = @{ token = $tl.Token; client_id = $tl.ClientId }
    $res = Invoke-TasklessApi "POST" ((Get-ApiBase) + "/oauth/revoke") $body ""
    if ($res.Status -eq 200) {
      Clear-Key
      if (Test-Path -LiteralPath $tl.MetaFile) { Remove-Item -LiteralPath $tl.MetaFile -Force }
      Say "Ключ отозван."
      return 0
    }
    Say "Не получилось отозвать ключ (HTTP $($res.Status)). Ключ на диске оставил, запусти снятие ещё раз."
    return 1
  }
  if (Test-Path -LiteralPath $tl.MetaFile) { Remove-Item -LiteralPath $tl.MetaFile -Force }
  Say "Ключа в связке не было."
  return 0
}

function Main {
  $homeDir = Get-HomeDir
  if (-not $homeDir) { Die "Нет HOME, некуда положить ключ." }
  $tl.ConfigDir = Join-Path (Join-Path $homeDir ".config") "taskless"
  $tl.KeyFile = Join-Path $tl.ConfigDir "device-key"
  $tl.MetaFile = Join-Path $tl.ConfigDir "device.json"
  Read-Args $tl.LaunchArgs
  if ($tl.DidHelp) { return 0 }
  # Адрес — до всего остального, как require_base в connect.sh: --dry-run
  # и --status с чужим http:// тоже отказывают.
  $null = Get-ApiBase
  $found = @()
  $missing = @()
  $searched = @()
  foreach ($id in $tl.AgentIds) {
    if (-not (Test-WantId $id)) { continue }
    $searched += $id
    if (Test-AgentFound $id) { $found += $id } else { $missing += $id }
  }
  if ($tl.DoStatus) { return (Invoke-Status $searched) }
  if ($tl.DoUninstall) { return (Invoke-Uninstall $searched) }
  if ($found.Count -eq 0) {
    Say "Taskless: подключение агентов"
    Say ""
    Say "агентов не нашёл"
    Say "Искал: $(Format-Names $searched)"
    return 0
  }
  return (Invoke-Install $found $missing)
}

$tl.ExitCode = 1
try {
  $tl.ExitCode = Main
} catch {
  if ($_.Exception.Message -ne "taskless-die") {
    Say $_.Exception.Message
  }
  $tl.ExitCode = 1
}
if ($PSCommandPath) { exit $tl.ExitCode }
if ($tl.HadLastExit) {
  $global:LASTEXITCODE = $tl.LastExit
} else {
  Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
}
} @args
