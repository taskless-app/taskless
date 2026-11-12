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
# Адаптер — найти / прописать / снять. TOML и скрипты правятся блоком
# `# >>> taskless:<id>` … `# <<< taskless:<id>`, ~/.claude.json — по ключу
# mcpServers.taskless; до первой правки копия *.bak-taskless.
# Подключены Claude Code и Codex (MCP-105), остальные — MCP-106 и позже.
# Заглушка тестов TASKLESS_CONNECT_STUB=1 по-прежнему работает.
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
$tl.MemorySet = ""
$tl.ImportFile = ""
$tl.MemoryDirs = @()
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
  powershell -NoProfile -File connect.ps1 --memory-dir ~/notes    также найти память в своей папке
  powershell -NoProfile -File connect.ps1 --memory on|off         включить или выключить личную память
  powershell -NoProfile -File connect.ps1 --import-memory <файл>  отправить согласованные записи
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
      "--memory" {
        $i++
        if ($i -ge $argv.Count) { Die "После --memory нужно on или off." }
        $tl.MemorySet = [string]$argv[$i]
      }
      "--import-memory" {
        $i++
        if ($i -ge $argv.Count) { Die "После --import-memory нужен JSON-файл." }
        $tl.ImportFile = [string]$argv[$i]
      }
      "--memory-dir" {
        $i++
        if ($i -ge $argv.Count) { Die "После --memory-dir нужен путь." }
        $tl.MemoryDirs += [string]$argv[$i]
      }
      "-h" { Show-Usage; $tl.DidHelp = $true }
      "--help" { Show-Usage; $tl.DidHelp = $true }
      default {
        if ($a.StartsWith("--only=")) { Set-OnlyList $a.Substring(7) }
        elseif ($a.StartsWith("--memory=")) {
          $tl.MemorySet = $a.Substring(9)
          if (-not $tl.MemorySet) { Die "После --memory нужно on или off." }
        }
        elseif ($a.StartsWith("--import-memory=")) {
          $tl.ImportFile = $a.Substring(16)
          if (-not $tl.ImportFile) { Die "После --import-memory нужен JSON-файл." }
        }
        elseif ($a.StartsWith("--memory-dir=")) {
          $dir = $a.Substring(13)
          if (-not $dir) { Die "После --memory-dir нужен путь." }
          $tl.MemoryDirs += $dir
        }
        else { Die "Не знаю аргумент: $a" }
      }
    }
    $i++
  }
  if ($tl.DoStatus -and $tl.DoUninstall) { Die "Укажи что-то одно: --status или --uninstall." }
  if ($tl.DoStatus -and $tl.Dry) { Die "--status ничего не меняет и без --dry-run." }
  if ($tl.MemorySet -and $tl.MemorySet -notin @("on", "off")) { Die "После --memory нужно on или off." }
  if ($tl.MemorySet -and $tl.ImportFile) { Die "Укажи что-то одно: --memory или --import-memory." }
  if (($tl.MemorySet -or $tl.ImportFile) -and ($tl.DoStatus -or $tl.DoUninstall)) {
    Die "Ключи личной памяти не совмещаются с --status и --uninstall."
  }
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
  if (Test-StubWants $id) { return $true }
  $homeDir = Get-HomeDir
  switch ($id) {
    "claude-code" {
      return [bool](Get-Command claude -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $homeDir ".claude.json") -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $homeDir ".claude") -PathType Container)
    }
    "codex" {
      return [bool](Get-Command codex -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $homeDir ".codex/config.toml") -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $homeDir ".codex") -PathType Container)
    }
    default { return $false }
  }
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

# Строка-метка с `n, `r`n или в конце файла без перевода. Ближняя из трёх.
# Возвращает @(позиция, длина строки с переводом) или @(-1, 0). Как find_mark в connect.sh.
function Find-Mark([byte[]]$data, [string]$mark, [int]$start) {
  $enc = Get-Utf8
  $best = @(-1, 0)
  foreach ($nl in @("`n", "`r`n")) {
    $needle = $enc.GetBytes($mark + $nl)
    $i = Find-LineStart $data $needle $start
    if ($i -ge 0 -and ($best[0] -lt 0 -or $i -lt $best[0])) { $best = @($i, $needle.Length) }
  }
  $needle = $enc.GetBytes($mark)
  $i = Find-LineStart $data $needle $start
  if ($i -ge 0 -and $i + $needle.Length -eq $data.Length -and ($best[0] -lt 0 -or $i -lt $best[0])) {
    $best = @($i, $needle.Length)
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

function Get-UnixModeOrNull([string]$path) {
  if (Test-WindowsOs) { return $null }
  if (-not [IO.File].GetMethod("GetUnixFileMode", [type[]]@([string]))) { return $null }
  return [int][IO.File]::GetUnixFileMode($path)
}

function Set-UnixModeIfPossible([string]$path, [int]$mode) {
  if (Test-WindowsOs) { return }
  $getMethod = [IO.File].GetMethod("GetUnixFileMode", [type[]]@([string]))
  if (-not $getMethod) { return }
  $setMethod = [IO.File].GetMethod("SetUnixFileMode", [type[]]@([string], $getMethod.ReturnType))
  if ($setMethod) { [IO.File]::SetUnixFileMode($path, $mode) }
}

function Write-AtomicBytes([string]$path, [byte[]]$data, [int]$mode) {
  $dest = Resolve-LinkPath $path
  $destExists = Test-Path -LiteralPath $dest
  $existingMode = $null
  $readOnly = $false
  if ($destExists) {
    if (Test-WindowsOs) {
      $readOnly = (([IO.File]::GetAttributes($dest) -band [IO.FileAttributes]::ReadOnly) -ne 0)
    } else {
      $existingMode = Get-UnixModeOrNull $dest
    }
  }
  $dir = [IO.Path]::GetDirectoryName($dest)
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $tmp = Join-Path $dir (".taskless-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
  [IO.File]::WriteAllBytes($tmp, $data)
  if ($null -ne $existingMode) { Set-UnixModeIfPossible $tmp $existingMode }
  else { Set-OwnerMode $tmp $mode }
  if ($destExists) { Remove-Item -LiteralPath $dest -Force }
  Move-Item -LiteralPath $tmp -Destination $dest
  if ($readOnly) {
    [IO.File]::SetAttributes($dest, ([IO.File]::GetAttributes($dest) -bor [IO.FileAttributes]::ReadOnly))
  }
}

# Тот же текст, что у connect.sh: файл не трогаем, выход 1.
function Die-OpenBlock([string]$path) {
  Die "В файле $path есть метка начала и нет метки конца. Файл не меняю."
}

function Normalize-TomlKey([string]$raw) {
  $key = [regex]::Replace($raw.Trim(), '[ \t]+', '')
  return $key.Replace('"taskless"', 'taskless').Replace("'taskless'", 'taskless')
}

function Get-TasklessTomlKind([string]$key) {
  if ($key -eq "mcp_servers.taskless" -or $key.StartsWith("mcp_servers.taskless.")) { return "mcp" }
  $plugin = 'plugins."taskless@taskless-app".mcp_servers.taskless'
  if ($key -eq $plugin -or $key.StartsWith($plugin + ".")) { return "plugin" }
  return $null
}

function Get-TomlHeader([string]$line) {
  $array = [regex]::Match($line, '^[ \t]*\[\[([^\[\]]+)\]\][ \t]*(?:#.*)?\r?\n?$')
  if ($array.Success) { return "[]" + (Normalize-TomlKey $array.Groups[1].Value) }
  $match = [regex]::Match($line, '^[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?\r?\n?$')
  if (-not $match.Success) { return $null }
  return Normalize-TomlKey $match.Groups[1].Value
}

function Get-TasklessTomlMask([byte[]]$data) {
  $out = [byte[]]$data.Clone()
  $state = ""
  $i = 0
  while ($i -lt $data.Length) {
    $char = $data[$i]
    if ($state -eq "basic" -or $state -eq "literal") {
      if ($state -eq "basic" -and $char -eq 92) {
        $i += 2
        continue
      }
      if ($char -eq $(if ($state -eq "basic") { 34 } else { 39 }) -or $char -eq 10) { $state = "" }
      $i++
      continue
    }
    if ($state -eq "basic3" -or $state -eq "literal3") {
      $quote = if ($state -eq "basic3") { 34 } else { 39 }
      if ($i + 2 -lt $data.Length -and $char -eq $quote -and $data[$i + 1] -eq $quote -and $data[$i + 2] -eq $quote) {
        $state = ""
        $i += 3
        continue
      }
      if ($state -eq "basic3" -and $char -eq 92) {
        $out[$i] = 32
        if ($i + 1 -lt $data.Length -and $data[$i + 1] -ne 10 -and $data[$i + 1] -ne 13) { $out[$i + 1] = 32 }
        $i += 2
        continue
      }
      if ($char -ne 10 -and $char -ne 13) { $out[$i] = 32 }
      $i++
      continue
    }
    if ($char -eq 35) {
      while ($i -lt $data.Length -and $data[$i] -ne 10) { $i++ }
      continue
    }
    if ($char -eq 34 -or $char -eq 39) {
      if ($i + 2 -lt $data.Length -and $data[$i + 1] -eq $char -and $data[$i + 2] -eq $char) {
        $state = if ($char -eq 34) { "basic3" } else { "literal3" }
        $i += 3
      } else {
        $state = if ($char -eq 34) { "basic" } else { "literal" }
        $i++
      }
      continue
    }
    $i++
  }
  return [pscustomobject]@{ Masked = $out; Open = $state }
}

function Get-TasklessTomlAssignmentEnd([byte[]]$masked, [int]$pos, [int]$nextPos) {
  $balance = 0
  $scan = $pos
  $first = $true
  while ($scan -lt $masked.Length) {
    $line = (Get-Utf8).GetString($masked, $scan, $nextPos - $scan)
    $eq = if ($first) { $line.IndexOf("=") } else { -1 }
    $rhs = if ($eq -ge 0) { $line.Substring($eq + 1) } else { $line }
    $rhs = [regex]::Replace($rhs, '"(?:\\.|[^"\\])*"|''[^'']*''', '')
    $rhs = ($rhs -split '#', 2)[0]
    $balance += [regex]::Matches($rhs, '[\[\{]').Count
    $balance -= [regex]::Matches($rhs, '[\]\}]').Count
    if ($balance -le 0) { return $nextPos }
    $first = $false
    $scan = $nextPos
    $nl = $scan
    while ($nl -lt $masked.Length -and $masked[$nl] -ne 10) { $nl++ }
    $nextPos = if ($nl -lt $masked.Length) { $nl + 1 } else { $nl }
  }
  return $masked.Length
}

function Find-TasklessTomlRanges([byte[]]$data) {
  $masked = (Get-TasklessTomlMask $data).Masked
  $ranges = @()
  $section = ""
  $pos = 0
  while ($pos -lt $data.Length) {
    $nl = $pos
    while ($nl -lt $data.Length -and $data[$nl] -ne 10) { $nl++ }
    $nextPos = if ($nl -lt $data.Length) { $nl + 1 } else { $nl }
    $line = (Get-Utf8).GetString($masked, $pos, $nextPos - $pos)
    $header = Get-TomlHeader $line
    if ($null -ne $header) {
      $section = $header
      $kind = Get-TasklessTomlKind $section
      if ($null -ne $kind) {
        $start = $pos
        $end = $data.Length
        $scan = $nextPos
        while ($scan -lt $data.Length) {
          $scanNl = $scan
          while ($scanNl -lt $data.Length -and $data[$scanNl] -ne 10) { $scanNl++ }
          $scanNext = if ($scanNl -lt $data.Length) { $scanNl + 1 } else { $scanNl }
          $nextHeader = Get-TomlHeader ((Get-Utf8).GetString($masked, $scan, $scanNext - $scan))
          if ($null -ne $nextHeader -and -not $nextHeader.StartsWith($section + ".")) {
            $end = $scan
            break
          }
          $scan = $scanNext
        }
        $ranges += [pscustomobject]@{ Start = $start; End = $end; Kind = $kind }
        $pos = $end
        continue
      }
    } else {
      $eq = $line.IndexOf("=")
      if ($eq -ge 0) {
        $left = Normalize-TomlKey $line.Substring(0, $eq)
        $full = $(if ($section) { $section + "." } else { "" }) + $left
        $kind = Get-TasklessTomlKind $full
        if ($null -ne $kind) {
          $end = Get-TasklessTomlAssignmentEnd $masked $pos $nextPos
          $ranges += [pscustomobject]@{ Start = $pos; End = $end; Kind = $kind }
          $pos = $end
          continue
        }
      }
    }
    $pos = $nextPos
  }
  return ,$ranges
}

function Remove-TasklessTomlRanges([byte[]]$data, $ranges) {
  $out = [byte[]]@()
  $pos = 0
  foreach ($range in @($ranges | Sort-Object Start)) {
    $out = Join-Bytes @($out, (Slice-Bytes $data $pos ($range.Start - $pos)))
    $pos = $range.End
  }
  return ,(Join-Bytes @($out, (Slice-Bytes $data $pos ($data.Length - $pos))))
}

function Get-TasklessTomlRestoreAnchor([byte[]]$bak, [int]$pos, $ranges) {
  $masked = (Get-TasklessTomlMask $bak).Masked
  while ($pos -lt $bak.Length) {
    $inside = @($ranges | Where-Object { $_.Start -le $pos -and $pos -lt $_.End } | Select-Object -First 1)
    if ($inside.Count -gt 0) {
      $pos = $inside[0].End
      continue
    }
    $nl = $pos
    while ($nl -lt $bak.Length -and $bak[$nl] -ne 10) { $nl++ }
    $nextPos = if ($nl -lt $bak.Length) { $nl + 1 } else { $nl }
    $header = Get-TomlHeader ((Get-Utf8).GetString($masked, $pos, $nextPos - $pos))
    if ($null -ne $header) { return $header }
    $pos = $nextPos
  }
  return $null
}

function Find-TomlHeader([byte[]]$data, [string]$wanted) {
  $masked = (Get-TasklessTomlMask $data).Masked
  $pos = 0
  while ($pos -lt $data.Length) {
    $nl = $pos
    while ($nl -lt $data.Length -and $data[$nl] -ne 10) { $nl++ }
    $nextPos = if ($nl -lt $data.Length) { $nl + 1 } else { $nl }
    $header = Get-TomlHeader ((Get-Utf8).GetString($masked, $pos, $nextPos - $pos))
    if ($header -eq $wanted) { return $pos }
    $pos = $nextPos
  }
  return $data.Length
}

function Restore-TasklessTomlRanges([byte[]]$stripped, [byte[]]$bak, $ranges) {
  $base = Remove-TasklessTomlRanges $bak $ranges
  $same = Test-BytesEqual $stripped $base
  $withNl = $false
  if (-not $same -and $base.Length -gt 0 -and $base[$base.Length - 1] -ne 10) {
    $withNl = Test-BytesEqual $stripped (Join-Bytes @($base, (Get-Utf8).GetBytes("`n")))
  }
  if ($same -or $withNl) { return ,$bak }
  $new = $stripped
  foreach ($range in @($ranges | Sort-Object Start)) {
    $anchor = Get-TasklessTomlRestoreAnchor $bak $range.End $ranges
    $at = if ($null -eq $anchor) { $new.Length } else { Find-TomlHeader $new $anchor }
    if ($null -ne $anchor -and $at -eq $new.Length) {
      $label = if ($anchor.StartsWith("[]")) { "[[" + $anchor.Substring(2) + "]]" } else { $anchor }
      [Console]::Error.WriteLine("Предупреждение: заголовок $label не найден, восстанавливаю taskless в конец TOML.")
    }
    $sep = [byte[]]@()
    if ($at -gt 0 -and $new[$at - 1] -ne 10) {
      $nl = if ((Get-Utf8).GetString($new).Contains("`r`n")) { "`r`n" } else { "`n" }
      $sep = (Get-Utf8).GetBytes($nl)
    }
    $new = Join-Bytes @((Slice-Bytes $new 0 $at), $sep, (Slice-Bytes $bak $range.Start ($range.End - $range.Start)), (Slice-Bytes $new $at ($new.Length - $at)))
  }
  return ,$new
}

function Assert-TasklessToml([string]$path, [byte[]]$data, [bool]$installed = $true) {
  if ($null -eq $data -or $data.Length -eq 0) { return }
  $scan = Get-TasklessTomlMask $data
  if ($scan.Open) { Die "Не смог разобрать итоговый TOML ${path}: незакрытая строка. Файл не меняю." }
  if (-not $installed) { return }
  $mcp = 0
  $plugin = 0
  foreach ($range in @(Find-TasklessTomlRanges $data)) {
    if ($range.Kind -eq "mcp") { $mcp++ }
    if ($range.Kind -eq "plugin") { $plugin++ }
  }
  $rootInline = $false
  $pos = 0
  while ($pos -lt $scan.Masked.Length) {
    $nl = $pos
    while ($nl -lt $scan.Masked.Length -and $scan.Masked[$nl] -ne 10) { $nl++ }
    $nextPos = if ($nl -lt $scan.Masked.Length) { $nl + 1 } else { $nl }
    $line = (Get-Utf8).GetString($scan.Masked, $pos, $nextPos - $pos)
    if ($null -ne (Get-TomlHeader $line)) { break }
    if ([regex]::IsMatch($line, '^[ \t]*mcp_servers[ \t]*=[ \t]*\{')) {
      $rootInline = $true
      break
    }
    $pos = $nextPos
  }
  if ($mcp -ne 1 -or $plugin -ne 1 -or $rootInline) { Die "В итоговом TOML $path дублируется taskless. Файл не меняю." }
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
  $exists = Test-Path -LiteralPath (Resolve-LinkPath $path) -PathType Leaf
  $old = $null
  if ($exists) { $old = [IO.File]::ReadAllBytes($path) }
  if ($null -eq $old) {
    $next = $block
  } else {
    $b = Find-Mark $old $begin 0
    $bpos = $b[0]
    if ($bpos -lt 0) {
      $ranges = if ($begin -eq "# >>> taskless:codex") { Find-TasklessTomlRanges $old } else { @() }
      $base = if ($ranges.Count -gt 0) { Remove-TasklessTomlRanges $old $ranges } else { $old }
      $sep = [byte[]]@()
      if ($base.Length -gt 0 -and $base[$base.Length - 1] -ne 10) { $sep = $enc.GetBytes("`n") }
      $next = Join-Bytes @($base, $sep, $block)
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
  if ($begin -eq "# >>> taskless:codex" -and (Get-Utf8).GetString($inner).Contains("[mcp_servers.taskless]")) { Assert-TasklessToml $path $next }
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
    if (-not (Test-WindowsOs)) {
      $configMode = Get-UnixModeOrNull $path
      if ($null -ne $configMode) { Set-UnixModeIfPossible $bak $configMode }
      else { Set-OwnerMode $bak 384 }
    }
  }
  $fileMode = $mode
  Write-AtomicBytes $path $next $fileMode
  return $result
}

function Remove-Block([string]$path, [string]$begin, [string]$end, [bool]$dry) {
  $result = @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  if (-not (Test-Path -LiteralPath (Resolve-LinkPath $path) -PathType Leaf)) { return $result }
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
  $original = if ($null -ne $bak -and $begin -eq "# >>> taskless:codex") { Find-TasklessTomlRanges $bak } else { @() }
  $next = $stripped
  if ($original.Count -gt 0) { $next = Restore-TasklessTomlRanges $stripped $bak $original }
  if ($null -ne $bak) {
    $same = Test-BytesEqual $stripped $bak
    $withNl = $false
    if (-not $same -and $bak.Length -gt 0 -and $bak[$bak.Length - 1] -ne 10) {
      $withNl = Test-BytesEqual $stripped (Join-Bytes @($bak, $enc.GetBytes("`n")))
    }
    if ($same -or $withNl) { $next = $bak }
  }
  if ($begin -eq "# >>> taskless:codex") { Assert-TasklessToml $path $next $false }
  $result.Changed = $true
  # Удаляем, только если файла до нас не было (копии нет). Был пустым — пустым
  # и остаётся, как в connect.sh.
  $result.Deleted = ($next.Length -eq 0 -and $null -eq $bak)
  if ($dry) { return $result }
  if ($result.Deleted) {
    Remove-Item -LiteralPath (Resolve-LinkPath $path) -Force
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

function Read-JsonConfig([string]$path) {
  if (-not (Test-Path -LiteralPath (Resolve-LinkPath $path) -PathType Leaf)) {
    return @{ Raw = $null; Data = [ordered]@{} }
  }
  $raw = [IO.File]::ReadAllBytes($path)
  $text = (Get-Utf8).GetString($raw)
  if ([string]::IsNullOrWhiteSpace($text)) {
    return @{ Raw = $raw; Data = [ordered]@{} }
  }
  try { $data = $text | ConvertFrom-Json } catch { Die "Не смог разобрать JSON $path. Файл не меняю." }
  if ($data -isnot [pscustomobject]) { Die "В JSON $path жду объект в корне. Файл не меняю." }
  return @{ Raw = $raw; Data = $data }
}

function Get-JsonProperty($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $prop = $obj.PSObject.Properties[$name]
  if ($null -eq $prop) { return $null }
  return ,($prop.Value)
}

function Test-JsonProperty($obj, [string]$name) {
  return $null -ne $obj -and $null -ne $obj.PSObject.Properties[$name]
}

function Set-JsonProperty($obj, [string]$name, $value) {
  $prop = $obj.PSObject.Properties[$name]
  if ($prop) { $prop.Value = $value }
  else { $obj | Add-Member -MemberType NoteProperty -Name $name -Value $value }
}

function Remove-JsonProperty($obj, [string]$name) {
  $obj.PSObject.Properties.Remove($name)
}

function ConvertTo-JsonBytes($data) {
  return (Get-Utf8).GetBytes(($data | ConvertTo-Json -Depth 100) + "`n")
}

function Test-JsonSame($a, $b) {
  if ($null -eq $a -and $null -eq $b) { return $true }
  if ($null -eq $a -or $null -eq $b) { return $false }
  return ($a | ConvertTo-Json -Depth 100 -Compress) -ceq ($b | ConvertTo-Json -Depth 100 -Compress)
}

function Get-HeaderHelperPath {
  return Join-Path $tl.ConfigDir "mcp-headers.ps1"
}

function Get-HeaderCommand {
  $shell = if (Test-WindowsOs) { "powershell" } else { "pwsh" }
  return "$shell -NoProfile -ExecutionPolicy Bypass -File `"$(Get-HeaderHelperPath)`""
}

function Get-TasklessServer {
  return [ordered]@{
    type = "http"
    url = (Get-ApiBase) + "/mcp"
    headersHelper = (Get-HeaderCommand)
  }
}

function Test-TasklessServerOwned($server) {
  $helper = Get-JsonProperty $server "headersHelper"
  return $helper -is [string] -and $helper.Contains((Get-HeaderHelperPath))
}

function Apply-ClaudeJson([bool]$dry) {
  $path = Join-Path (Get-HomeDir) ".claude.json"
  $read = Read-JsonConfig $path
  $data = $read.Data
  $servers = Get-JsonProperty $data "mcpServers"
  if ($null -eq $servers) {
    $servers = [pscustomobject]@{}
    Set-JsonProperty $data "mcpServers" $servers
  }
  if ($servers -isnot [pscustomobject] -and $servers -isnot [Collections.Specialized.OrderedDictionary]) {
    Die "В JSON $path ключ mcpServers не объект. Файл не меняю."
  }
  $wanted = Get-TasklessServer
  if (Test-JsonSame (Get-JsonProperty $servers "taskless") $wanted) {
    return @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  }
  Set-JsonProperty $servers "taskless" $wanted
  $bak = "$path.bak-taskless"
  $backup = if ($null -ne $read.Raw -and -not (Test-Path -LiteralPath $bak)) { $bak } else { "" }
  $result = @{ Changed = $true; Backup = $backup; Created = ($null -eq $read.Raw); Deleted = $false }
  if ($dry) { return $result }
  if ($backup) {
    $dir = [IO.Path]::GetDirectoryName($path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($bak, $read.Raw)
    if (-not (Test-WindowsOs)) {
      $configMode = Get-UnixModeOrNull $path
      if ($null -ne $configMode) { Set-UnixModeIfPossible $bak $configMode }
      else { Set-OwnerMode $bak 384 }
    }
  }
  Write-AtomicBytes $path (ConvertTo-JsonBytes $data) 420
  return $result
}

function Remove-ClaudeJson([bool]$dry) {
  $path = Join-Path (Get-HomeDir) ".claude.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  }
  $read = Read-JsonConfig $path
  $data = $read.Data
  $servers = Get-JsonProperty $data "mcpServers"
  if ($null -eq $servers -or -not (Test-TasklessServerOwned (Get-JsonProperty $servers "taskless"))) {
    return @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  }
  $bakPath = "$path.bak-taskless"
  $hasBackup = Test-Path -LiteralPath $bakPath -PathType Leaf
  $bakRead = $null
  if ($hasBackup) { $bakRead = Read-JsonConfig $bakPath }
  Remove-JsonProperty $servers "taskless"
  $bakServers = if ($hasBackup) { Get-JsonProperty $bakRead.Data "mcpServers" } else { $null }
  if ($bakServers -and (Test-JsonProperty $bakServers "taskless")) {
    Set-JsonProperty $servers "taskless" (Get-JsonProperty $bakServers "taskless")
  }
  $backupHasServers = $hasBackup -and (Test-JsonProperty $bakRead.Data "mcpServers")
  if (@($servers.PSObject.Properties).Count -eq 0 -and (-not $backupHasServers -or @($bakServers.PSObject.Properties).Count -eq 0)) {
    Remove-JsonProperty $data "mcpServers"
  }
  $deleted = -not $hasBackup -and @($data.PSObject.Properties).Count -eq 0
  $result = @{ Changed = $true; Backup = ""; Created = $false; Deleted = $deleted }
  if ($dry) { return $result }
  if ($deleted) {
    Remove-Item -LiteralPath (Resolve-LinkPath $path) -Force
  } elseif ($hasBackup -and (Test-JsonSame $data $bakRead.Data)) {
    Write-AtomicBytes $path $bakRead.Raw 420
  } else {
    Write-AtomicBytes $path (ConvertTo-JsonBytes $data) 420
  }
  if ($hasBackup) { Remove-Item -LiteralPath $bakPath -Force }
  return $result
}

function Test-ClaudeJsonConnected {
  $path = Join-Path (Get-HomeDir) ".claude.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  $servers = Get-JsonProperty (Read-JsonConfig $path).Data "mcpServers"
  return Test-TasklessServerOwned (Get-JsonProperty $servers "taskless")
}

function Test-CodexConfigConnected {
  $path = Join-Path (Get-HomeDir) ".codex/config.toml"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  $text = [IO.File]::ReadAllText($path)
  return $text.Contains("# >>> taskless:codex") -and $text.Contains("# <<< taskless:codex")
}

function Get-CodexBlock {
  $server = Get-TasklessServer
  $url = $server.url | ConvertTo-Json -Compress
  $command = $server.headersHelper | ConvertTo-Json -Compress
  return "[mcp_servers.taskless]`nurl = $url`nhttp_headers_helper = $command`n`n[plugins.`"taskless@taskless-app`".mcp_servers.taskless]`nenabled = false`n"
}

function Apply-KeyHelper([bool]$dry) {
  $body = @'
$credSource = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TasklessHeaderCred {
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
  public static extern bool CredRead(string target, uint type, uint flags, out IntPtr cred);
  [DllImport("advapi32")]
  public static extern void CredFree(IntPtr cred);
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
}
"@
$ErrorActionPreference = "Stop"
$token = ""
$onWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
if ($onWindows -and $env:TASKLESS_KEY_STORE -ne "file") {
  try {
    Add-Type -TypeDefinition $credSource
    $token = [TasklessHeaderCred]::ReadToken("taskless-device")
  } catch {}
}
if (-not $token) {
  $homeDir = $env:HOME
  if (-not $homeDir) { $homeDir = $env:USERPROFILE }
  $keyFile = Join-Path (Join-Path (Join-Path $homeDir ".config") "taskless") "device-key"
  if (Test-Path -LiteralPath $keyFile -PathType Leaf) {
    $token = [IO.File]::ReadAllText($keyFile) -replace "[\r\n]", ""
  }
}
if (-not $token) { exit 1 }
[Console]::WriteLine((@{ Authorization = "Bearer $token" } | ConvertTo-Json -Compress))
'@
  return Apply-Block (Get-HeaderHelperPath) "# >>> taskless:key-helper" "# <<< taskless:key-helper" ((Get-Utf8).GetBytes($body)) $dry 384
}

function Remove-KeyHelperIfUnused([bool]$dry) {
  if ((Test-ClaudeJsonConnected) -or (Test-CodexConfigConnected)) {
    return @{ Changed = $false; Backup = ""; Created = $false; Deleted = $false }
  }
  return Remove-Block (Get-HeaderHelperPath) "# >>> taskless:key-helper" "# <<< taskless:key-helper" $dry
}

function Apply-Claude([bool]$dry) {
  $null = Apply-KeyHelper $dry
  $edit = Apply-ClaudeJson $dry
  if ($dry) {
    Say "  claude plugin marketplace add taskless-app/taskless"
    Say "  claude plugin install taskless@taskless-app --scope user"
    return $edit
  }
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Say "Нет claude в PATH. Сервер и ключ прописаны, плагин поставь командами:"
    Say "  claude plugin marketplace add taskless-app/taskless"
    Say "  claude plugin install taskless@taskless-app --scope user"
    return $edit
  }
  & claude plugin marketplace add taskless-app/taskless | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "Не поставил маркетплейс Claude Code." }
  & claude plugin install taskless@taskless-app --scope user | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "Не поставил плагин Claude Code." }
  return $edit
}

function Apply-Codex([bool]$dry) {
  $null = Apply-KeyHelper $dry
  $file = Join-Path (Get-HomeDir) ".codex/config.toml"
  $edit = Apply-Block $file "# >>> taskless:codex" "# <<< taskless:codex" ((Get-Utf8).GetBytes((Get-CodexBlock))) $dry 384
  if ($dry) {
    Say "  codex plugin marketplace add taskless-app/taskless"
    Say "  codex plugin add taskless@taskless-app"
    return $edit
  }
  if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Say "Нет codex в PATH. Сервер и ключ прописаны, плагин поставь командами:"
    Say "  codex plugin marketplace add taskless-app/taskless"
    Say "  codex plugin add taskless@taskless-app"
    return $edit
  }
  & codex plugin marketplace add taskless-app/taskless | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "Не поставил маркетплейс Codex." }
  & codex plugin add taskless@taskless-app | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "Не поставил плагин Codex." }
  return $edit
}

function Remove-Agent([string]$id, [bool]$dry) {
  if (Test-StubWants $id) {
    $file = Get-StubFile $id
    return (Remove-Block $file "# >>> taskless:$id" "# <<< taskless:$id" $dry)
  }
  $changed = $false
  switch ($id) {
    "claude-code" {
      if (-not $dry -and (Get-Command claude -ErrorAction SilentlyContinue)) {
        & claude plugin uninstall taskless@taskless-app --scope user | Out-Null
      }
      $edit = Remove-ClaudeJson $dry
      if ($edit.Changed) { $changed = $true }
      $helper = Remove-KeyHelperIfUnused $dry
      if ($helper.Changed) { $changed = $true }
    }
    "codex" {
      if (-not $dry -and (Get-Command codex -ErrorAction SilentlyContinue)) {
        & codex plugin remove taskless@taskless-app | Out-Null
      }
      $file = Join-Path (Get-HomeDir) ".codex/config.toml"
      $edit = Remove-Block $file "# >>> taskless:codex" "# <<< taskless:codex" $dry
      if ($edit.Changed) { $changed = $true }
      $helper = Remove-KeyHelperIfUnused $dry
      if ($helper.Changed) { $changed = $true }
    }
  }
  return @{ Changed = $changed; Backup = ""; Created = $false; Deleted = $false }
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
  switch ($id) {
    "claude-code" {
      Say "$name`: прописал бы ~/.claude.json и плагин taskless@taskless-app"
      $null = Apply-Claude $true
    }
    "codex" {
      Say "$name`: прописал бы ~/.codex/config.toml и плагин taskless@taskless-app"
      $null = Apply-Codex $true
    }
    default { Say "$name`: адаптер ещё не подключает клиент" }
  }
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
  switch ($id) {
    "claude-code" {
      $null = Apply-Claude $false
      Say "$name`: сервер и ключ прописаны"
    }
    "codex" {
      $null = Apply-Codex $false
      Say "$name`: сервер и ключ прописаны"
    }
    default { Say "$name`: адаптер ещё не подключает клиент" }
  }
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
    $json = Restore-LoneSurrogates ($payload | ConvertTo-Json -Compress -Depth 6)
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

function Get-ServerMessage($json, [string]$net) {
  if ($net) { return $net }
  foreach ($key in @("message", "error", "detail")) {
    $value = Get-JsonProperty $json $key
    if ($value -is [string] -and $value) { return $value }
  }
  return "неизвестная ошибка сервера"
}

function Test-SecretName([string]$name) {
  $split = [regex]::Replace($name, '([a-zа-яё0-9])([A-ZА-ЯЁ])', '$1_$2')
  $split = [regex]::Replace($split, '([A-ZА-ЯЁ])([A-ZА-ЯЁ][a-zа-яё])', '$1_$2').ToLowerInvariant()
  $words = @($split -split '[_-]+' | Where-Object { $_ })
  if ($words.Count -eq 0) { return $false }
  $last = $words[-1]
  if ($last -in @("password", "passwd", "пароль", "token", "secret", "apikey", "ключ")) { return $true }
  return $last -eq "key" -and $words.Count -gt 1 -and $words[-2] -in @("api", "secret", "access")
}

function Test-AssignedSecret([string]$value, [Text.RegularExpressions.Match]$match) {
  if (-not (Test-SecretName $match.Groups["name"].Value)) { return $false }
  if ($value -match '^(?i:true|false|null|none|undefined|empty|redacted|x+|\*+|\.+)$') { return $false }
  if ($value -match '^[$%{<]' -or $value.StartsWith("process.env")) { return $false }
  if ($value -match '^(?:@?[A-Z][A-Z0-9]*-\d+|v?\d+(?:\.\d+)+(?:[-+][\w.]+)?|\d{4}-\d{2}-\d{2}(?:[T ]?[\d:.]+Z?)?|\d{1,2}:\d{2}(?::\d{2})?)$') { return $false }
  if ($match.Groups["sep"].Value -eq "=") { return $value.Length -ge 4 }
  return $value.Length -ge 6 -and $value -match '[^\p{L}]'
}

function Test-LineSecret([string]$line) {
  if (-not $tl.SecretPatterns) {
    $assigned = @'
(?<![\w-])(?<name>[\w-]*?(?:password|passwd|пароль|token|secret|key|ключ))["']?[ \t]*(?<sep>=|:)[ \t]*["']?(?<secret>[\x21-\x7e]+?)(?=["'`,;&<>)\]}]|\s|$)
'@
    $tl.SecretPatterns = @(
      [pscustomobject]@{ Pattern = '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])(?:tlswarm|tldev|tlsec|tldc|tla|tlr|tlc)_[A-Za-z0-9_-]{20,}'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{30,}(?![A-Za-z0-9_])'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])sk-ant-[A-Za-z0-9_-]{20,}'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{20,}'; Kind = "digit" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_])'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])xox[abprs]-[A-Za-z0-9-]{10,}'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])AIza[A-Za-z0-9_-]{35}'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?<![A-Za-z0-9_])[Bb]earer[ \t]+(?<secret>[A-Za-z0-9._~+/-]{16,}=*)'; Kind = "digit" },
      [pscustomobject]@{ Pattern = '(?i)(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*://[^\s/:@]+:(?<secret>[^\s/@]+)@'; Kind = "none" },
      [pscustomobject]@{ Pattern = '(?i)' + $assigned; Kind = "assigned" }
    )
  }
  foreach ($entry in $tl.SecretPatterns) {
    foreach ($match in [regex]::Matches($line, $entry.Pattern)) {
      $value = if ($match.Groups["secret"].Success) { $match.Groups["secret"].Value } else { $match.Value }
      if ($entry.Kind -eq "none") { return $true }
      if ($entry.Kind -eq "digit" -and $value -match '[0-9]') { return $true }
      if ($entry.Kind -eq "assigned" -and (Test-AssignedSecret $value $match)) { return $true }
    }
  }
  return $false
}

function Format-MemorySize([int64]$size) {
  if ($size -lt 1024) { return "$size Б" }
  if ($size -lt 1024 * 1024) { return "$([int][Math]::Floor($size / 1024 + 0.5)) КБ" }
  $tenths = [int][Math]::Floor($size * 10 / (1024 * 1024) + 0.5)
  return "$([Math]::Floor($tenths / 10)),$($tenths % 10) МБ"
}

function Format-MemoryCount([int]$count, [string[]]$words = @("файл", "файла", "файлов")) {
  $mod10 = $count % 10
  $mod100 = $count % 100
  if ($mod10 -eq 1 -and $mod100 -ne 11) { $word = $words[0] }
  elseif ($mod10 -ge 2 -and $mod10 -le 4 -and -not ($mod100 -ge 12 -and $mod100 -le 14)) { $word = $words[1] }
  else { $word = $words[2] }
  return "$count $word"
}

function Test-LinkItem($item) {
  if ($null -eq $item) { return $false }
  if ($item.PSObject.Properties["LinkType"] -and $item.LinkType) { return $true }
  return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-MemorySkipReason([string]$name) {
  $lower = $name.ToLowerInvariant()
  if ($lower.StartsWith(".env") -or $lower.StartsWith("id_") -or $lower.Contains("secret") -or $lower.Contains("credential") -or $lower.Contains("token")) {
    return "похоже на ключи"
  }
  foreach ($ext in @(".pem", ".key", ".p12", ".pfx")) {
    if ($lower.EndsWith($ext)) { return "похоже на ключи" }
  }
  if (-not ($lower.EndsWith(".md") -or $lower.EndsWith(".markdown") -or $lower.EndsWith(".txt"))) { return "не текст" }
  return $null
}

function Inspect-MemoryFile([string]$path, $scan) {
  $shown = Format-Tilde ([IO.Path]::GetFullPath($path))
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (Test-LinkItem $item) {
      $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "симлинк" }
      return $null
    }
    $reason = Get-MemorySkipReason $item.Name
    if ($reason) {
      $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = $reason }
      return $null
    }
    $size = [int64]$item.Length
    if ($size -gt 256 * 1024) {
      $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "больше 256 КБ" }
      return $null
    }
    $data = [IO.File]::ReadAllBytes($path)
    $limit = [Math]::Min($data.Length, 8192)
    for ($i = 0; $i -lt $limit; $i++) {
      if ($data[$i] -eq 0) {
        $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "не текст" }
        return $null
      }
    }
    $text = (Get-Utf8).GetString($data)
    $inPrivateKey = $false
    $number = 0
    # Пустой хвост после Split — не строка: так же считают splitlines и node.
    $fileLines = @($text.Split("`n"))
    if ($fileLines.Count -gt 1 -and $fileLines[$fileLines.Count - 1] -eq "") {
      $fileLines = @($fileLines[0..($fileLines.Count - 2)])
    }
    foreach ($rawLine in $fileLines) {
      $number++
      $line = $rawLine.TrimEnd([char]13)
      $begins = [regex]::IsMatch($line, '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----')
      $ends = [regex]::IsMatch($line, '-----END [A-Z0-9 ]*PRIVATE KEY-----')
      if ($inPrivateKey -or $begins -or (Test-LineSecret $line)) {
        $scan.Secrets += [pscustomobject]@{ Path = $shown; Number = $number }
      }
      if ($inPrivateKey -and $ends) { $inPrivateKey = $false }
      if ($begins -and -not $ends) { $inPrivateKey = $true }
    }
    return $size
  } catch {
    $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "не прочитал" }
    return $null
  }
}

function Walk-MemoryDir([string]$root, $scan) {
  $count = 0
  $total = [int64]0
  try {
    $entries = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | Sort-Object -Property Name)
  } catch {
    $scan.Skipped += [pscustomobject]@{ Path = (Format-Tilde ([IO.Path]::GetFullPath($root))); Reason = "не прочитал" }
    return [pscustomobject]@{ Count = 0; Total = [int64]0 }
  }
  foreach ($entry in $entries) {
    $path = $entry.FullName
    $shown = Format-Tilde ([IO.Path]::GetFullPath($path))
    try {
      if (Test-LinkItem $entry) {
        $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "симлинк" }
        continue
      }
      if ($entry.PSIsContainer) {
        if ($entry.Name.StartsWith(".")) {
          $scan.Skipped += [pscustomobject]@{ Path = $shown + "/"; Reason = "скрытая папка" }
        } elseif ($entry.Name -eq "node_modules") {
          $scan.Skipped += [pscustomobject]@{ Path = $shown + "/"; Reason = "node_modules" }
        } else {
          $sub = Walk-MemoryDir $path $scan
          $count += $sub.Count
          $total += $sub.Total
        }
        continue
      }
      # FIFO и прочие не-файлы: UnixMode врёт -rw-r--r--, ReadAllBytes на них виснет.
      if ($entry.UnixStat -and "$($entry.UnixStat.ItemType)" -ne "File") { continue }
      if ($entry.Name -in @("CLAUDE.md", "AGENTS.md")) {
        $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "правила команды" }
        continue
      }
      $size = Inspect-MemoryFile $path $scan
      if ($null -ne $size) {
        $count++
        $total += $size
      }
    } catch {
      $scan.Skipped += [pscustomobject]@{ Path = $shown; Reason = "не прочитал" }
    }
  }
  return [pscustomobject]@{ Count = $count; Total = $total }
}

function Get-CustomMemoryDirs {
  $dirs = @()
  $comparer = if (Test-WindowsOs) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
  $seen = [Collections.Generic.HashSet[string]]::new($comparer)
  $homeDir = [IO.Path]::GetFullPath((Get-HomeDir))
  foreach ($raw in $tl.MemoryDirs) {
    if (-not $raw) { continue }
    $expanded = $raw
    if ($raw -eq "~") { $expanded = $homeDir }
    elseif ($raw.StartsWith("~/") -or $raw.StartsWith("~\")) { $expanded = Join-Path $homeDir $raw.Substring(2) }
    $full = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd("\", "/") }
    if (-not $seen.Add($full)) { continue }
    $dirs += [pscustomobject]@{ Path = $full; Raw = $raw }
  }
  return $dirs
}

function Assert-MemoryDirs {
  foreach ($dir in @(Get-CustomMemoryDirs)) {
    if (-not (Test-Path -LiteralPath $dir.Path -PathType Container)) { Die "Нет такой папки: $($dir.Raw)" }
  }
}

function Get-SecretRanges($secrets) {
  $ranges = New-Object System.Collections.Generic.List[object]
  foreach ($secret in @($secrets)) {
    if ($ranges.Count -gt 0) {
      $last = $ranges[$ranges.Count - 1]
      if ($last.Path -eq $secret.Path -and $last.Last -eq ($secret.Number - 1)) {
        $last.Last = $secret.Number
        continue
      }
    }
    $ranges.Add([pscustomobject]@{ Path = $secret.Path; First = $secret.Number; Last = $secret.Number })
  }
  return ,$ranges.ToArray()
}

function Get-MemoryScan {
  Assert-MemoryDirs
  $homeDir = [IO.Path]::GetFullPath((Get-HomeDir))
  $scan = @{ Skipped = @(); Secrets = @() }
  $rows = @()
  $total = [int64]0
  $files = @(
    [pscustomobject]@{ Path = (Join-Path $homeDir ".claude/CLAUDE.md"); Label = "правила" },
    [pscustomobject]@{ Path = (Join-Path $homeDir ".codex/AGENTS.md"); Label = "правила" }
  )
  foreach ($file in $files) {
    try { $item = Get-Item -LiteralPath $file.Path -Force -ErrorAction Stop } catch { $item = $null }
    if ($null -eq $item) { continue }
    $size = Inspect-MemoryFile $file.Path $scan
    if ($null -ne $size) {
      $rows += "  $(Format-Tilde $file.Path) — $(Format-MemorySize $size), $($file.Label)"
      $total += $size
    }
  }
  $claudeDirs = @()
  $projects = Join-Path $homeDir ".claude/projects"
  try {
    foreach ($entry in @(Get-ChildItem -LiteralPath $projects -Force -ErrorAction Stop | Sort-Object -Property Name)) {
      $memory = Join-Path $entry.FullName "memory"
      if (-not $entry.PSIsContainer -or (Test-LinkItem $entry)) { continue }
      try { $memoryItem = Get-Item -LiteralPath $memory -Force -ErrorAction Stop } catch { continue }
      if ($memoryItem.PSIsContainer -and -not (Test-LinkItem $memoryItem)) { $claudeDirs += $memory }
    }
  } catch {}
  $claudeCount = 0
  $claudeSize = [int64]0
  foreach ($dir in $claudeDirs) {
    $result = Walk-MemoryDir $dir $scan
    $claudeCount += $result.Count
    $claudeSize += $result.Total
  }
  if ($claudeCount -gt 0) {
    $rows += "  ~/.claude/projects/…/memory/ — $(Format-MemoryCount $claudeCount), $(Format-MemorySize $claudeSize), память Claude Code"
    $total += $claudeSize
  }
  $dirs = @(
    [pscustomobject]@{ Path = (Join-Path $homeDir ".codex/memories"); Label = "память Codex" },
    [pscustomobject]@{ Path = (Join-Path $homeDir ".codex/memories_v2"); Label = "память Codex" }
  )
  foreach ($custom in @(Get-CustomMemoryDirs)) {
    $dirs += [pscustomobject]@{ Path = $custom.Path; Label = "твоя папка" }
  }
  foreach ($dir in $dirs) {
    try { $item = Get-Item -LiteralPath $dir.Path -Force -ErrorAction Stop } catch { continue }
    if (Test-LinkItem $item) {
      $scan.Skipped += [pscustomobject]@{ Path = (Format-Tilde $dir.Path); Reason = "симлинк" }
      continue
    }
    $result = Walk-MemoryDir $dir.Path $scan
    if ($result.Count -gt 0) {
      $rows += "  $(Format-Tilde $dir.Path)/ — $(Format-MemoryCount $result.Count), $(Format-MemorySize $result.Total), $($dir.Label)"
      $total += $result.Total
    }
  }
  $lines = @($rows)
  if ($rows.Count -gt 0) {
    $lines += "Всего $(Format-MemorySize $total). Агент за раз читает до 200 КБ, остальное — по выбору человека."
  }
  if ($scan.Skipped.Count -gt 0) {
    $skippedText = (@($scan.Skipped | Select-Object -First 10 | ForEach-Object { "$($_.Path) — $($_.Reason)" }) -join "; ")
    if ($scan.Skipped.Count -gt 10) { $skippedText += "; и ещё $($scan.Skipped.Count - 10)" }
    $lines += "Пропущены: $skippedText."
  }
  foreach ($range in (Get-SecretRanges $scan.Secrets)) {
    if ($range.First -eq $range.Last) {
      $lines += "Похоже на секрет: $($range.Path), строка $($range.First). Эту строку в записи не бери."
    } else {
      $lines += "Похоже на секрет: $($range.Path), строки $($range.First)–$($range.Last). Эти строки в записи не бери."
    }
  }
  return [pscustomobject]@{ Found = ($rows.Count -gt 0); Lines = $lines }
}

function Show-MemoryScan {
  $result = Get-MemoryScan
  if ($result.Found) { Say "Память на этом компьютере. В Taskless пока ничего не ушло." }
  else { Say "Памяти агентов на компьютере не нашёл" }
  if ($result.Found -or $tl.Dry) {
    foreach ($line in $result.Lines) { Say $line }
  }
  return $result
}

function Test-ModifiedAt($value) {
  if ($value -isnot [string] -or $value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function Protect-LoneSurrogates([string]$raw) {
  if (-not $raw) { return $raw }
  # Newtonsoft заменяет одинокий \uD83D на U+FFFD ещё при чтении. Прячем escape,
  # чтобы после ConvertTo-Json вернуть его так же, как JSON.stringify в node.
  # (?<!\\) считает экранированный слеш началом escape: a\\\ud83d не прячется.
  # Чётное число слешей перед \u — настоящий escape, нечётное — литерал.
  $bound = '(?<=(?:^|[^\\])(?:\\\\)*)'
  $high = $bound + '\\u([dD][89abAB][0-9a-fA-F]{2})(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})'
  $low = $bound + '(?<!' + $bound + '\\u[dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})'
  # Метка на вызов: постоянная ~TL118~d83d~ совпала бы с чужим текстом и ушла бы как \ud83d.
  $script:tlSurrogateMark = [guid]::NewGuid().ToString("N")
  $mark = $script:tlSurrogateMark
  $repl = { param($m) "~$mark~$($m.Groups[1].Value.ToLowerInvariant())~" }.GetNewClosure()
  $raw = [regex]::Replace($raw, $high, $repl)
  return [regex]::Replace($raw, $low, $repl)
}

function Restore-LoneSurrogates([string]$json) {
  $mark = $script:tlSurrogateMark
  if (-not $json -or -not $mark) { return $json }
  $needle = "~$mark~"
  if ($json.IndexOf($needle) -lt 0) { return $json }
  return [regex]::Replace($json, "~$mark~([0-9a-f]{4})~", { param($m) return ('\u{0}' -f $m.Groups[1].Value) })
}

function ConvertFrom-JToken($token) {
  if ($null -eq $token -or $token.Type -eq [Newtonsoft.Json.Linq.JTokenType]::Null) { return $null }
  if ($token -is [Newtonsoft.Json.Linq.JArray]) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in $token) { [void]$list.Add((ConvertFrom-JToken $item)) }
    return ,$list.ToArray()
  }
  if ($token -is [Newtonsoft.Json.Linq.JObject]) {
    $obj = [pscustomobject]@{}
    foreach ($prop in $token.Properties()) {
      $obj | Add-Member -NotePropertyName $prop.Name -NotePropertyValue (ConvertFrom-JToken $prop.Value) -Force
    }
    return $obj
  }
  return $token.Value
}

function Read-ImportBatch([string]$path) {
  try {
    # Одинокий суррогат прячем до разбора в обеих ветках.
    $raw = Protect-LoneSurrogates ([IO.File]::ReadAllText($path))
    # pwsh 6+: Newtonsoft в ConvertFrom-Json делает из ISO DateTime, и ConvertTo-Json
    # переписывает +03:00 в +00:00. DateParseHandling.None оставляет текст.
    # Windows PowerShell 5.1 сборку Newtonsoft.Json не грузит. Там ConvertFrom-Json
    # идёт через JavaScriptSerializer, и ISO-строка остаётся строкой. Дальше обе
    # ветки отдают PSCustomObject (массивы — object[]): проверки ниже общие.
    if ('Newtonsoft.Json.JsonConvert' -as [type]) {
      $settings = New-Object Newtonsoft.Json.JsonSerializerSettings
      $settings.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
      $token = [Newtonsoft.Json.JsonConvert]::DeserializeObject($raw, $settings)
      $batch = ConvertFrom-JToken $token
    } else {
      $batch = $raw | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    Die "Не прочитал JSON ${path}: $($_.Exception.Message)"
  }
  $files = Get-JsonProperty $batch "files"
  if ($batch -isnot [pscustomobject] -or $null -eq $files -or $files -isnot [Array]) {
    Die "Не тот формат ${path}: нужен объект с массивом files"
  }
  if ((Test-JsonProperty $batch "client") -and (Get-JsonProperty $batch "client") -notin @("claude-code", "codex", "grok", "zcode", "cursor", "gemini", "other")) {
    Die "Не тот формат ${path}: неизвестный client"
  }
  $totalItems = 0
  $fileIndex = 0
  foreach ($file in $files) {
    $fileIndex++
    $where = "файл $fileIndex"
    if ($file -isnot [pscustomobject]) { Die "${where}: нужен объект" }
    $filePath = Get-JsonProperty $file "path"
    if ($filePath -isnot [string] -or $filePath.Length -lt 1 -or $filePath.Length -gt 500) { Die "${where}: path — строка от 1 до 500 знаков" }
    if ((Get-JsonProperty $file "source") -notin @("instructions", "agent_memory", "notes")) { Die "${where}: source — instructions, agent_memory или notes" }
    if ((Test-JsonProperty $file "modifiedAt") -and -not (Test-ModifiedAt (Get-JsonProperty $file "modifiedAt"))) {
      Die "${where}: modifiedAt — дата ISO 8601 с часовым поясом"
    }
    $items = Get-JsonProperty $file "items"
    if ($null -eq $items -or $items -isnot [Array]) { Die "${where}: items — массив записей" }
    if ($items.Count -gt 300) { Die "${where}: больше 300 записей, раздели их между файлами" }
    $itemIndex = 0
    foreach ($item in $items) {
      $itemIndex++
      $place = "${where}, запись $itemIndex"
      if ($item -isnot [pscustomobject] -or (Get-JsonProperty $item "statement") -isnot [string]) { Die "${place}: statement — строка" }
      if ((Test-JsonProperty $item "kind") -and (Get-JsonProperty $item "kind") -notin @("fact", "rule", "decision", "promise")) {
        Die "${place}: kind — fact, rule, decision или promise"
      }
      if ((Test-JsonProperty $item "quote") -and (Get-JsonProperty $item "quote") -isnot [string]) { Die "${place}: quote — строка" }
    }
    $totalItems += $items.Count
  }
  if ($totalItems -eq 0) { Die "Пустая пачка ${path}: нужна хотя бы одна запись" }
  return $batch
}

function Get-ImportNumber($json, [string]$name) {
  $value = Get-JsonProperty $json $name
  if ($null -eq $value) { return 0 }
  try { return [int]$value } catch { return 0 }
}

function Show-ImportReport($reports) {
  $total = @{ new = 0; known = 0; duplicate = 0; skipped = 0 }
  foreach ($report in $reports) {
    foreach ($key in @("new", "known", "duplicate", "skipped")) { $total[$key] += Get-ImportNumber $report $key }
  }
  Say "Взял новых: $($total.new). Уже было: $($total.known). Повтор: $($total.duplicate). Пропущено: $($total.skipped)"
  $reasonNames = @(
    @("secret", "секрет"), @("too_long", "длиннее 300 знаков"), @("empty", "пусто"),
    @("rule_without_quote", "правило без цитаты"), @("retracted", "ты это раньше удалил"), @("error", "ошибка")
  )
  $reasons = @()
  foreach ($pair in $reasonNames) {
    $count = 0
    foreach ($report in $reports) { $count += Get-ImportNumber (Get-JsonProperty $report "skippedByReason") $pair[0] }
    if ($count -gt 0) { $reasons += "$($pair[1]) — $count" }
  }
  if ($reasons.Count -gt 0) { Say "Причины пропусков: $($reasons -join '; ')" }
  foreach ($report in $reports) {
    $reportFiles = Get-JsonProperty $report "files"
    foreach ($file in $reportFiles) {
      Say "  $(Get-JsonField $file 'file') — новых $(Get-ImportNumber $file 'new'), уже было $(Get-ImportNumber $file 'known'), повтор $(Get-ImportNumber $file 'duplicate'), пропущено $(Get-ImportNumber $file 'skipped')"
    }
  }
}

function Invoke-MemoryImport {
  if (-not $tl.Dry -and -not (Load-Key)) {
    Say "Сначала подключи агентов: запусти установщик без флагов"
    return 1
  }
  $batch = Read-ImportBatch $tl.ImportFile
  $files = Get-JsonProperty $batch "files"
  $totalItems = 0
  foreach ($file in $files) { $totalItems += @($file.items).Count }
  $countWords = @("запись", "записи", "записей")
  if ($tl.Dry) {
    Say "Проверка: ушло бы $(Format-MemoryCount $totalItems $countWords), запросов не отправил."
    foreach ($file in $files) { Say "  $($file.path) — $(Format-MemoryCount @($file.items).Count $countWords)" }
    return 0
  }
  $chunks = @()
  $current = @()
  $count = 0
  foreach ($file in $files) {
    $size = @($file.items).Count
    if ($current.Count -gt 0 -and $count + $size -gt 300) {
      $chunks += ,@($current)
      $current = @()
      $count = 0
    }
    $current += $file
    $count += $size
  }
  if ($current.Count -gt 0) { $chunks += ,@($current) }
  $reports = @()
  $sent = 0
  foreach ($chunk in $chunks) {
    $payload = @{ files = [object[]]$chunk }
    if (Test-JsonProperty $batch "client") { $payload["client"] = Get-JsonProperty $batch "client" }
    $res = Invoke-TasklessApi "POST" ((Get-ApiBase) + "/memory/personal/import") $payload $tl.Token
    if ($res.Status -ne 200) {
      if ($reports.Count -gt 0) {
        Show-ImportReport $reports
        Say "Отправил $sent из $(Format-MemoryCount $totalItems $countWords), дальше остановился:"
      }
      Die (Get-ServerMessage $res.Json $res.Net)
    }
    $reports += $res.Json
    foreach ($file in $chunk) { $sent += @($file.items).Count }
  }
  Show-ImportReport $reports
  return 0
}

function Invoke-MemorySet {
  if ($tl.Dry) {
    if ($tl.MemorySet -eq "on") { Say "Проверка: включил бы личную память, запросов не отправил." }
    else { Say "Проверка: выключил бы личную память, запросов не отправил." }
    return 0
  }
  if (-not (Load-Key)) {
    Say "Сначала подключи агентов: запусти установщик без флагов"
    return 1
  }
  $res = Invoke-TasklessApi "PUT" ((Get-ApiBase) + "/memory/personal/settings") @{ enabled = ($tl.MemorySet -eq "on") } $tl.Token
  if ($res.Status -ne 200) {
    Die (Get-ServerMessage $res.Json $res.Net)
    return 1
  }
  if ($tl.MemorySet -eq "on") { Say "Личная память включена." }
  else { Say "Личная память выключена. Записи, если были, остались, удалить их можно в профиле." }
  return 0
}

function Show-MemoryImportSteps([int]$n) {
  Say "$n. Спроси, забирать ли найденную память. Если нет — на этом всё."
  $n++
  Say "$n. Прочитай файлы из списка, всего не больше 200 КБ текста. Если файлов больше, спроси, какие взять."
  $n++
  Say "$n. Составь короткие записи: одно утверждение — одна запись, до 300 знаков. Вид: fact, rule, decision или promise. Для правила положи в quote дословную строку из файла. Пароли, токены, ключи и строки с пометкой «похоже на секрет» не бери."
  $n++
  Say "$n. Покажи записи человеку по файлам и спроси: «Отправить в Taskless?» Убери то, что он попросит. Без явного «да» ничего не отправляй."
  $n++
  Say "$n. Запиши пачку во временный файл JSON (формат: https://taskless.ru/invite-agent#memory-format) и запусти:"
  Say "   & ([scriptblock]::Create((irm https://taskless.ru/connect.ps1))) --import-memory <файл>"
  $n++
  Say "$n. Перескажи человеку отчёт установщика и удали временный файл."
}

function Show-MemoryIntroSteps {
  Say "1. Расскажи человеку о личной памяти и спроси, включить ли её. Агенты во всех его подключениях будут помнить его правила, решения и факты о работе. Записи видит только он: ни админ, ни команда, ни рой. Выключить и удалить всё можно в профиле Taskless, раздел «Личная память»."
  Say "2. Ответ запиши командой:"
  Say "   & ([scriptblock]::Create((irm https://taskless.ru/connect.ps1))) --memory on"
  Say "   Если человек против — та же команда с --memory off, и на этом всё."
}

function Report-Memory {
  Say ""
  if ($tl.Dry) {
    $null = Show-MemoryScan
    Say "Это проверка. Что делать с памятью, установщик скажет при настоящем запуске."
    return
  }
  $res = Invoke-TasklessApi "GET" ((Get-ApiBase) + "/memory/personal/settings") $null $tl.Token
  if ($res.Status -ne 200) {
    Say "Не узнал, включена ли личная память: $(Get-ServerMessage $res.Json $res.Net)"
    return
  }
  $state = Get-JsonField $res.Json "state"
  if ($state -eq "off") {
    Say "Личная память Taskless выключена, память с компьютера не ищу. Включить её можно в профиле, раздел «Личная память»."
    return
  }
  $scan = Show-MemoryScan
  if ($state -eq "on") {
    if ($scan.Found) {
      Say ""
      Say "Агенту: как забрать эту память в Taskless"
      Show-MemoryImportSteps 1
    }
    return
  }
  Say ""
  Say "Агенту: личная память Taskless пока не включена"
  Show-MemoryIntroSteps
  if ($scan.Found) { Show-MemoryImportSteps 3 }
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
  Set-OwnerMode $tl.MetaFile 384
}

function Read-Meta {
  if (-not (Test-Path -LiteralPath $tl.MetaFile -PathType Leaf)) { return $null }
  try { return ([IO.File]::ReadAllText($tl.MetaFile) | ConvertFrom-Json) } catch { return $null }
}

function Test-AgentConnected([string]$id) {
  if (Test-StubWants $id) {
    $file = Get-StubFile $id
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($file)
    return $text.Contains("# >>> taskless:$id")
  }
  if (-not (Test-Path -LiteralPath (Get-HeaderHelperPath) -PathType Leaf)) { return $false }
  switch ($id) {
    "claude-code" { return Test-ClaudeJsonConnected }
    "codex" { return Test-CodexConfigConnected }
    default { return $false }
  }
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
    Report-Memory
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
  Report-Memory
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
  if ($tl.MemorySet) { return (Invoke-MemorySet) }
  if ($tl.ImportFile) { return (Invoke-MemoryImport) }
  if ($tl.MemoryDirs.Count -gt 0) { Assert-MemoryDirs }
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
