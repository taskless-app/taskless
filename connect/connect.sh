#!/bin/sh
# Taskless: подключение агентов на этом компьютере.
#
# Один файл, его отдают как https://taskless.ru/connect.sh и запускают
# `curl -fsSL https://taskless.ru/connect.sh | sh`. Рядом ничего нет, поэтому
# помощник на python3 или node встроен ниже, а не лежит отдельным файлом.
#
# Режимы: без флагов подключает всех найденных; --dry-run только показывает;
# --only claude-code,codex; --status; --uninstall снимает наши правки и
# отзывает ключ. --memory-dir добавляет источники памяти, --memory on|off
# меняет настройку, --import-memory отправляет согласованные записи.
# Ключ — macOS Keychain (`security`), Linux libsecret
# (`secret-tool`) плюс файл ~/.config/taskless/device-key с правами 600 для
# MCP helper без D-Bus; без связки ключ хранится только в этом файле.
#
# Адаптер клиента — три действия: найти, прописать, снять. TOML и скрипты
# правятся блоком между `# >>> taskless:<id>` и `# <<< taskless:<id>`;
# ~/.claude.json — только по ключу mcpServers.taskless. Перед первой правкой —
# копия `<файл>.bak-taskless`. Повтор без дублей, чужие ключи не трогаются.
# Подключены Claude Code и Codex (MCP-105), остальные — MCP-106 и позже.
# Заглушка для тестов: TASKLESS_CONNECT_STUB=1 и TASKLESS_STUB_AGENTS.
#
# TASKLESS_URL — база API, по умолчанию https://taskless.ru/api.
# Настоящий taskless.ru из тестов не зовётся: тест подставляет свой адрес.

set -eu

CLIENT_VERSION=0.1.0
AGENT_IDS="claude-code codex grok zcode cursor gemini opencode copilot qwen kimi"

DRY=0
DO_STATUS=0
DO_UNINSTALL=0
MEMORY_SET=
IMPORT_FILE=
MEMORY_DIRS=
ONLY=
HELPER=
RUNTIME=
BASE=
DEVICE_NAME=
PLATFORM=
OS_VERSION=
FOUND=
MISSING=
SEARCHED=
TOKEN=
STORE_KIND=
CONFIG_DIR=
KEY_FILE=
META_FILE=

HTTP_STATUS=
HTTP_RETRY=
HTTP_NET=
HTTP_OAUTH_ERROR=
HTTP_TOKEN=
HTTP_USER_CODE=
HTTP_DEVICE_CODE=
HTTP_URI=
HTTP_EXPIRES=
HTTP_INTERVAL=
EDIT_CHANGED=
EDIT_BACKUP=
META_DEVICE=

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Taskless: подключение агентов на этом компьютере.

  sh connect.sh                         подключить всех найденных
  sh connect.sh --dry-run               показать, что поменяется
  sh connect.sh --only claude-code,codex
  sh connect.sh --status                что подключено
  sh connect.sh --uninstall             снять поставленное и отозвать ключ
  sh connect.sh --memory-dir ~/notes    также найти память в своей папке
  sh connect.sh --memory on|off         включить или выключить личную память
  sh connect.sh --import-memory <файл>  отправить согласованные записи
EOF
}

cleanup() {
  if [ -n "${HELPER:-}" ]; then
    rm -f "$HELPER"
  fi
}
# EXIT только убирает временный помощник. INT/TERM должны завершать процесс:
# иначе пойманный сигнал (таймаут теста) глотается и скрипт продолжает висеть.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

agent_name() {
  case "$1" in
    claude-code) printf '%s' "Claude Code" ;;
    codex) printf '%s' "Codex" ;;
    grok) printf '%s' "Grok" ;;
    zcode) printf '%s' "ZCode" ;;
    cursor) printf '%s' "Cursor" ;;
    gemini) printf '%s' "Gemini CLI" ;;
    opencode) printf '%s' "OpenCode" ;;
    copilot) printf '%s' "Copilot CLI" ;;
    qwen) printf '%s' "Qwen Code" ;;
    kimi) printf '%s' "Kimi CLI" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Короткие имена из речи человека («claude») и id словаря — одно и то же.
canon_id() {
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    claude|claude-code) printf '%s' "claude-code" ;;
    codex) printf '%s' "codex" ;;
    grok) printf '%s' "grok" ;;
    zcode|z-code) printf '%s' "zcode" ;;
    cursor) printf '%s' "cursor" ;;
    gemini) printf '%s' "gemini" ;;
    opencode|open-code) printf '%s' "opencode" ;;
    copilot) printf '%s' "copilot" ;;
    qwen) printf '%s' "qwen" ;;
    kimi) printf '%s' "kimi" ;;
    *) return 1 ;;
  esac
}

names_of() {
  out=
  for id in $1; do
    name=$(agent_name "$id")
    if [ -z "$out" ]; then
      out=$name
    else
      out="$out, $name"
    fi
  done
  printf '%s' "$out"
}

comma_ids() {
  out=
  for id in $1; do
    if [ -z "$out" ]; then
      out=$id
    else
      out="$out,$id"
    fi
  done
  printf '%s' "$out"
}

tilde_path() {
  # shellcheck disable=SC2088 # путь для человека: тильда в тексте отчёта, не раскрывается
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    "$HOME") printf '~' ;;
    *) printf '%s' "$1" ;;
  esac
}

digits() {
  printf '%s' "$1" | tr -cd '0-9'
}

want_id() {
  if [ -z "$ONLY" ]; then
    return 0
  fi
  case " $ONLY " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Заглушка подменяет адаптер только в тесте. На машине человека её нет.
stub_wants() {
  if [ "${TASKLESS_CONNECT_STUB:-}" != "1" ]; then
    return 1
  fi
  list=$(printf '%s' "${TASKLESS_STUB_AGENTS:-claude-code}" | tr ',' ' ')
  case " $list " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

stub_file() {
  printf '%s' "$HOME/.taskless-stub/$1.conf"
}

stub_manual() {
  case "$1" in
    claude-code) printf '%s' "перезапусти Claude Code" ;;
    codex) printf '%s' "в Codex одобри хуки командой /hooks" ;;
    *) return 0 ;;
  esac
}

agent_found() {
  if stub_wants "$1"; then
    return 0
  fi
  case "$1" in
    claude-code)
      command -v claude >/dev/null 2>&1 || [ -f "$HOME/.claude.json" ] || [ -d "$HOME/.claude" ]
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || [ -f "$HOME/.codex/config.toml" ] || [ -d "$HOME/.codex" ]
      ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --status) DO_STATUS=1 ;;
      --uninstall) DO_UNINSTALL=1 ;;
      --only)
        shift
        if [ $# -lt 1 ]; then
          die "После --only нужен список агентов."
        fi
        normalize_only "$1"
        ;;
      --only=*)
        normalize_only "${1#--only=}"
        ;;
      --memory)
        shift
        if [ $# -lt 1 ]; then
          die "После --memory нужно on или off."
        fi
        MEMORY_SET=$1
        ;;
      --memory=*)
        MEMORY_SET=${1#--memory=}
        if [ -z "$MEMORY_SET" ]; then
          die "После --memory нужно on или off."
        fi
        ;;
      --import-memory)
        shift
        if [ $# -lt 1 ]; then
          die "После --import-memory нужен JSON-файл."
        fi
        IMPORT_FILE=$1
        ;;
      --import-memory=*)
        IMPORT_FILE=${1#--import-memory=}
        if [ -z "$IMPORT_FILE" ]; then
          die "После --import-memory нужен JSON-файл."
        fi
        ;;
      --memory-dir)
        shift
        if [ $# -lt 1 ]; then
          die "После --memory-dir нужен путь."
        fi
        MEMORY_DIRS="${MEMORY_DIRS}${MEMORY_DIRS:+
}$1"
        ;;
      --memory-dir=*)
        if [ "$1" = "--memory-dir=" ]; then
          die "После --memory-dir нужен путь."
        fi
        MEMORY_DIRS="${MEMORY_DIRS}${MEMORY_DIRS:+
}${1#--memory-dir=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Не знаю аргумент: $1"
        ;;
    esac
    shift
  done
  if [ "$DO_STATUS" = 1 ] && [ "$DO_UNINSTALL" = 1 ]; then
    die "Укажи что-то одно: --status или --uninstall."
  fi
  if [ "$DO_STATUS" = 1 ] && [ "$DRY" = 1 ]; then
    die "--status ничего не меняет и без --dry-run."
  fi
  if [ -n "$MEMORY_SET" ] && [ "$MEMORY_SET" != "on" ] && [ "$MEMORY_SET" != "off" ]; then
    die "После --memory нужно on или off."
  fi
  if [ -n "$MEMORY_SET" ] && [ -n "$IMPORT_FILE" ]; then
    die "Укажи что-то одно: --memory или --import-memory."
  fi
  if { [ -n "$MEMORY_SET" ] || [ -n "$IMPORT_FILE" ]; } && { [ "$DO_STATUS" = 1 ] || [ "$DO_UNINSTALL" = 1 ]; }; then
    die "Ключи личной памяти не совмещаются с --status и --uninstall."
  fi
}

normalize_only() {
  ONLY=
  raw=$(printf '%s' "$1" | tr ',' ' ')
  for item in $raw; do
    if ! id=$(canon_id "$item"); then
      die "Не знаю агента: $item"
    fi
    case " $ONLY " in
      *" $id "*) ;;
      *) ONLY="$ONLY $id" ;;
    esac
  done
  ONLY=${ONLY# }
  if [ -z "$ONLY" ]; then
    die "После --only нужен список агентов."
  fi
}

collect_agents() {
  FOUND=
  MISSING=
  SEARCHED=
  for id in $AGENT_IDS; do
    if ! want_id "$id"; then
      continue
    fi
    SEARCHED="$SEARCHED $id"
    if agent_found "$id"; then
      FOUND="$FOUND $id"
    else
      MISSING="$MISSING $id"
    fi
  done
  FOUND=${FOUND# }
  MISSING=${MISSING# }
  SEARCHED=${SEARCHED# }
}

say_header() {
  printf '%s\n' "Taskless: подключение агентов"
  printf '\n'
}

print_manuals() {
  n=1
  any=0
  # Макет «Терминал»: сначала «в Codex одобри хуки», потом «перезапусти Claude Code».
  # Это не порядок «Нашёл»: там Claude Code стоит раньше Codex.
  order="codex claude-code"
  for id in $AGENT_IDS; do
    case " $order " in
      *" $id "*) ;;
      *) order="$order $id" ;;
    esac
  done
  for id in $order; do
    case " $FOUND " in
      *" $id "*) ;;
      *) continue ;;
    esac
    line=$(stub_manual "$id")
    if [ -z "$line" ]; then
      continue
    fi
    if [ "$any" = 0 ]; then
      printf '%s\n' "Сделай руками:"
      any=1
    fi
    printf '  %s. %s\n' "$n" "$line"
    n=$((n + 1))
  done
}

print_missing() {
  if [ -n "$MISSING" ]; then
    printf 'Не найдены: %s\n' "$(names_of "$MISSING")"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf '%s' "macos" ;;
    Linux) printf '%s' "linux" ;;
    MINGW*|MSYS*|CYGWIN*) printf '%s' "windows" ;;
    *) printf '%s' "" ;;
  esac
}

detect_device_name() {
  if [ -n "${TASKLESS_DEVICE_NAME:-}" ]; then
    printf '%s' "$TASKLESS_DEVICE_NAME"
    return
  fi
  name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '%s' "computer")
  printf '%s' "$name" | tr '\n\r' ' '
}

detect_os_version() {
  ver=
  if [ -n "${TASKLESS_OS_VERSION:-}" ]; then
    ver=$TASKLESS_OS_VERSION
  else
    case "$(uname -s)" in
      Darwin)
        ver=$(sw_vers -productVersion 2>/dev/null || true)
        ;;
      *)
        ver=$(uname -r 2>/dev/null || true)
        ;;
    esac
  fi
  if printf '%s' "$ver" | grep -Eq '^[0-9A-Za-z .()_-]{1,32}$'; then
    printf '%s' "$ver"
  fi
}

pick_runtime() {
  want=${TASKLESS_RUNTIME:-auto}
  case "$want" in
    python|python3)
      command -v python3 >/dev/null 2>&1 || die "Нет python3 (TASKLESS_RUNTIME=python)."
      RUNTIME=python3
      ;;
    node)
      command -v node >/dev/null 2>&1 || die "Нет node (TASKLESS_RUNTIME=node)."
      RUNTIME=node
      ;;
    auto)
      if command -v python3 >/dev/null 2>&1; then
        RUNTIME=python3
      elif command -v node >/dev/null 2>&1; then
        RUNTIME=node
      else
        die "Нужен python3 или node, чтобы поговорить с Taskless. Поставь любой из них и запусти снова."
      fi
      ;;
    *)
      die "Не знаю TASKLESS_RUNTIME=$want. Жду auto, python3 или node."
      ;;
  esac
}

prepare_helper() {
  pick_runtime
  raw=$(mktemp)
  if [ "$RUNTIME" = "python3" ]; then
    HELPER="$raw.py"
    mv "$raw" "$HELPER"
    cat > "$HELPER" <<'TASKLESS_CONNECT_PY_END'
import datetime, json, os, re, sys, tempfile, urllib.error, urllib.request

OS_RE = re.compile(r"^[0-9A-Za-z .()_-]{1,32}$")
PLATFORMS = ("macos", "linux", "windows")

def clean_name(raw):
    raw = "".join(ch if ch >= " " else " " for ch in (raw or ""))
    raw = raw.replace("<", " ").replace(">", " ")
    raw = " ".join(raw.split())
    raw = "".join(list(raw)[:64])
    return raw or "computer"

def parse_json(raw):
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}

def emit_http(status, retry, net, payload):
    def s(v):
        if v is None:
            return ""
        return str(v).replace("\n", " ").replace("\r", "")
    body = payload if isinstance(payload, dict) else {}
    fields = [
        ("status", status),
        ("retry_after", retry or ""),
        ("net_error", net or ""),
        ("oauth_error", body.get("error") or ""),
        ("access_token", body.get("access_token") or ""),
        ("user_code", body.get("user_code") or ""),
        ("device_code", body.get("device_code") or ""),
        ("verification_uri_complete", body.get("verification_uri_complete") or ""),
        ("expires_in", body.get("expires_in") if "expires_in" in body else ""),
        ("interval", body.get("interval") if "interval" in body else ""),
    ]
    for key, value in fields:
        sys.stdout.write("%s=%s\n" % (key, s(value)))

def request(method, url, payload=None, token=""):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False)
        # Одиночная половинка суррогатной пары (текст оборван посреди эмодзи) в utf-8
        # не кодируется. Пишем её escape-последовательностью, как JSON.stringify в node.
        # Целые пары python хранит одним символом, так что сюда попадают только одиночные.
        body = re.sub("[\ud800-\udfff]", lambda m: "\\u%04x" % ord(m.group()), body)
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            raw = res.read().decode("utf-8", "replace")
            return res.status, res.headers.get("Retry-After") or "", "", parse_json(raw)
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", "replace")
        retry = err.headers.get("Retry-After") if err.headers else ""
        return err.code, retry or "", "", parse_json(raw)
    except Exception as err:
        return 0, "", str(err), {}

def base():
    return os.environ.get("TASKLESS_BASE", "").rstrip("/")

def device_payload():
    agents = [a for a in os.environ.get("TASKLESS_AGENTS", "").split(",") if a]
    payload = {
        "client_id": "taskless-device",
        "device_name": clean_name(os.environ.get("TASKLESS_DEVICE_NAME", "")),
        "agents": agents,
        "client_version": os.environ.get("TASKLESS_CLIENT_VERSION") or "0.1.0",
    }
    platform = os.environ.get("TASKLESS_PLATFORM", "")
    if platform in PLATFORMS:
        payload["platform"] = platform
    os_version = os.environ.get("TASKLESS_OS_VERSION", "")
    if OS_RE.match(os_version or ""):
        payload["os_version"] = os_version
    return payload

def find_line(data, needle, start):
    pos = start
    while True:
        i = data.find(needle, pos)
        if i < 0:
            return -1
        if i == 0 or data[i - 1:i] == b"\n":
            return i
        pos = i + 1

def find_mark(data, mark, start):
    # Строка-метка с \n, \r\n или в конце файла без перевода. Ближняя из трёх.
    # Возвращает (позиция, длина строки с переводом) или (-1, 0).
    best = (-1, 0)
    for nl in (b"\n", b"\r\n"):
        i = find_line(data, mark + nl, start)
        if i >= 0 and (best[0] < 0 or i < best[0]):
            best = (i, len(mark) + len(nl))
    i = find_line(data, mark, start)
    if i >= 0 and i + len(mark) == len(data) and (best[0] < 0 or i < best[0]):
        best = (i, len(mark))
    return best

def link_dest(path):
    # Конфиг-симлинк (stow): пишем и удаляем цель, саму ссылку не трогаем.
    # realpath без strict разрешает и битую ссылку — в цель, которой ещё нет.
    return os.path.realpath(path) if os.path.islink(path) else path

def write_atomic(path, data, mode):
    dest = link_dest(path)
    parent = os.path.dirname(dest) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".taskless-", dir=parent)
    try:
        os.write(fd, data)
        os.fchmod(fd, mode)
    except Exception:
        os.close(fd)
        os.unlink(tmp)
        raise
    os.close(fd)
    os.replace(tmp, dest)

def emit_edit(changed, backup, created, deleted):
    sys.stdout.write("changed=%s\n" % (1 if changed else 0))
    sys.stdout.write("backup=%s\n" % backup)
    sys.stdout.write("created=%s\n" % (1 if created else 0))
    sys.stdout.write("deleted=%s\n" % (1 if deleted else 0))

def toml_key(raw):
    key = re.sub(br"[ \t]+", b"", raw.strip())
    return key.replace(b'"taskless"', b"taskless").replace(b"'taskless'", b"taskless")

def toml_kind(key):
    if key == b"mcp_servers.taskless" or key.startswith(b"mcp_servers.taskless."):
        return "mcp"
    plugin = b'plugins."taskless@taskless-app".mcp_servers.taskless'
    if key == plugin or key.startswith(plugin + b"."):
        return "plugin"
    return None

def toml_header(line):
    array = re.match(br"^[ \t]*\[\[([^\[\]]+)\]\][ \t]*(?:#.*)?(?:\r?\n)?$", line)
    if array:
        return b"[]" + toml_key(array.group(1))
    match = re.match(br"^[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?(?:\r?\n)?$", line)
    return toml_key(match.group(1)) if match else None

def toml_mask(data):
    out = bytearray(data)
    state = ""
    i = 0
    while i < len(data):
        char = data[i]
        if state in ("basic", "literal"):
            if state == "basic" and char == 92:
                i += 2
                continue
            if char == (34 if state == "basic" else 39) or char == 10:
                state = ""
            i += 1
            continue
        if state in ("basic3", "literal3"):
            delimiter = b'"""' if state == "basic3" else b"'''"
            if data.startswith(delimiter, i):
                state = ""
                i += 3
                continue
            if state == "basic3" and char == 92:
                out[i] = 32
                if i + 1 < len(data) and data[i + 1] not in (10, 13):
                    out[i + 1] = 32
                i += 2
                continue
            if char not in (10, 13):
                out[i] = 32
            i += 1
            continue
        if char == 35:
            nl = data.find(b"\n", i)
            i = len(data) if nl < 0 else nl
            continue
        if char in (34, 39):
            delimiter = bytes([char]) * 3
            if data.startswith(delimiter, i):
                state = "basic3" if char == 34 else "literal3"
                i += 3
            else:
                state = "basic" if char == 34 else "literal"
                i += 1
            continue
        i += 1
    return bytes(out), state

def toml_assignment_end(masked, pos, next_pos):
    balance = 0
    scan = pos
    first = True
    while scan < len(masked):
        line = masked[scan:next_pos]
        eq = line.find(b"=") if first else -1
        rhs = line[eq + 1:] if eq >= 0 else line
        rhs = re.sub(br'"(?:\\.|[^"\\])*"|\'[^\']*\'', b"", rhs).split(b"#", 1)[0]
        balance += rhs.count(b"[") - rhs.count(b"]") + rhs.count(b"{") - rhs.count(b"}")
        if balance <= 0:
            return next_pos
        first = False
        scan = next_pos
        nl = masked.find(b"\n", scan)
        next_pos = len(masked) if nl < 0 else nl + 1
    return len(masked)

def toml_taskless_ranges(data):
    masked, _open = toml_mask(data)
    ranges = []
    section = b""
    pos = 0
    while pos < len(data):
        nl = data.find(b"\n", pos)
        next_pos = len(data) if nl < 0 else nl + 1
        line = masked[pos:next_pos]
        header = toml_header(line)
        if header is not None:
            section = header
            kind = toml_kind(section)
            if kind is not None:
                start = pos
                end = len(data)
                scan = next_pos
                while scan < len(data):
                    scan_nl = data.find(b"\n", scan)
                    scan_next = len(data) if scan_nl < 0 else scan_nl + 1
                    next_header = toml_header(masked[scan:scan_next])
                    if next_header is not None and not next_header.startswith(section + b"."):
                        end = scan
                        break
                    scan = scan_next
                ranges.append((start, end, kind))
                pos = end
                continue
        else:
            eq = line.find(b"=")
            if eq >= 0:
                left = toml_key(line[:eq])
                full = (section + b"." if section else b"") + left
                kind = toml_kind(full)
                if kind is not None:
                    end = toml_assignment_end(masked, pos, next_pos)
                    ranges.append((pos, end, kind))
                    pos = end
                    continue
        pos = next_pos
    return ranges

def toml_remove_ranges(data, ranges):
    out = []
    pos = 0
    for start, end, _kind in sorted(ranges):
        out.append(data[pos:start])
        pos = end
    out.append(data[pos:])
    return b"".join(out)

def toml_restore_anchor(bak, pos, ranges):
    masked, _open = toml_mask(bak)
    while pos < len(bak):
        inside = next((end for start, end, _kind in ranges if start <= pos < end), None)
        if inside is not None:
            pos = inside
            continue
        nl = bak.find(b"\n", pos)
        next_pos = len(bak) if nl < 0 else nl + 1
        header = toml_header(masked[pos:next_pos])
        if header is not None:
            return header
        pos = next_pos
    return None

def toml_find_header(data, wanted):
    masked, _open = toml_mask(data)
    pos = 0
    while pos < len(data):
        nl = data.find(b"\n", pos)
        next_pos = len(data) if nl < 0 else nl + 1
        if toml_header(masked[pos:next_pos]) == wanted:
            return pos
        pos = next_pos
    return len(data)

def toml_restore_ranges(stripped, bak, ranges):
    base = toml_remove_ranges(bak, ranges)
    if stripped == base or (stripped == base + b"\n" and not base.endswith(b"\n")):
        return bak
    new = stripped
    for start, end, _kind in sorted(ranges):
        anchor = toml_restore_anchor(bak, end, ranges)
        at = toml_find_header(new, anchor) if anchor is not None else len(new)
        if anchor is not None and at == len(new):
            label = "[[" + anchor[2:].decode("utf-8") + "]]" if anchor.startswith(b"[]") else anchor.decode("utf-8")
            sys.stderr.write("Предупреждение: заголовок %s не найден, восстанавливаю taskless в конец TOML.\n" % label)
        sep = b""
        if at > 0 and new[at - 1:at] != b"\n":
            sep = b"\r\n" if b"\r\n" in new else b"\n"
        new = new[:at] + sep + bak[start:end] + new[at:]
    return new

def toml_validate(path, data, installed=True):
    masked, open_string = toml_mask(data)
    if open_string:
        sys.stderr.write("Не смог разобрать итоговый TOML %s: незакрытая строка. Файл не меняю.\n" % path)
        sys.exit(1)
    try:
        import tomllib
    except ImportError:
        tomllib = None
    if tomllib is not None:
        try:
            tomllib.loads(data.decode("utf-8"))
        except Exception as err:
            sys.stderr.write("Не смог разобрать итоговый TOML %s: %s. Файл не меняю.\n" % (path, err))
            sys.exit(1)
    if installed:
        counts = {"mcp": 0, "plugin": 0}
        for _start, _end, kind in toml_taskless_ranges(data):
            counts[kind] += 1
        root_inline = False
        pos = 0
        while pos < len(masked):
            nl = masked.find(b"\n", pos)
            next_pos = len(masked) if nl < 0 else nl + 1
            line = masked[pos:next_pos]
            if toml_header(line) is not None:
                break
            if re.match(br"^[ \t]*mcp_servers[ \t]*=[ \t]*\{", line):
                root_inline = True
                break
            pos = next_pos
        if counts != {"mcp": 1, "plugin": 1} or root_inline:
            sys.stderr.write("В итоговом TOML %s дублируется taskless. Файл не меняю.\n" % path)
            sys.exit(1)

def apply_block(path, begin, end, inner, dry, mode):
    begin_b = (begin + "\n").encode()
    end_b = (end + "\n").encode()
    if inner and not inner.endswith(b"\n"):
        inner += b"\n"
    block = begin_b + inner + end_b
    exists = os.path.isfile(path)
    old = open(path, "rb").read() if exists else None
    if old is None:
        new = block
    else:
        bpos, blen = find_mark(old, begin.encode(), 0)
        if bpos < 0:
            ranges = toml_taskless_ranges(old) if begin == "# >>> taskless:codex" else []
            base = toml_remove_ranges(old, ranges) if ranges else old
            sep = b"" if base.endswith(b"\n") or base == b"" else b"\n"
            new = base + sep + block
        else:
            epos, elen = find_mark(old, end.encode(), bpos + blen)
            if epos < 0:
                sys.stderr.write("В файле %s есть метка начала и нет метки конца. Файл не меняю.\n" % path)
                sys.exit(1)
            new = old[:bpos] + block + old[epos + elen:]
    changed = old != new
    if not changed:
        emit_edit(False, "", False, False)
        return
    if begin == "# >>> taskless:codex" and b"[mcp_servers.taskless]" in inner:
        toml_validate(path, new)
    bak = path + ".bak-taskless"
    backup = ""
    if old is not None and not os.path.exists(bak):
        backup = bak
    if dry:
        emit_edit(True, backup, old is None, False)
        return
    if backup:
        parent = os.path.dirname(path) or "."
        os.makedirs(parent, exist_ok=True)
        open(bak, "wb").write(old)
        os.chmod(bak, os.stat(path).st_mode & 0o777)
    file_mode = mode if old is None else (os.stat(path).st_mode & 0o777)
    write_atomic(path, new, file_mode)
    emit_edit(True, backup, old is None, False)

def remove_block(path, begin, end, dry, mode):
    if not os.path.isfile(path):
        emit_edit(False, "", False, False)
        return
    old = open(path, "rb").read()
    bpos, blen = find_mark(old, begin.encode(), 0)
    if bpos < 0:
        emit_edit(False, "", False, False)
        return
    epos, elen = find_mark(old, end.encode(), bpos + blen)
    if epos < 0:
        sys.stderr.write("В файле %s есть метка начала и нет метки конца. Файл не меняю.\n" % path)
        sys.exit(1)
    stripped = old[:bpos] + old[epos + elen:]
    bak_path = path + ".bak-taskless"
    bak = open(bak_path, "rb").read() if os.path.isfile(bak_path) else None
    original = toml_taskless_ranges(bak) if bak is not None and begin == "# >>> taskless:codex" else []
    new = toml_restore_ranges(stripped, bak, original) if original else stripped
    if bak is not None and (stripped == bak or (stripped == bak + b"\n" and not bak.endswith(b"\n"))):
        new = bak
    if begin == "# >>> taskless:codex":
        toml_validate(path, new, False)
    if dry:
        # Пустую копию возвращаем пустым файлом, а не удалением.
        emit_edit(True, "", False, new == b"" and bak is None)
        return
    deleted = False
    if new == b"" and bak is None:
        os.remove(link_dest(path))
        deleted = True
    else:
        write_atomic(path, new, os.stat(path).st_mode & 0o777)
    if bak is not None and new == bak and os.path.isfile(bak_path):
        os.remove(bak_path)
    emit_edit(True, "", False, deleted)

def json_parse(raw, path):
    if not raw or not raw.strip():
        return {}
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        sys.stderr.write("Не смог разобрать JSON %s. Файл не меняю.\n" % path)
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("В JSON %s жду объект в корне. Файл не меняю.\n" % path)
        sys.exit(1)
    return data

def json_read(path):
    raw = open(path, "rb").read() if os.path.isfile(path) else None
    return raw, json_parse(raw, path)

def json_server():
    return {
        "type": "http",
        "url": os.environ.get("TASKLESS_MCP_URL", ""),
        "headersHelper": os.environ.get("TASKLESS_HEADER_COMMAND", ""),
    }

def json_taskless_owned(server):
    if not isinstance(server, dict) or not isinstance(server.get("headersHelper"), str):
        return False
    helper_path = os.path.join(os.environ.get("HOME", ""), ".config", "taskless", "mcp-headers")
    return helper_path in server["headersHelper"]

def json_dump(data):
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

def json_apply(path, dry):
    raw, data = json_read(path)
    servers = data.get("mcpServers")
    if servers is None:
        servers = {}
        data["mcpServers"] = servers
    if not isinstance(servers, dict):
        sys.stderr.write("В JSON %s ключ mcpServers не объект. Файл не меняю.\n" % path)
        sys.exit(1)
    wanted = json_server()
    if servers.get("taskless") == wanted:
        emit_edit(False, "", False, False)
        return
    servers["taskless"] = wanted
    bak = path + ".bak-taskless"
    backup = bak if raw is not None and not os.path.isfile(bak) else ""
    if dry:
        emit_edit(True, backup, raw is None, False)
        return
    if backup:
        open(bak, "wb").write(raw)
        os.chmod(bak, os.stat(path).st_mode & 0o777)
    mode = os.stat(path).st_mode & 0o777 if raw is not None else 0o600
    write_atomic(path, json_dump(data), mode)
    emit_edit(True, backup, raw is None, False)

def json_remove(path, dry):
    if not os.path.isfile(path):
        emit_edit(False, "", False, False)
        return
    raw, data = json_read(path)
    servers = data.get("mcpServers")
    if not isinstance(servers, dict) or not json_taskless_owned(servers.get("taskless")):
        emit_edit(False, "", False, False)
        return
    bak_path = path + ".bak-taskless"
    bak_raw = open(bak_path, "rb").read() if os.path.isfile(bak_path) else None
    bak_data = json_parse(bak_raw, bak_path) if bak_raw is not None else None
    del servers["taskless"]
    bak_servers = bak_data.get("mcpServers") if bak_data is not None else None
    if isinstance(bak_servers, dict) and "taskless" in bak_servers:
        servers["taskless"] = bak_servers["taskless"]
    if not servers and (bak_data is None or not bak_data.get("mcpServers")):
        del data["mcpServers"]
    if dry:
        emit_edit(True, "", False, bak_data is None and data == {})
        return
    deleted = False
    if bak_data is None and data == {}:
        os.remove(link_dest(path))
        deleted = True
    elif bak_raw is not None and data == bak_data:
        write_atomic(path, bak_raw, os.stat(path).st_mode & 0o777)
    else:
        write_atomic(path, json_dump(data), os.stat(path).st_mode & 0o777)
    if bak_raw is not None:
        os.remove(bak_path)
    emit_edit(True, "", False, deleted)

def json_status(path):
    if not os.path.isfile(path):
        emit_edit(False, "", False, False)
        return
    _raw, data = json_read(path)
    servers = data.get("mcpServers")
    connected = isinstance(servers, dict) and json_taskless_owned(servers.get("taskless"))
    emit_edit(connected, "", False, False)

def toml_block():
    url = json.dumps(os.environ.get("TASKLESS_MCP_URL", ""), ensure_ascii=False)
    command = json.dumps(os.environ.get("TASKLESS_HEADER_COMMAND", ""), ensure_ascii=False)
    sys.stdout.write("[mcp_servers.taskless]\n")
    sys.stdout.write("url = %s\n" % url)
    sys.stdout.write("http_headers_helper = %s\n\n" % command)
    sys.stdout.write('[plugins."taskless@taskless-app".mcp_servers.taskless]\n')
    sys.stdout.write("enabled = false\n")

def meta_write():
    path = sys.argv[2]
    agents = [a for a in os.environ.get("TASKLESS_AGENTS", "").split(",") if a]
    data = {
        "device_name": os.environ.get("TASKLESS_DEVICE_NAME", ""),
        "platform": os.environ.get("TASKLESS_PLATFORM", ""),
        "store": os.environ.get("TASKLESS_STORE", ""),
        "agents": agents,
    }
    raw = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
        os.chmod(parent, 0o700)
    write_atomic(path, raw, 0o600)
    sys.stdout.write("changed=1\n")

def meta_read():
    path = sys.argv[2]
    data = {}
    if os.path.isfile(path):
        try:
            data = json.loads(open(path, encoding="utf-8").read())
        except Exception:
            data = {}
    if not isinstance(data, dict):
        data = {}
    agents = data.get("agents") or []
    if not isinstance(agents, list):
        agents = []
    sys.stdout.write("device_name=%s\n" % str(data.get("device_name") or "").replace("\n", " "))
    sys.stdout.write("platform=%s\n" % str(data.get("platform") or "").replace("\n", " "))
    sys.stdout.write("store=%s\n" % str(data.get("store") or "").replace("\n", " "))
    sys.stdout.write("agents=%s\n" % ",".join(str(a) for a in agents))

def emit_memory_field(key, value):
    sys.stdout.write("%s=%s\n" % (key, str(value if value is not None else "").replace("\n", " ").replace("\r", "")))

def server_message(payload, net=""):
    if net:
        return net
    if isinstance(payload, dict):
        for key in ("message", "error", "detail"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
    return "неизвестная ошибка сервера"

def memory_state():
    status, retry, net, payload = request("GET", base() + "/memory/personal/settings", None, os.environ.get("TASKLESS_TOKEN", ""))
    state = payload.get("state") if isinstance(payload, dict) else None
    emit_memory_field("status", status)
    emit_memory_field("net_error", net)
    emit_memory_field("memory_state", state if state in ("on", "off") else "")
    emit_memory_field("server_message", server_message(payload, net) if status != 200 else "")

def memory_set(value):
    status, retry, net, payload = request("PUT", base() + "/memory/personal/settings", {"enabled": value == "on"}, os.environ.get("TASKLESS_TOKEN", ""))
    if status != 200:
        sys.stderr.write(server_message(payload, net) + "\n")
        sys.exit(1)
    emit_memory_field("status", status)

SECRET_WORDS = {"password", "passwd", "пароль", "token", "secret", "apikey", "ключ"}
SECRET_KEY_OWNERS = {"api", "secret", "access"}
SECRET_PLACEHOLDER = re.compile(r"^(?:true|false|null|none|undefined|empty|redacted|x+|\*+|\.+)$", re.I)
NOT_SECRET_VALUE = re.compile(r"^(?:@?[A-Z][A-Z0-9]*-\d+|v?\d+(?:\.\d+)+(?:[-+][\w.]+)?|\d{4}-\d{2}-\d{2}(?:[T ]?[\d:.]+Z?)?|\d{1,2}:\d{2}(?::\d{2})?)$")

def is_secret_name(name):
    split = re.sub(r"([a-zа-яё0-9])([A-ZА-ЯЁ])", r"\1_\2", name)
    split = re.sub(r"([A-ZА-ЯЁ])([A-ZА-ЯЁ][a-zа-яё])", r"\1_\2", split).lower()
    words = [word for word in re.split(r"[_-]+", split) if word]
    if not words:
        return False
    if words[-1] in SECRET_WORDS:
        return True
    return words[-1] == "key" and len(words) > 1 and words[-2] in SECRET_KEY_OWNERS

def accept_assigned_secret(value, match):
    if not is_secret_name(match.group("name")):
        return False
    if SECRET_PLACEHOLDER.match(value) or re.match(r"^[$%{<]", value) or value.startswith("process.env"):
        return False
    if NOT_SECRET_VALUE.match(value):
        return False
    if match.group("sep") == "=":
        return len(value) >= 4
    return len(value) >= 6 and any(not ch.isalpha() for ch in value)

L = r"(?<![A-Za-z0-9_])"
R = r"(?![A-Za-z0-9_])"
SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"), None),
    (re.compile(L + r"(?:tlswarm|tldev|tlsec|tldc|tla|tlr|tlc)_[A-Za-z0-9_-]{20,}"), None),
    (re.compile(L + r"gh[pousr]_[A-Za-z0-9]{30,}" + R), None),
    (re.compile(L + r"github_pat_[A-Za-z0-9_]{22,}"), None),
    (re.compile(L + r"sk-ant-[A-Za-z0-9_-]{20,}"), None),
    (re.compile(L + r"sk-[A-Za-z0-9_-]{20,}"), "digit"),
    (re.compile(L + r"(?:AKIA|ASIA)[A-Z0-9]{16}" + R), None),
    (re.compile(L + r"xox[abprs]-[A-Za-z0-9-]{10,}"), None),
    (re.compile(L + r"AIza[A-Za-z0-9_-]{35}"), None),
    (re.compile(L + r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"), None),
    (re.compile(r"(?<![A-Za-z0-9_])[Bb]earer[ \t]+(?P<secret>[A-Za-z0-9._~+/-]{16,}=*)"), "digit"),
    (re.compile(r"(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*://[^\s/:@]+:(?P<secret>[^\s/@]+)@", re.I), None),
    (re.compile(r"(?<![\w-])(?P<name>[\w-]*?(?:password|passwd|пароль|token|secret|key|ключ))[\"']?[ \t]*(?P<sep>=|:)[ \t]*[\"']?(?P<secret>[\x21-\x7e]+?)(?=[\"'`,;&<>)\]}]|\s|$)", re.I), accept_assigned_secret),
]

def line_has_secret(line):
    for pattern, accept in SECRET_PATTERNS:
        for match in pattern.finditer(line):
            value = match.groupdict().get("secret") or match.group(0)
            if accept is None:
                return True
            if accept == "digit" and re.search(r"[0-9]", value):
                return True
            if callable(accept) and accept(value, match):
                return True
    return False

def pretty_path(path, home):
    path = os.path.abspath(path)
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~/" + path[len(home) + 1:].replace(os.sep, "/")
    return path

def pretty_size(size):
    if size < 1024:
        return "%d Б" % size
    if size < 1024 * 1024:
        return "%d КБ" % int(size / 1024 + 0.5)
    tenths = int(size * 10 / (1024 * 1024) + 0.5)
    return "%d,%d МБ" % (tenths // 10, tenths % 10)

def pretty_count(count, words=("файл", "файла", "файлов")):
    mod10 = count % 10
    mod100 = count % 100
    if mod10 == 1 and mod100 != 11:
        word = words[0]
    elif 2 <= mod10 <= 4 and not 12 <= mod100 <= 14:
        word = words[1]
    else:
        word = words[2]
    return "%d %s" % (count, word)

def skip_reason(name):
    lower = name.lower()
    if lower.startswith(".env") or lower.startswith("id_") or any(word in lower for word in ("secret", "credential", "token")):
        return "похоже на ключи"
    if lower.endswith((".pem", ".key", ".p12", ".pfx")):
        return "похоже на ключи"
    if not lower.endswith((".md", ".markdown", ".txt")):
        return "не текст"
    return None

def inspect_memory_file(path, home, skipped, secrets):
    name = os.path.basename(path)
    shown = pretty_path(path, home)
    if os.path.islink(path):
        skipped.append((shown, "симлинк"))
        return None
    reason = skip_reason(name)
    if reason:
        skipped.append((shown, reason))
        return None
    try:
        size = os.path.getsize(path)
        if size > 256 * 1024:
            skipped.append((shown, "больше 256 КБ"))
            return None
        with open(path, "rb") as source:
            data = source.read()
        if b"\0" in data[:8192]:
            skipped.append((shown, "не текст"))
            return None
        text = data.decode("utf-8", "replace")
        in_private_key = False
        for number, line in enumerate(text.splitlines(), 1):
            begins = re.search(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", line)
            ends = re.search(r"-----END [A-Z0-9 ]*PRIVATE KEY-----", line)
            if in_private_key or begins or line_has_secret(line):
                secrets.append((shown, number))
            if in_private_key and ends:
                in_private_key = False
            if begins and not ends:
                in_private_key = True
        return size
    except Exception:
        skipped.append((shown, "не прочитал"))
        return None

def walk_memory_dir(root, home, skipped, secrets):
    count = 0
    total = 0
    try:
        entries = sorted(os.scandir(root), key=lambda entry: entry.name)
    except Exception:
        skipped.append((pretty_path(root, home), "не прочитал"))
        return count, total
    for entry in entries:
        path = entry.path
        shown = pretty_path(path, home)
        try:
            if entry.is_symlink():
                skipped.append((shown, "симлинк"))
                continue
            if entry.is_dir(follow_symlinks=False):
                if entry.name.startswith("."):
                    skipped.append((shown + "/", "скрытая папка"))
                elif entry.name == "node_modules":
                    skipped.append((shown + "/", "node_modules"))
                else:
                    subcount, subtotal = walk_memory_dir(path, home, skipped, secrets)
                    count += subcount
                    total += subtotal
                continue
            if not entry.is_file(follow_symlinks=False):
                continue
            if entry.name in ("CLAUDE.md", "AGENTS.md"):
                skipped.append((shown, "правила команды"))
                continue
            size = inspect_memory_file(path, home, skipped, secrets)
            if size is not None:
                count += 1
                total += size
        except Exception:
            skipped.append((shown, "не прочитал"))
    return count, total

def custom_memory_dirs(home):
    dirs = []
    seen = set()
    for raw in os.environ.get("TASKLESS_MEMORY_DIRS", "").splitlines():
        if not raw:
            continue
        path = os.path.abspath(os.path.expanduser(raw))
        if path in seen:
            continue
        seen.add(path)
        dirs.append((path, raw))
    return dirs

def validate_memory_dirs():
    home = os.path.abspath(os.environ.get("HOME", ""))
    for path, raw in custom_memory_dirs(home):
        if not os.path.isdir(path):
            raise ValueError("Нет такой папки: %s" % raw)

def secret_ranges(secrets):
    ranges = []
    for path, number in secrets:
        if ranges and ranges[-1][0] == path and ranges[-1][2] == number - 1:
            ranges[-1][2] = number
        else:
            ranges.append([path, number, number])
    return ranges

def memory_scan(output):
    home = os.path.abspath(os.environ.get("HOME", ""))
    validate_memory_dirs()
    files = [
        (os.path.join(home, ".claude", "CLAUDE.md"), "правила"),
        (os.path.join(home, ".codex", "AGENTS.md"), "правила"),
    ]
    claude_dirs = []
    projects = os.path.join(home, ".claude", "projects")
    try:
        for entry in sorted(os.scandir(projects), key=lambda item: item.name):
            memory = os.path.join(entry.path, "memory")
            if not entry.is_symlink() and entry.is_dir(follow_symlinks=False) and os.path.isdir(memory) and not os.path.islink(memory):
                claude_dirs.append(memory)
    except Exception:
        pass
    dirs = [(os.path.join(home, ".codex", name), "память Codex") for name in ("memories", "memories_v2")]
    dirs += [(path, "твоя папка") for path, raw in custom_memory_dirs(home)]
    rows = []
    skipped = []
    secrets = []
    total = 0
    for path, label in files:
        if os.path.exists(path) or os.path.islink(path):
            size = inspect_memory_file(path, home, skipped, secrets)
            if size is not None:
                rows.append("  %s — %s, %s" % (pretty_path(path, home), pretty_size(size), label))
                total += size
    claude_count = 0
    claude_size = 0
    for path in claude_dirs:
        count, size = walk_memory_dir(path, home, skipped, secrets)
        claude_count += count
        claude_size += size
    if claude_count:
        rows.append("  ~/.claude/projects/…/memory/ — %s, %s, память Claude Code" % (pretty_count(claude_count), pretty_size(claude_size)))
        total += claude_size
    for path, label in dirs:
        if not os.path.exists(path) and not os.path.islink(path):
            continue
        if os.path.islink(path):
            skipped.append((pretty_path(path, home), "симлинк"))
            continue
        count, size = walk_memory_dir(path, home, skipped, secrets)
        if count:
            rows.append("  %s/ — %s, %s, %s" % (pretty_path(path, home), pretty_count(count), pretty_size(size), label))
            total += size
    lines = list(rows)
    if rows:
        lines.append("Всего %s. Агент за раз читает до 200 КБ, остальное — по выбору человека." % pretty_size(total))
    if skipped:
        skipped_text = "; ".join("%s — %s" % item for item in skipped[:10])
        if len(skipped) > 10:
            skipped_text += "; и ещё %d" % (len(skipped) - 10)
        lines.append("Пропущены: " + skipped_text + ".")
    for path, first, last in secret_ranges(secrets):
        if first == last:
            lines.append("Похоже на секрет: %s, строка %d. Эту строку в записи не бери." % (path, first))
        else:
            lines.append("Похоже на секрет: %s, строки %d–%d. Эти строки в записи не бери." % (path, first, last))
    with open(output, "w", encoding="utf-8") as report:
        report.write("\n".join(lines) + ("\n" if lines else ""))
    emit_memory_field("memory_found", 1 if rows else 0)

IMPORT_KINDS = {"fact", "rule", "decision", "promise"}
IMPORT_SOURCES = {"instructions", "agent_memory", "notes"}
IMPORT_CLIENTS = {"claude-code", "codex", "grok", "zcode", "cursor", "gemini", "other"}
IMPORT_MODIFIED_AT = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$")

def valid_modified_at(value):
    if not isinstance(value, str) or not IMPORT_MODIFIED_AT.match(value):
        return False
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False

def read_import_batch(path):
    try:
        with open(path, encoding="utf-8") as source:
            batch = json.load(source)
    except Exception as err:
        raise ValueError("Не прочитал JSON %s: %s" % (path, err))
    if not isinstance(batch, dict) or not isinstance(batch.get("files"), list):
        raise ValueError("Не тот формат %s: нужен объект с массивом files" % path)
    if "client" in batch and batch["client"] not in IMPORT_CLIENTS:
        raise ValueError("Не тот формат %s: неизвестный client" % path)
    for file_index, file in enumerate(batch["files"], 1):
        where = "файл %d" % file_index
        if not isinstance(file, dict):
            raise ValueError("%s: нужен объект" % where)
        if not isinstance(file.get("path"), str) or not 1 <= len(file["path"]) <= 500:
            raise ValueError("%s: path — строка от 1 до 500 знаков" % where)
        if file.get("source") not in IMPORT_SOURCES:
            raise ValueError("%s: source — instructions, agent_memory или notes" % where)
        if "modifiedAt" in file and not valid_modified_at(file["modifiedAt"]):
            raise ValueError("%s: modifiedAt — дата ISO 8601 с часовым поясом" % where)
        if not isinstance(file.get("items"), list):
            raise ValueError("%s: items — массив записей" % where)
        if len(file["items"]) > 300:
            raise ValueError("%s: больше 300 записей, раздели их между файлами" % where)
        for item_index, item in enumerate(file["items"], 1):
            place = "%s, запись %d" % (where, item_index)
            if not isinstance(item, dict) or not isinstance(item.get("statement"), str):
                raise ValueError("%s: statement — строка" % place)
            if "kind" in item and item["kind"] not in IMPORT_KINDS:
                raise ValueError("%s: kind — fact, rule, decision или promise" % place)
            if "quote" in item and not isinstance(item["quote"], str):
                raise ValueError("%s: quote — строка" % place)
    if sum(len(file["items"]) for file in batch["files"]) == 0:
        raise ValueError("Пустая пачка %s: нужна хотя бы одна запись" % path)
    return batch

def import_batches(batch):
    batches = []
    current = []
    count = 0
    for file in batch["files"]:
        size = len(file["items"])
        if current and count + size > 300:
            batches.append(current)
            current = []
            count = 0
        current.append(file)
        count += size
    if current:
        batches.append(current)
    return batches

def write_import_report(output, reports, dry_files=None):
    if dry_files is not None:
        total_items = sum(len(file["items"]) for file in dry_files)
        lines = ["Проверка: ушло бы %s, запросов не отправил." % pretty_count(total_items, ("запись", "записи", "записей"))]
        lines += ["  %s — %s" % (file["path"], pretty_count(len(file["items"]), ("запись", "записи", "записей"))) for file in dry_files]
    else:
        total = {key: sum(int(report.get(key, 0)) for report in reports) for key in ("new", "known", "duplicate", "skipped")}
        lines = ["Взял новых: %d. Уже было: %d. Повтор: %d. Пропущено: %d" % (total["new"], total["known"], total["duplicate"], total["skipped"])]
        reason_names = [("secret", "секрет"), ("too_long", "длиннее 300 знаков"), ("empty", "пусто"), ("rule_without_quote", "правило без цитаты"), ("retracted", "ты это раньше удалил"), ("error", "ошибка")]
        reasons = []
        for key, label in reason_names:
            count = sum(int((report.get("skippedByReason") or {}).get(key, 0)) for report in reports)
            if count:
                reasons.append("%s — %d" % (label, count))
        if reasons:
            lines.append("Причины пропусков: " + "; ".join(reasons))
        for report in reports:
            for file in report.get("files") or []:
                lines.append("  %s — новых %d, уже было %d, повтор %d, пропущено %d" % (file.get("file", ""), int(file.get("new", 0)), int(file.get("known", 0)), int(file.get("duplicate", 0)), int(file.get("skipped", 0))))
    with open(output, "w", encoding="utf-8") as target:
        # Путь из ответа сервера может нести одиночный суррогат. В отчёте,
        # как у node, он становится U+FFFD, иначе запись utf-8 падает.
        target.write(re.sub("[\ud800-\udfff]", "\ufffd", "\n".join(lines)) + "\n")

def memory_import(path, output, dry):
    batch = read_import_batch(path)
    if dry:
        write_import_report(output, [], batch["files"])
        return
    reports = []
    sent = 0
    total_items = sum(len(file["items"]) for file in batch["files"])
    for files in import_batches(batch):
        payload = {"files": files}
        if "client" in batch:
            payload["client"] = batch["client"]
        status, retry, net, body = request("POST", base() + "/memory/personal/import", payload, os.environ.get("TASKLESS_TOKEN", ""))
        if status != 200:
            if reports:
                write_import_report(output, reports)
                with open(output, "a", encoding="utf-8") as target:
                    target.write("Отправил %d из %s, дальше остановился:\n" % (sent, pretty_count(total_items, ("запись", "записи", "записей"))))
            raise ValueError(server_message(body, net))
        reports.append(body)
        sent += sum(len(file["items"]) for file in files)
    write_import_report(output, reports)

def main():
    cmd = sys.argv[1]
    if cmd == "device_start":
        status, retry, net, payload = request("POST", base() + "/oauth/device_authorization", device_payload())
        emit_http(status, retry, net, payload)
    elif cmd == "poll":
        body = {
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": os.environ.get("TASKLESS_DEVICE_CODE", ""),
            "client_id": "taskless-device",
        }
        status, retry, net, payload = request("POST", base() + "/oauth/token", body)
        emit_http(status, retry, net, payload)
    elif cmd == "me":
        status, retry, net, payload = request("GET", base() + "/auth/me", None, os.environ.get("TASKLESS_TOKEN", ""))
        emit_http(status, retry, net, payload)
    elif cmd == "revoke":
        body = {"token": os.environ.get("TASKLESS_TOKEN", ""), "client_id": "taskless-device"}
        status, retry, net, payload = request("POST", base() + "/oauth/revoke", body)
        emit_http(status, retry, net, payload)
    elif cmd == "edit":
        action, path, begin, end, dry, mode_s = sys.argv[2:8]
        mode = int(mode_s, 8)
        if action == "apply":
            apply_block(path, begin, end, sys.stdin.buffer.read(), dry == "1", mode)
        elif action == "remove":
            remove_block(path, begin, end, dry == "1", mode)
        else:
            sys.stderr.write("edit: не знаю действие\n")
            sys.exit(1)
    elif cmd == "json":
        action, path, dry = sys.argv[2:5]
        if action == "apply":
            json_apply(path, dry == "1")
        elif action == "remove":
            json_remove(path, dry == "1")
        elif action == "status":
            json_status(path)
        else:
            sys.stderr.write("json: не знаю действие\n")
            sys.exit(1)
    elif cmd == "toml_block":
        toml_block()
    elif cmd == "meta_write":
        meta_write()
    elif cmd == "meta_read":
        meta_read()
    elif cmd == "memory_state":
        memory_state()
    elif cmd == "memory_set":
        memory_set(sys.argv[2])
    elif cmd == "memory_validate_dirs":
        try:
            validate_memory_dirs()
        except ValueError as err:
            sys.stderr.write(str(err) + "\n")
            sys.exit(1)
    elif cmd == "memory_scan":
        memory_scan(sys.argv[2])
    elif cmd == "memory_import":
        try:
            memory_import(sys.argv[2], sys.argv[3], sys.argv[4] == "1")
        except ValueError as err:
            sys.stderr.write(str(err) + "\n")
            sys.exit(1)
    else:
        sys.stderr.write("не знаю команду\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
TASKLESS_CONNECT_PY_END
  else
    HELPER="$raw.mjs"
    mv "$raw" "$HELPER"
    cat > "$HELPER" <<'TASKLESS_CONNECT_NODE_END'
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, chmodSync, unlinkSync, statSync, lstatSync, readlinkSync, openSync, closeSync, fchmodSync, writeSync, renameSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { randomBytes } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";

const OS_RE = /^[0-9A-Za-z .()_-]{1,32}$/;
const PLATFORMS = new Set(["macos", "linux", "windows"]);

function cleanName(raw) {
  const text = String(raw || "")
    .replace(/[\u0000-\u001f]/g, " ")
    .replace(/[<>]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  const cut = Array.from(text).slice(0, 64).join("");
  return cut || "computer";
}

function parseJson(raw) {
  if (!raw) return {};
  try {
    const data = JSON.parse(raw);
    return data && typeof data === "object" && !Array.isArray(data) ? data : {};
  } catch {
    return {};
  }
}

function field(v) {
  if (v === undefined || v === null) return "";
  return String(v).replace(/\n/g, " ").replace(/\r/g, "");
}

function emitHttp(status, retry, net, payload) {
  const body = payload && typeof payload === "object" ? payload : {};
  const lines = [
    ["status", status],
    ["retry_after", retry || ""],
    ["net_error", net || ""],
    ["oauth_error", body.error || ""],
    ["access_token", body.access_token || ""],
    ["user_code", body.user_code || ""],
    ["device_code", body.device_code || ""],
    ["verification_uri_complete", body.verification_uri_complete || ""],
    ["expires_in", Object.prototype.hasOwnProperty.call(body, "expires_in") ? body.expires_in : ""],
    ["interval", Object.prototype.hasOwnProperty.call(body, "interval") ? body.interval : ""],
  ];
  for (const [key, value] of lines) process.stdout.write(`${key}=${field(value)}\n`);
}

function request(method, url, payload, token) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    let parsed;
    try {
      parsed = new URL(url);
    } catch (err) {
      finish({ status: 0, retry: "", net: String(err), payload: {} });
      return;
    }
    const body =
      payload !== undefined && payload !== null ? Buffer.from(JSON.stringify(payload), "utf8") : null;
    const headers = { accept: "application/json" };
    if (body) {
      headers["content-type"] = "application/json";
      headers["content-length"] = String(body.length);
    }
    if (token) headers.authorization = "Bearer " + token;
    const lib = parsed.protocol === "https:" ? httpsRequest : httpRequest;
    const req = lib(
      {
        protocol: parsed.protocol,
        hostname: parsed.hostname,
        port: parsed.port,
        path: `${parsed.pathname}${parsed.search}`,
        method,
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const retry = res.headers["retry-after"];
          finish({
            status: res.statusCode || 0,
            retry: Array.isArray(retry) ? retry[0] || "" : retry || "",
            net: "",
            payload: parseJson(Buffer.concat(chunks).toString("utf8")),
          });
        });
      },
    );
    req.setTimeout(30000, () => {
      req.destroy(new Error("timeout"));
    });
    req.on("error", (err) => {
      finish({ status: 0, retry: "", net: String(err), payload: {} });
    });
    if (body) req.end(body);
    else req.end();
  });
}

function apiBase() {
  return (process.env.TASKLESS_BASE || "").replace(/\/+$/, "");
}

function devicePayload() {
  const agents = (process.env.TASKLESS_AGENTS || "").split(",").filter(Boolean);
  const payload = {
    client_id: "taskless-device",
    device_name: cleanName(process.env.TASKLESS_DEVICE_NAME || ""),
    agents,
    client_version: process.env.TASKLESS_CLIENT_VERSION || "0.1.0",
  };
  const platform = process.env.TASKLESS_PLATFORM || "";
  if (PLATFORMS.has(platform)) payload.platform = platform;
  const osVersion = process.env.TASKLESS_OS_VERSION || "";
  if (OS_RE.test(osVersion)) payload.os_version = osVersion;
  return payload;
}

function findLine(data, needle, start) {
  let pos = start;
  while (pos <= data.length) {
    const i = data.indexOf(needle, pos);
    if (i < 0) return -1;
    if (i === 0 || data[i - 1] === 0x0a) return i;
    pos = i + 1;
  }
  return -1;
}

// Строка-метка с \n, \r\n или в конце файла без перевода. Ближняя из трёх.
function findMark(data, mark, start) {
  let best = { pos: -1, len: 0 };
  for (const nl of ["\n", "\r\n"]) {
    const needle = Buffer.from(mark + nl);
    const i = findLine(data, needle, start);
    if (i >= 0 && (best.pos < 0 || i < best.pos)) best = { pos: i, len: needle.length };
  }
  const needle = Buffer.from(mark);
  const i = findLine(data, needle, start);
  if (i >= 0 && i + needle.length === data.length && (best.pos < 0 || i < best.pos)) best = { pos: i, len: needle.length };
  return best;
}

// Конфиг-симлинк (stow): пишем и удаляем цель, саму ссылку не трогаем.
// По цепочке readlinkSync, а не realpathSync: тот на битой ссылке бросает.
function linkDest(path) {
  let cur = path;
  for (let i = 0; i < 40; i++) {
    let st;
    try {
      st = lstatSync(cur);
    } catch {
      return cur;
    }
    if (!st.isSymbolicLink()) return cur;
    cur = resolve(dirname(cur), readlinkSync(cur));
  }
  return cur;
}

function writeAtomic(path, data, mode) {
  const dest = linkDest(path);
  const parent = dirname(dest) || ".";
  mkdirSync(parent, { recursive: true });
  const tmp = join(parent, `.taskless-${randomBytes(6).toString("hex")}`);
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeSync(fd, data);
    fchmodSync(fd, mode);
  } catch (err) {
    closeSync(fd);
    unlinkSync(tmp);
    throw err;
  }
  closeSync(fd);
  renameSync(tmp, dest);
}

function emitEdit(changed, backup, created, deleted) {
  process.stdout.write(`changed=${changed ? 1 : 0}\n`);
  process.stdout.write(`backup=${backup}\n`);
  process.stdout.write(`created=${created ? 1 : 0}\n`);
  process.stdout.write(`deleted=${deleted ? 1 : 0}\n`);
}

function tomlKey(raw) {
  return raw.trim().replace(/[ \t]+/g, "").replaceAll('"taskless"', "taskless").replaceAll("'taskless'", "taskless");
}

function tomlKind(key) {
  if (key === "mcp_servers.taskless" || key.startsWith("mcp_servers.taskless.")) return "mcp";
  const plugin = 'plugins."taskless@taskless-app".mcp_servers.taskless';
  if (key === plugin || key.startsWith(plugin + ".")) return "plugin";
  return null;
}

function tomlHeader(line) {
  const array = line.match(/^[ \t]*\[\[([^\[\]]+)\]\][ \t]*(?:#.*)?(?:\r?\n)?$/);
  if (array) return "[]" + tomlKey(array[1]);
  const match = line.match(/^[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?(?:\r?\n)?$/);
  return match ? tomlKey(match[1]) : null;
}

function tomlMask(data) {
  const out = Buffer.from(data);
  let state = "";
  let i = 0;
  while (i < data.length) {
    const char = data[i];
    if (state === "basic" || state === "literal") {
      if (state === "basic" && char === 92) {
        i += 2;
        continue;
      }
      if (char === (state === "basic" ? 34 : 39) || char === 10) state = "";
      i += 1;
      continue;
    }
    if (state === "basic3" || state === "literal3") {
      const delimiter = state === "basic3" ? '"""' : "'''";
      if (data.subarray(i, i + 3).toString("utf8") === delimiter) {
        state = "";
        i += 3;
        continue;
      }
      if (state === "basic3" && char === 92) {
        out[i] = 32;
        if (i + 1 < data.length && data[i + 1] !== 10 && data[i + 1] !== 13) out[i + 1] = 32;
        i += 2;
        continue;
      }
      if (char !== 10 && char !== 13) out[i] = 32;
      i += 1;
      continue;
    }
    if (char === 35) {
      const nl = data.indexOf(0x0a, i);
      i = nl < 0 ? data.length : nl;
      continue;
    }
    if (char === 34 || char === 39) {
      const delimiter = char === 34 ? '"""' : "'''";
      if (data.subarray(i, i + 3).toString("utf8") === delimiter) {
        state = char === 34 ? "basic3" : "literal3";
        i += 3;
      } else {
        state = char === 34 ? "basic" : "literal";
        i += 1;
      }
      continue;
    }
    i += 1;
  }
  return { masked: out, open: state };
}

function tomlAssignmentEnd(masked, pos, nextPos) {
  let balance = 0;
  let scan = pos;
  let first = true;
  while (scan < masked.length) {
    const line = masked.subarray(scan, nextPos).toString("utf8");
    const eq = first ? line.indexOf("=") : -1;
    const rhs = (eq >= 0 ? line.slice(eq + 1) : line).replace(/"(?:\\.|[^"\\])*"|'[^']*'/g, "").split("#", 1)[0];
    for (const char of rhs) {
      if (char === "[" || char === "{") balance += 1;
      if (char === "]" || char === "}") balance -= 1;
    }
    if (balance <= 0) return nextPos;
    first = false;
    scan = nextPos;
    const nl = masked.indexOf(0x0a, scan);
    nextPos = nl < 0 ? masked.length : nl + 1;
  }
  return masked.length;
}

function tomlTasklessRanges(data) {
  const { masked } = tomlMask(data);
  const ranges = [];
  let section = "";
  let pos = 0;
  while (pos < data.length) {
    const nl = data.indexOf(0x0a, pos);
    const nextPos = nl < 0 ? data.length : nl + 1;
    const line = masked.subarray(pos, nextPos).toString("utf8");
    const header = tomlHeader(line);
    if (header !== null) {
      section = header;
      const kind = tomlKind(section);
      if (kind) {
        const start = pos;
        let end = data.length;
        let scan = nextPos;
        while (scan < data.length) {
          const scanNl = data.indexOf(0x0a, scan);
          const scanNext = scanNl < 0 ? data.length : scanNl + 1;
          const nextHeader = tomlHeader(masked.subarray(scan, scanNext).toString("utf8"));
          if (nextHeader !== null && !nextHeader.startsWith(section + ".")) {
            end = scan;
            break;
          }
          scan = scanNext;
        }
        ranges.push({ start, end, kind });
        pos = end;
        continue;
      }
    } else {
      const eq = line.indexOf("=");
      if (eq >= 0) {
        const full = (section ? section + "." : "") + tomlKey(line.slice(0, eq));
        const kind = tomlKind(full);
        if (kind) {
          const end = tomlAssignmentEnd(masked, pos, nextPos);
          ranges.push({ start: pos, end, kind });
          pos = end;
          continue;
        }
      }
    }
    pos = nextPos;
  }
  return ranges;
}

function tomlRemoveRanges(data, ranges) {
  const parts = [];
  let pos = 0;
  for (const range of [...ranges].sort((a, b) => a.start - b.start)) {
    parts.push(data.subarray(pos, range.start));
    pos = range.end;
  }
  parts.push(data.subarray(pos));
  return Buffer.concat(parts);
}

function tomlRestoreAnchor(bak, pos, ranges) {
  const { masked } = tomlMask(bak);
  while (pos < bak.length) {
    const inside = ranges.find((range) => range.start <= pos && pos < range.end);
    if (inside) {
      pos = inside.end;
      continue;
    }
    const nl = bak.indexOf(0x0a, pos);
    const nextPos = nl < 0 ? bak.length : nl + 1;
    const header = tomlHeader(masked.subarray(pos, nextPos).toString("utf8"));
    if (header !== null) return header;
    pos = nextPos;
  }
  return null;
}

function tomlFindHeader(data, wanted) {
  const { masked } = tomlMask(data);
  let pos = 0;
  while (pos < data.length) {
    const nl = data.indexOf(0x0a, pos);
    const nextPos = nl < 0 ? data.length : nl + 1;
    if (tomlHeader(masked.subarray(pos, nextPos).toString("utf8")) === wanted) return pos;
    pos = nextPos;
  }
  return data.length;
}

function tomlRestoreRanges(stripped, bak, ranges) {
  const base = tomlRemoveRanges(bak, ranges);
  const withNl = Buffer.concat([base, Buffer.from("\n")]);
  if (stripped.equals(base) || (base[base.length - 1] !== 0x0a && stripped.equals(withNl))) return bak;
  let next = stripped;
  for (const range of [...ranges].sort((a, b) => a.start - b.start)) {
    const anchor = tomlRestoreAnchor(bak, range.end, ranges);
    const at = anchor === null ? next.length : tomlFindHeader(next, anchor);
    if (anchor !== null && at === next.length) {
      const label = anchor.startsWith("[]") ? `[[${anchor.slice(2)}]]` : anchor;
      process.stderr.write(`Предупреждение: заголовок ${label} не найден, восстанавливаю taskless в конец TOML.\n`);
    }
    const sep = at > 0 && next[at - 1] !== 0x0a ? Buffer.from(next.includes(Buffer.from("\r\n")) ? "\r\n" : "\n") : Buffer.alloc(0);
    next = Buffer.concat([next.subarray(0, at), sep, bak.subarray(range.start, range.end), next.subarray(at)]);
  }
  return next;
}

function tomlValidate(path, data, installed = true) {
  const { masked, open } = tomlMask(data);
  if (open) {
    process.stderr.write(`Не смог разобрать итоговый TOML ${path}: незакрытая строка. Файл не меняю.\n`);
    process.exit(1);
  }
  if (!installed) return;
  const counts = { mcp: 0, plugin: 0 };
  for (const range of tomlTasklessRanges(data)) counts[range.kind] += 1;
  let rootInline = false;
  let pos = 0;
  while (pos < masked.length) {
    const nl = masked.indexOf(0x0a, pos);
    const nextPos = nl < 0 ? masked.length : nl + 1;
    const line = masked.subarray(pos, nextPos).toString("utf8");
    if (tomlHeader(line) !== null) break;
    if (/^[ \t]*mcp_servers[ \t]*=[ \t]*\{/.test(line)) {
      rootInline = true;
      break;
    }
    pos = nextPos;
  }
  if (counts.mcp !== 1 || counts.plugin !== 1 || rootInline) {
    process.stderr.write(`В итоговом TOML ${path} дублируется taskless. Файл не меняю.\n`);
    process.exit(1);
  }
}

function applyBlock(path, begin, end, inner, dry, mode) {
  const beginB = Buffer.from(begin + "\n");
  const endB = Buffer.from(end + "\n");
  let body = inner;
  if (body.length && body[body.length - 1] !== 0x0a) body = Buffer.concat([body, Buffer.from("\n")]);
  const block = Buffer.concat([beginB, body, endB]);
  const exists = existsSync(path) && statSync(path).isFile();
  const old = exists ? readFileSync(path) : null;
  let next;
  if (old === null) {
    next = block;
  } else {
    const b = findMark(old, begin, 0);
    if (b.pos < 0) {
      const ranges = begin === "# >>> taskless:codex" ? tomlTasklessRanges(old) : [];
      const base = ranges.length ? tomlRemoveRanges(old, ranges) : old;
      const sep = base.length === 0 || base[base.length - 1] === 0x0a ? Buffer.alloc(0) : Buffer.from("\n");
      next = Buffer.concat([base, sep, block]);
    } else {
      const e = findMark(old, end, b.pos + b.len);
      if (e.pos < 0) {
        process.stderr.write(`В файле ${path} есть метка начала и нет метки конца. Файл не меняю.\n`);
        process.exit(1);
      }
      next = Buffer.concat([old.subarray(0, b.pos), block, old.subarray(e.pos + e.len)]);
    }
  }
  const changed = old === null || !old.equals(next);
  if (!changed) {
    emitEdit(false, "", false, false);
    return;
  }
  if (begin === "# >>> taskless:codex" && inner.includes(Buffer.from("[mcp_servers.taskless]"))) tomlValidate(path, next);
  const bak = path + ".bak-taskless";
  let backup = "";
  if (old !== null && !existsSync(bak)) backup = bak;
  if (dry) {
    emitEdit(true, backup, old === null, false);
    return;
  }
  if (backup) {
    mkdirSync(dirname(path) || ".", { recursive: true });
    writeFileSync(bak, old);
    chmodSync(bak, statSync(path).mode & 0o777);
  }
  const fileMode = old === null ? mode : statSync(path).mode & 0o777;
  writeAtomic(path, next, fileMode);
  emitEdit(true, backup, old === null, false);
}

function removeBlock(path, begin, end, dry) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    emitEdit(false, "", false, false);
    return;
  }
  const old = readFileSync(path);
  const b = findMark(old, begin, 0);
  if (b.pos < 0) {
    emitEdit(false, "", false, false);
    return;
  }
  const e = findMark(old, end, b.pos + b.len);
  if (e.pos < 0) {
    process.stderr.write(`В файле ${path} есть метка начала и нет метки конца. Файл не меняю.\n`);
    process.exit(1);
  }
  const stripped = Buffer.concat([old.subarray(0, b.pos), old.subarray(e.pos + e.len)]);
  const bakPath = path + ".bak-taskless";
  const bak = existsSync(bakPath) && statSync(bakPath).isFile() ? readFileSync(bakPath) : null;
  const original = bak && begin === "# >>> taskless:codex" ? tomlTasklessRanges(bak) : [];
  let next = original.length ? tomlRestoreRanges(stripped, bak, original) : stripped;
  if (bak && (stripped.equals(bak) || (stripped.equals(Buffer.concat([bak, Buffer.from("\n")])) && bak[bak.length - 1] !== 0x0a))) {
    next = bak;
  }
  if (begin === "# >>> taskless:codex") tomlValidate(path, next, false);
  if (dry) {
    // Пустую копию возвращаем пустым файлом, а не удалением.
    emitEdit(true, "", false, next.length === 0 && !bak);
    return;
  }
  let deleted = false;
  if (next.length === 0 && !bak) {
    unlinkSync(linkDest(path));
    deleted = true;
  } else {
    writeAtomic(path, next, statSync(path).mode & 0o777);
  }
  if (bak && next.equals(bak) && existsSync(bakPath)) unlinkSync(bakPath);
  emitEdit(true, "", false, deleted);
}

function jsonParse(raw, path) {
  if (!raw || !raw.toString("utf8").trim()) return {};
  let data;
  try {
    data = JSON.parse(raw.toString("utf8"));
  } catch {
    process.stderr.write(`Не смог разобрать JSON ${path}. Файл не меняю.\n`);
    process.exit(1);
  }
  if (!data || Array.isArray(data) || typeof data !== "object") {
    process.stderr.write(`В JSON ${path} жду объект в корне. Файл не меняю.\n`);
    process.exit(1);
  }
  return data;
}

function jsonRead(path) {
  const raw = existsSync(path) && statSync(path).isFile() ? readFileSync(path) : null;
  return { raw, data: jsonParse(raw, path) };
}

function jsonServer() {
  return {
    type: "http",
    url: process.env.TASKLESS_MCP_URL || "",
    headersHelper: process.env.TASKLESS_HEADER_COMMAND || "",
  };
}

function jsonTasklessOwned(server) {
  if (!server || Array.isArray(server) || typeof server !== "object" || typeof server.headersHelper !== "string") return false;
  const helperPath = `${process.env.HOME}/.config/taskless/mcp-headers`;
  return server.headersHelper.includes(helperPath);
}

function jsonDump(data) {
  return Buffer.from(JSON.stringify(data, null, 2) + "\n", "utf8");
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function jsonApply(path, dry) {
  const { raw, data } = jsonRead(path);
  let servers = data.mcpServers;
  if (servers === undefined) {
    servers = {};
    data.mcpServers = servers;
  }
  if (!servers || Array.isArray(servers) || typeof servers !== "object") {
    process.stderr.write(`В JSON ${path} ключ mcpServers не объект. Файл не меняю.\n`);
    process.exit(1);
  }
  const wanted = jsonServer();
  if (sameJson(servers.taskless, wanted)) {
    emitEdit(false, "", false, false);
    return;
  }
  servers.taskless = wanted;
  const bak = path + ".bak-taskless";
  const backup = raw !== null && !existsSync(bak) ? bak : "";
  if (dry) {
    emitEdit(true, backup, raw === null, false);
    return;
  }
  if (backup) {
    mkdirSync(dirname(path) || ".", { recursive: true });
    writeFileSync(bak, raw);
    chmodSync(bak, statSync(path).mode & 0o777);
  }
  writeAtomic(path, jsonDump(data), raw === null ? 0o600 : statSync(path).mode & 0o777);
  emitEdit(true, backup, raw === null, false);
}

function jsonRemove(path, dry) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    emitEdit(false, "", false, false);
    return;
  }
  const { data } = jsonRead(path);
  const servers = data.mcpServers;
  if (!servers || typeof servers !== "object" || !jsonTasklessOwned(servers.taskless)) {
    emitEdit(false, "", false, false);
    return;
  }
  const bakPath = path + ".bak-taskless";
  const bakRaw = existsSync(bakPath) && statSync(bakPath).isFile() ? readFileSync(bakPath) : null;
  const bakData = bakRaw === null ? null : jsonParse(bakRaw, bakPath);
  delete servers.taskless;
  const bakServers = bakData?.mcpServers;
  if (bakServers && typeof bakServers === "object" && Object.hasOwn(bakServers, "taskless")) {
    servers.taskless = bakServers.taskless;
  }
  if (Object.keys(servers).length === 0 && (!bakData || !bakData.mcpServers || Object.keys(bakData.mcpServers).length === 0)) {
    delete data.mcpServers;
  }
  if (dry) {
    emitEdit(true, "", false, bakData === null && Object.keys(data).length === 0);
    return;
  }
  let deleted = false;
  if (bakData === null && Object.keys(data).length === 0) {
    unlinkSync(linkDest(path));
    deleted = true;
  } else if (bakRaw !== null && sameJson(data, bakData)) {
    writeAtomic(path, bakRaw, statSync(path).mode & 0o777);
  } else {
    writeAtomic(path, jsonDump(data), statSync(path).mode & 0o777);
  }
  if (bakRaw !== null) unlinkSync(bakPath);
  emitEdit(true, "", false, deleted);
}

function jsonStatus(path) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    emitEdit(false, "", false, false);
    return;
  }
  const { data } = jsonRead(path);
  const connected = data.mcpServers && typeof data.mcpServers === "object" && jsonTasklessOwned(data.mcpServers.taskless);
  emitEdit(Boolean(connected), "", false, false);
}

function tomlBlock() {
  process.stdout.write("[mcp_servers.taskless]\n");
  process.stdout.write(`url = ${JSON.stringify(process.env.TASKLESS_MCP_URL || "")}\n`);
  process.stdout.write(`http_headers_helper = ${JSON.stringify(process.env.TASKLESS_HEADER_COMMAND || "")}\n\n`);
  process.stdout.write('[plugins."taskless@taskless-app".mcp_servers.taskless]\n');
  process.stdout.write("enabled = false\n");
}

function metaWrite() {
  const path = process.argv[3];
  const agents = (process.env.TASKLESS_AGENTS || "").split(",").filter(Boolean);
  const data = {
    device_name: process.env.TASKLESS_DEVICE_NAME || "",
    platform: process.env.TASKLESS_PLATFORM || "",
    store: process.env.TASKLESS_STORE || "",
    agents,
  };
  const raw = Buffer.from(JSON.stringify(data, null, 2) + "\n", "utf8");
  const parent = dirname(path);
  if (parent) {
    mkdirSync(parent, { recursive: true });
    chmodSync(parent, 0o700);
  }
  writeAtomic(path, raw, 0o600);
  process.stdout.write("changed=1\n");
}

function metaRead() {
  const path = process.argv[3];
  let data = {};
  if (existsSync(path)) {
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      data = {};
    }
  }
  if (!data || typeof data !== "object") data = {};
  const agents = Array.isArray(data.agents) ? data.agents : [];
  process.stdout.write(`device_name=${field(data.device_name || "")}\n`);
  process.stdout.write(`platform=${field(data.platform || "")}\n`);
  process.stdout.write(`store=${field(data.store || "")}\n`);
  process.stdout.write(`agents=${agents.map((a) => String(a)).join(",")}\n`);
}

function emitMemoryField(key, value) {
  process.stdout.write(`${key}=${field(value)}\n`);
}

function serverMessage(payload, net = "") {
  if (net) return net;
  if (payload && typeof payload === "object") {
    for (const key of ["message", "error", "detail"]) {
      if (typeof payload[key] === "string" && payload[key]) return payload[key];
    }
  }
  return "неизвестная ошибка сервера";
}

async function memoryState() {
  const r = await request("GET", apiBase() + "/memory/personal/settings", null, process.env.TASKLESS_TOKEN || "");
  emitMemoryField("status", r.status);
  emitMemoryField("net_error", r.net);
  emitMemoryField("memory_state", ["on", "off"].includes(r.payload.state) ? r.payload.state : "");
  emitMemoryField("server_message", r.status === 200 ? "" : serverMessage(r.payload, r.net));
}

async function memorySet(value) {
  const r = await request("PUT", apiBase() + "/memory/personal/settings", { enabled: value === "on" }, process.env.TASKLESS_TOKEN || "");
  if (r.status !== 200) throw new Error(serverMessage(r.payload, r.net));
  emitMemoryField("status", r.status);
}

const SECRET_WORDS = new Set(["password", "passwd", "пароль", "token", "secret", "apikey", "ключ"]);
const SECRET_KEY_OWNERS = new Set(["api", "secret", "access"]);
const SECRET_PLACEHOLDER = /^(?:true|false|null|none|undefined|empty|redacted|x+|\*+|\.+)$/i;
const NOT_SECRET_VALUE = /^(?:@?[A-Z][A-Z0-9]*-\d+|v?\d+(?:\.\d+)+(?:[-+][\w.]+)?|\d{4}-\d{2}-\d{2}(?:[T ]?[\d:.]+Z?)?|\d{1,2}:\d{2}(?::\d{2})?)$/;

function isSecretName(name) {
  const words = name
    .replace(/(\p{Ll}|\p{N})(\p{Lu})/gu, "$1_$2")
    .replace(/(\p{Lu})(\p{Lu}\p{Ll})/gu, "$1_$2")
    .toLowerCase()
    .split(/[_-]+/)
    .filter(Boolean);
  const last = words.at(-1);
  if (!last) return false;
  if (SECRET_WORDS.has(last)) return true;
  return last === "key" && words.length > 1 && SECRET_KEY_OWNERS.has(words.at(-2));
}

function acceptAssignedSecret(value, match) {
  if (!isSecretName(match.groups.name)) return false;
  if (SECRET_PLACEHOLDER.test(value) || /^[$%{<]/.test(value) || /^process\.env\b/.test(value)) return false;
  if (NOT_SECRET_VALUE.test(value)) return false;
  if (match.groups.sep === "=") return value.length >= 4;
  return value.length >= 6 && /[^\p{L}]/u.test(value);
}

const L = String.raw`(?<![A-Za-z0-9_])`;
const R = String.raw`(?![A-Za-z0-9_])`;
const SECRET_PATTERNS = [
  [/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/g, null],
  [new RegExp(`${L}(?:tlswarm|tldev|tlsec|tldc|tla|tlr|tlc)_[A-Za-z0-9_-]{20,}`, "g"), null],
  [new RegExp(`${L}gh[pousr]_[A-Za-z0-9]{30,}${R}`, "g"), null],
  [new RegExp(`${L}github_pat_[A-Za-z0-9_]{22,}`, "g"), null],
  [new RegExp(`${L}sk-ant-[A-Za-z0-9_-]{20,}`, "g"), null],
  [new RegExp(`${L}sk-[A-Za-z0-9_-]{20,}`, "g"), "digit"],
  [new RegExp(`${L}(?:AKIA|ASIA)[A-Z0-9]{16}${R}`, "g"), null],
  [new RegExp(`${L}xox[abprs]-[A-Za-z0-9-]{10,}`, "g"), null],
  [new RegExp(`${L}AIza[A-Za-z0-9_-]{35}`, "g"), null],
  [new RegExp(`${L}eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*`, "g"), null],
  [/(?<![A-Za-z0-9_])[Bb]earer[ \t]+(?<secret>[A-Za-z0-9._~+/-]{16,}=*)/g, "digit"],
  [/(?<![a-z0-9+.-])[a-z][a-z0-9+.-]*:\/\/[^\s\/:@]+:(?<secret>[^\s\/@]+)@/gi, null],
  [/(?<![\p{L}\p{N}_-])(?<name>[\p{L}\p{N}_-]*?(?:password|passwd|пароль|token|secret|key|ключ))["']?[ \t]*(?<sep>=|:)[ \t]*["']?(?<secret>[\x21-\x7e]+?)(?=["'`,;&<>)\]}]|\s|$)/giu, acceptAssignedSecret],
];

function lineHasSecret(line) {
  for (const [pattern, accept] of SECRET_PATTERNS) {
    pattern.lastIndex = 0;
    for (const match of line.matchAll(pattern)) {
      const value = match.groups?.secret || match[0];
      if (accept === null) return true;
      if (accept === "digit" && /[0-9]/.test(value)) return true;
      if (typeof accept === "function" && accept(value, match)) return true;
    }
  }
  return false;
}

function prettyPath(path, home) {
  const absolute = resolve(path);
  if (absolute === home) return "~";
  if (absolute.startsWith(home + "/")) return "~/" + absolute.slice(home.length + 1);
  return absolute;
}

function prettySize(size) {
  if (size < 1024) return `${size} Б`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} КБ`;
  return `${(size / (1024 * 1024)).toFixed(1).replace(".", ",")} МБ`;
}

function prettyCount(count, words = ["файл", "файла", "файлов"]) {
  const mod10 = count % 10;
  const mod100 = count % 100;
  const word = mod10 === 1 && mod100 !== 11 ? words[0] : mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) ? words[1] : words[2];
  return `${count} ${word}`;
}

function skipReason(name) {
  const lower = name.toLowerCase();
  if (lower.startsWith(".env") || lower.startsWith("id_") || ["secret", "credential", "token"].some((word) => lower.includes(word))) return "похоже на ключи";
  if ([".pem", ".key", ".p12", ".pfx"].some((ext) => lower.endsWith(ext))) return "похоже на ключи";
  if (![".md", ".markdown", ".txt"].some((ext) => lower.endsWith(ext))) return "не текст";
  return null;
}

function inspectMemoryFile(path, home, skipped, secrets) {
  const name = path.split("/").pop();
  const shown = prettyPath(path, home);
  try {
    if (lstatSync(path).isSymbolicLink()) {
      skipped.push([shown, "симлинк"]);
      return null;
    }
    const reason = skipReason(name);
    if (reason) {
      skipped.push([shown, reason]);
      return null;
    }
    const size = statSync(path).size;
    if (size > 256 * 1024) {
      skipped.push([shown, "больше 256 КБ"]);
      return null;
    }
    const data = readFileSync(path);
    if (data.subarray(0, 8192).includes(0)) {
      skipped.push([shown, "не текст"]);
      return null;
    }
    let inPrivateKey = false;
    const fileLines = data.toString("utf8").split(/\r?\n/);
    // Перевод строки в конце файла — не ещё одна строка (python splitlines считает так же).
    if (fileLines.length > 1 && fileLines[fileLines.length - 1] === "") fileLines.pop();
    fileLines.forEach((line, index) => {
      const begins = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(line);
      const ends = /-----END [A-Z0-9 ]*PRIVATE KEY-----/.test(line);
      if (inPrivateKey || begins || lineHasSecret(line)) secrets.push([shown, index + 1]);
      if (inPrivateKey && ends) inPrivateKey = false;
      if (begins && !ends) inPrivateKey = true;
    });
    return size;
  } catch {
    skipped.push([shown, "не прочитал"]);
    return null;
  }
}

function walkMemoryDir(root, home, skipped, secrets) {
  let count = 0;
  let total = 0;
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    skipped.push([prettyPath(root, home), "не прочитал"]);
    return [count, total];
  }
  for (const entry of entries) {
    const path = join(root, entry.name);
    const shown = prettyPath(path, home);
    try {
      if (entry.isSymbolicLink()) {
        skipped.push([shown, "симлинк"]);
        continue;
      }
      if (entry.isDirectory()) {
        if (entry.name.startsWith(".")) skipped.push([shown + "/", "скрытая папка"]);
        else if (entry.name === "node_modules") skipped.push([shown + "/", "node_modules"]);
        else {
          const [subcount, subtotal] = walkMemoryDir(path, home, skipped, secrets);
          count += subcount;
          total += subtotal;
        }
        continue;
      }
      if (!entry.isFile()) continue;
      if (["CLAUDE.md", "AGENTS.md"].includes(entry.name)) {
        skipped.push([shown, "правила команды"]);
        continue;
      }
      const size = inspectMemoryFile(path, home, skipped, secrets);
      if (size !== null) {
        count += 1;
        total += size;
      }
    } catch {
      skipped.push([shown, "не прочитал"]);
    }
  }
  return [count, total];
}

function customMemoryDirs(home) {
  const dirs = [];
  const seen = new Set();
  for (const raw of (process.env.TASKLESS_MEMORY_DIRS || "").split("\n")) {
    if (!raw) continue;
    const expanded = raw === "~" ? home : raw.startsWith("~/") ? join(home, raw.slice(2)) : raw;
    const path = resolve(expanded);
    if (seen.has(path)) continue;
    seen.add(path);
    dirs.push([path, raw]);
  }
  return dirs;
}

function validateMemoryDirs() {
  const home = resolve(process.env.HOME || "");
  for (const [path, raw] of customMemoryDirs(home)) {
    let directory = false;
    try {
      directory = statSync(path).isDirectory();
    } catch {}
    if (!directory) throw new Error(`Нет такой папки: ${raw}`);
  }
}

function secretRanges(secrets) {
  const ranges = [];
  for (const [path, number] of secrets) {
    const last = ranges[ranges.length - 1];
    if (last && last[0] === path && last[2] === number - 1) last[2] = number;
    else ranges.push([path, number, number]);
  }
  return ranges;
}

function memoryScan(output) {
  const home = resolve(process.env.HOME || "");
  validateMemoryDirs();
  const files = [
    [join(home, ".claude", "CLAUDE.md"), "правила"],
    [join(home, ".codex", "AGENTS.md"), "правила"],
  ];
  const claudeDirs = [];
  const projects = join(home, ".claude", "projects");
  try {
    for (const entry of readdirSync(projects, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const memory = join(projects, entry.name, "memory");
      if (!entry.isSymbolicLink() && entry.isDirectory() && existsSync(memory) && statSync(memory).isDirectory() && !lstatSync(memory).isSymbolicLink()) claudeDirs.push(memory);
    }
  } catch {}
  const dirs = ["memories", "memories_v2"].map((name) => [join(home, ".codex", name), "память Codex"]);
  dirs.push(...customMemoryDirs(home).map(([path]) => [path, "твоя папка"]));
  const rows = [];
  const skipped = [];
  const secrets = [];
  let total = 0;
  for (const [path, label] of files) {
    if (!existsSync(path)) continue;
    const size = inspectMemoryFile(path, home, skipped, secrets);
    if (size !== null) {
      rows.push(`  ${prettyPath(path, home)} — ${prettySize(size)}, ${label}`);
      total += size;
    }
  }
  let claudeCount = 0;
  let claudeSize = 0;
  for (const path of claudeDirs) {
    const [count, size] = walkMemoryDir(path, home, skipped, secrets);
    claudeCount += count;
    claudeSize += size;
  }
  if (claudeCount) {
    rows.push(`  ~/.claude/projects/…/memory/ — ${prettyCount(claudeCount)}, ${prettySize(claudeSize)}, память Claude Code`);
    total += claudeSize;
  }
  for (const [path, label] of dirs) {
    if (!existsSync(path)) continue;
    if (lstatSync(path).isSymbolicLink()) {
      skipped.push([prettyPath(path, home), "симлинк"]);
      continue;
    }
    const [count, size] = walkMemoryDir(path, home, skipped, secrets);
    if (count) {
      rows.push(`  ${prettyPath(path, home)}/ — ${prettyCount(count)}, ${prettySize(size)}, ${label}`);
      total += size;
    }
  }
  const lines = [...rows];
  if (rows.length) lines.push(`Всего ${prettySize(total)}. Агент за раз читает до 200 КБ, остальное — по выбору человека.`);
  if (skipped.length) {
    const first = skipped.slice(0, 10).map(([path, reason]) => `${path} — ${reason}`).join("; ");
    const rest = skipped.length > 10 ? `; и ещё ${skipped.length - 10}` : "";
    lines.push(`Пропущены: ${first}${rest}.`);
  }
  for (const [path, first, last] of secretRanges(secrets)) {
    if (first === last) lines.push(`Похоже на секрет: ${path}, строка ${first}. Эту строку в записи не бери.`);
    else lines.push(`Похоже на секрет: ${path}, строки ${first}–${last}. Эти строки в записи не бери.`);
  }
  writeFileSync(output, lines.length ? lines.join("\n") + "\n" : "", "utf8");
  emitMemoryField("memory_found", rows.length ? 1 : 0);
}

const IMPORT_KINDS = new Set(["fact", "rule", "decision", "promise"]);
const IMPORT_SOURCES = new Set(["instructions", "agent_memory", "notes"]);
const IMPORT_CLIENTS = new Set(["claude-code", "codex", "grok", "zcode", "cursor", "gemini", "other"]);
const IMPORT_MODIFIED_AT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

function validModifiedAt(value) {
  return typeof value === "string" && IMPORT_MODIFIED_AT.test(value) && !Number.isNaN(Date.parse(value));
}

function readImportBatch(path) {
  let batch;
  try {
    batch = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new Error(`Не прочитал JSON ${path}: ${err.message}`);
  }
  if (!batch || typeof batch !== "object" || !Array.isArray(batch.files)) throw new Error(`Не тот формат ${path}: нужен объект с массивом files`);
  if ("client" in batch && !IMPORT_CLIENTS.has(batch.client)) throw new Error(`Не тот формат ${path}: неизвестный client`);
  batch.files.forEach((file, fileIndex) => {
    const where = `файл ${fileIndex + 1}`;
    if (!file || typeof file !== "object") throw new Error(`${where}: нужен объект`);
    if (typeof file.path !== "string" || file.path.length < 1 || file.path.length > 500) throw new Error(`${where}: path — строка от 1 до 500 знаков`);
    if (!IMPORT_SOURCES.has(file.source)) throw new Error(`${where}: source — instructions, agent_memory или notes`);
    if ("modifiedAt" in file && !validModifiedAt(file.modifiedAt)) throw new Error(`${where}: modifiedAt — дата ISO 8601 с часовым поясом`);
    if (!Array.isArray(file.items)) throw new Error(`${where}: items — массив записей`);
    if (file.items.length > 300) throw new Error(`${where}: больше 300 записей, раздели их между файлами`);
    file.items.forEach((item, itemIndex) => {
      const place = `${where}, запись ${itemIndex + 1}`;
      if (!item || typeof item !== "object" || typeof item.statement !== "string") throw new Error(`${place}: statement — строка`);
      if ("kind" in item && !IMPORT_KINDS.has(item.kind)) throw new Error(`${place}: kind — fact, rule, decision или promise`);
      if ("quote" in item && typeof item.quote !== "string") throw new Error(`${place}: quote — строка`);
    });
  });
  if (batch.files.reduce((sum, file) => sum + file.items.length, 0) === 0) throw new Error(`Пустая пачка ${path}: нужна хотя бы одна запись`);
  return batch;
}

function importBatches(batch) {
  const batches = [];
  let current = [];
  let count = 0;
  for (const file of batch.files) {
    if (current.length && count + file.items.length > 300) {
      batches.push(current);
      current = [];
      count = 0;
    }
    current.push(file);
    count += file.items.length;
  }
  if (current.length) batches.push(current);
  return batches;
}

function writeImportReport(output, reports, dryFiles = null) {
  const lines = [];
  if (dryFiles !== null) {
    const totalItems = dryFiles.reduce((sum, file) => sum + file.items.length, 0);
    lines.push(`Проверка: ушло бы ${prettyCount(totalItems, ["запись", "записи", "записей"])}, запросов не отправил.`);
    for (const file of dryFiles) lines.push(`  ${file.path} — ${prettyCount(file.items.length, ["запись", "записи", "записей"])}`);
  } else {
    const total = Object.fromEntries(["new", "known", "duplicate", "skipped"].map((key) => [key, reports.reduce((sum, report) => sum + (Number(report[key]) || 0), 0)]));
    lines.push(`Взял новых: ${total.new}. Уже было: ${total.known}. Повтор: ${total.duplicate}. Пропущено: ${total.skipped}`);
    const reasonNames = [["secret", "секрет"], ["too_long", "длиннее 300 знаков"], ["empty", "пусто"], ["rule_without_quote", "правило без цитаты"], ["retracted", "ты это раньше удалил"], ["error", "ошибка"]];
    const reasons = [];
    for (const [key, label] of reasonNames) {
      const count = reports.reduce((sum, report) => sum + (Number(report.skippedByReason?.[key]) || 0), 0);
      if (count) reasons.push(`${label} — ${count}`);
    }
    if (reasons.length) lines.push(`Причины пропусков: ${reasons.join("; ")}`);
    for (const report of reports) {
      for (const file of report.files || []) lines.push(`  ${file.file || ""} — новых ${Number(file.new) || 0}, уже было ${Number(file.known) || 0}, повтор ${Number(file.duplicate) || 0}, пропущено ${Number(file.skipped) || 0}`);
    }
  }
  writeFileSync(output, lines.join("\n") + "\n", "utf8");
}

async function memoryImport(path, output, dry) {
  const batch = readImportBatch(path);
  if (dry) {
    writeImportReport(output, [], batch.files);
    return;
  }
  const reports = [];
  let sent = 0;
  const totalItems = batch.files.reduce((sum, file) => sum + file.items.length, 0);
  for (const files of importBatches(batch)) {
    const payload = { files };
    if ("client" in batch) payload.client = batch.client;
    const r = await request("POST", apiBase() + "/memory/personal/import", payload, process.env.TASKLESS_TOKEN || "");
    if (r.status !== 200) {
      if (reports.length) {
        writeImportReport(output, reports);
        writeFileSync(output, `${readFileSync(output, "utf8")}Отправил ${sent} из ${prettyCount(totalItems, ["запись", "записи", "записей"])}, дальше остановился:\n`, "utf8");
      }
      throw new Error(serverMessage(r.payload, r.net));
    }
    reports.push(r.payload);
    sent += files.reduce((sum, file) => sum + file.items.length, 0);
  }
  writeImportReport(output, reports);
}

const cmd = process.argv[2];
if (cmd === "device_start") {
  const r = await request("POST", apiBase() + "/oauth/device_authorization", devicePayload(), "");
  emitHttp(r.status, r.retry, r.net, r.payload);
} else if (cmd === "poll") {
  const r = await request("POST", apiBase() + "/oauth/token", {
    grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    device_code: process.env.TASKLESS_DEVICE_CODE || "",
    client_id: "taskless-device",
  }, "");
  emitHttp(r.status, r.retry, r.net, r.payload);
} else if (cmd === "me") {
  const r = await request("GET", apiBase() + "/auth/me", null, process.env.TASKLESS_TOKEN || "");
  emitHttp(r.status, r.retry, r.net, r.payload);
} else if (cmd === "revoke") {
  const r = await request("POST", apiBase() + "/oauth/revoke", {
    token: process.env.TASKLESS_TOKEN || "",
    client_id: "taskless-device",
  }, "");
  emitHttp(r.status, r.retry, r.net, r.payload);
} else if (cmd === "edit") {
  const action = process.argv[3];
  const path = process.argv[4];
  const begin = process.argv[5];
  const end = process.argv[6];
  const dry = process.argv[7] === "1";
  const mode = parseInt(process.argv[8], 8);
  if (action === "apply") applyBlock(path, begin, end, readFileSync(0), dry, mode);
  else if (action === "remove") removeBlock(path, begin, end, dry);
  else {
    process.stderr.write("edit: не знаю действие\n");
    process.exit(1);
  }
} else if (cmd === "json") {
  const action = process.argv[3];
  const path = process.argv[4];
  const dry = process.argv[5] === "1";
  if (action === "apply") jsonApply(path, dry);
  else if (action === "remove") jsonRemove(path, dry);
  else if (action === "status") jsonStatus(path);
  else {
    process.stderr.write("json: не знаю действие\n");
    process.exit(1);
  }
} else if (cmd === "toml_block") {
  tomlBlock();
} else if (cmd === "meta_write") {
  metaWrite();
} else if (cmd === "meta_read") {
  metaRead();
} else if (cmd === "memory_state") {
  await memoryState();
} else if (cmd === "memory_set") {
  try {
    await memorySet(process.argv[3]);
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exit(1);
  }
} else if (cmd === "memory_validate_dirs") {
  try {
    validateMemoryDirs();
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exit(1);
  }
} else if (cmd === "memory_scan") {
  memoryScan(process.argv[3]);
} else if (cmd === "memory_import") {
  try {
    await memoryImport(process.argv[3], process.argv[4], process.argv[5] === "1");
  } catch (err) {
    process.stderr.write(`${err.message}\n`);
    process.exit(1);
  }
} else {
  process.stderr.write("не знаю команду\n");
  process.exit(1);
}
process.exit(0);
TASKLESS_CONNECT_NODE_END
  fi
  chmod 700 "$HELPER"
}

run_helper() {
  if [ "$RUNTIME" = "python3" ]; then
    python3 "$HELPER" "$@"
  else
    node "$HELPER" "$@"
  fi
}

parse_kv() {
  HTTP_STATUS=
  HTTP_RETRY=
  HTTP_NET=
  HTTP_OAUTH_ERROR=
  HTTP_TOKEN=
  HTTP_USER_CODE=
  HTTP_DEVICE_CODE=
  HTTP_URI=
  HTTP_EXPIRES=
  HTTP_INTERVAL=
  EDIT_CHANGED=
  EDIT_BACKUP=
  META_DEVICE=
  MEMORY_STATE=
  MEMORY_FOUND=
  SERVER_MESSAGE=
  while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      status) HTTP_STATUS=$val ;;
      retry_after) HTTP_RETRY=$val ;;
      net_error) HTTP_NET=$val ;;
      oauth_error) HTTP_OAUTH_ERROR=$val ;;
      access_token) HTTP_TOKEN=$val ;;
      user_code) HTTP_USER_CODE=$val ;;
      device_code) HTTP_DEVICE_CODE=$val ;;
      verification_uri_complete) HTTP_URI=$val ;;
      expires_in) HTTP_EXPIRES=$val ;;
      interval) HTTP_INTERVAL=$val ;;
      changed) EDIT_CHANGED=$val ;;
      backup) EDIT_BACKUP=$val ;;
      device_name) META_DEVICE=$val ;;
      memory_state) MEMORY_STATE=$val ;;
      memory_found) MEMORY_FOUND=$val ;;
      server_message) SERVER_MESSAGE=$val ;;
    esac
  done
}

# Помощник печатает поля key=value. Разбор — из файла, не из канала:
# канал в sh выполняется в подпроцессе и потерял бы переменные.
capture_helper() {
  kvfile=$(mktemp)
  if ! run_helper "$@" > "$kvfile"; then
    cat "$kvfile" >&2
    rm -f "$kvfile"
    return 1
  fi
  parse_kv < "$kvfile"
  rm -f "$kvfile"
}

# http:// только на петле: иначе curl|sh с подменённым TASKLESS_URL ушёл бы
# на чужой хост. localhost и 127.0.0.1 — заглушка тестов и локальный api.
# Хост разбираем, а не сравниваем шаблоном: в http://127.0.0.1:x@evil/ хост —
# evil, а шаблон 127.0.0.1:* его пропускал. До первого «/» — ровно
# localhost или 127.0.0.1 и, может быть, :цифры. Как регекс в connect.ps1.
require_base() {
  case "$BASE" in
    https://*)
      return 0
      ;;
    http://*)
      authority=${BASE#http://}
      authority=${authority%%/*}
      case "$authority" in
        127.0.0.1|localhost)
          return 0
          ;;
        127.0.0.1:*|localhost:*)
          case "${authority#*:}" in
            ''|*[!0-9]*) ;;
            *) return 0 ;;
          esac
          ;;
      esac
      die "TASKLESS_URL с http:// разрешён только для localhost и 127.0.0.1."
      ;;
    *)
      die "TASKLESS_URL должен начинаться с https://."
      ;;
  esac
}

export_base() {
  export TASKLESS_BASE="$BASE"
  export TASKLESS_DEVICE_NAME="$DEVICE_NAME"
  export TASKLESS_PLATFORM="$PLATFORM"
  export TASKLESS_OS_VERSION="$OS_VERSION"
  export TASKLESS_CLIENT_VERSION="$CLIENT_VERSION"
}

load_key_file() {
  if [ ! -f "$KEY_FILE" ]; then
    return 1
  fi
  got=$(tr -d '\r\n' < "$KEY_FILE")
  if [ -z "$got" ]; then
    return 1
  fi
  TOKEN=$got
  STORE_KIND="file"
  return 0
}

load_key() {
  TOKEN=
  STORE_KIND=
  if [ "${TASKLESS_KEY_STORE:-auto}" = "file" ]; then
    load_key_file
    return
  fi
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    if got=$(security find-generic-password -a taskless -s taskless-device -w 2>/dev/null); then
      got=$(printf '%s' "$got" | tr -d '\r\n')
      if [ -n "$got" ]; then
        TOKEN=$got
        STORE_KIND=keychain
        return 0
      fi
    fi
  fi
  if [ "$(uname -s)" != "Darwin" ] && command -v secret-tool >/dev/null 2>&1; then
    if got=$(secret-tool lookup service taskless account device 2>/dev/null); then
      got=$(printf '%s' "$got" | tr -d '\r\n')
      if [ -n "$got" ]; then
        TOKEN=$got
        STORE_KIND=secret
        return 0
      fi
    fi
  fi
  load_key_file
}

write_secret_file() {
  dir=$1
  dest=$2
  content=$3
  mkdir -p "$dir"
  chmod 700 "$dir"
  tmp=$(mktemp "$dir/.key.XXXXXX")
  chmod 600 "$tmp"
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dest"
  chmod 600 "$dest"
}

save_key() {
  token=$1
  TOKEN=$token
  forced=${TASKLESS_KEY_STORE:-auto}
  if [ "$forced" != "file" ] && [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    # -w в argv светит ключ в списке процессов. security -i читает команду из stdin.
    if printf 'add-generic-password -U -a taskless -s taskless-device -w %s\n' "$token" | security -i >/dev/null 2>&1; then
      STORE_KIND=keychain
      rm -f "$KEY_FILE"
      return 0
    fi
  fi
  if [ "$forced" != "file" ] && [ "$(uname -s)" != "Darwin" ] && command -v secret-tool >/dev/null 2>&1; then
    if printf '%s' "$token" | secret-tool store --label='Taskless device key' service taskless account device >/dev/null 2>&1; then
      STORE_KIND=secret
      write_secret_file "$CONFIG_DIR" "$KEY_FILE" "$token"
      return 0
    fi
  fi
  write_secret_file "$CONFIG_DIR" "$KEY_FILE" "$token"
  STORE_KIND="file"
}

clear_key() {
  if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    security delete-generic-password -a taskless -s taskless-device >/dev/null 2>&1 || true
  fi
  if [ "$(uname -s)" != "Darwin" ] && command -v secret-tool >/dev/null 2>&1; then
    secret-tool clear service taskless account device >/dev/null 2>&1 || true
  fi
  rm -f "$KEY_FILE"
}

key_saved_line() {
  case "$STORE_KIND" in
    keychain) printf '%s\n' "Вход подтверждён, ключ сохранён в Keychain." ;;
    secret) printf '%s\n' "Вход подтверждён, ключ сохранён в связке ключей." ;;
    *) printf '%s\n' "Вход подтверждён, ключ сохранён в файле ~/.config/taskless/device-key." ;;
  esac
}

key_status_line() {
  case "$STORE_KIND" in
    keychain) printf '%s\n' "Ключ: в Keychain" ;;
    secret) printf '%s\n' "Ключ: в связке ключей" ;;
    file) printf '%s\n' "Ключ: в файле ~/.config/taskless/device-key" ;;
    *) printf '%s\n' "Ключ: нет" ;;
  esac
}

# 0 — ключ жив, 1 — сервер его не принял, 2 — не смогли спросить.
probe_key() {
  export TASKLESS_TOKEN="$TOKEN"
  export_base
  if ! capture_helper me; then
    return 2
  fi
  case "$HTTP_STATUS" in
    200|201|204) return 0 ;;
    401|403) return 1 ;;
    *) return 2 ;;
  esac
}

open_browser() {
  url=$1
  if [ -n "${TASKLESS_BROWSER:-}" ]; then
    # Команда целиком — одно слово (путь или имя). Тест подставляет true.
    "$TASKLESS_BROWSER" "$url" >/dev/null 2>&1 || true
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      if command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

device_login() {
  export_base
  TASKLESS_AGENTS=$(comma_ids "$FOUND")
  export TASKLESS_AGENTS
  capture_helper device_start || die "Не достучался до Taskless."
  if [ "$HTTP_STATUS" != "200" ] || [ -z "$HTTP_USER_CODE" ] || [ -z "$HTTP_DEVICE_CODE" ]; then
    die "Не получил код подключения (HTTP ${HTTP_STATUS:-0}). ${HTTP_OAUTH_ERROR:-$HTTP_NET}"
  fi
  if [ -z "$HTTP_URI" ]; then
    HTTP_URI="https://taskless.ru/connect?code=$HTTP_USER_CODE"
  fi
  interval=$(digits "$HTTP_INTERVAL")
  if [ -z "$interval" ]; then
    interval=5
  fi
  expires=$(digits "$HTTP_EXPIRES")
  if [ -z "$expires" ]; then
    expires=600
  fi
  now=$(date +%s)
  deadline=$((now + expires))
  printf 'Код подключения: %s\n' "$HTTP_USER_CODE"
  printf 'Открываю браузер: %s\n' "$HTTP_URI"
  printf '%s\n' "Если браузер не открылся, открой ссылку сам. Код живёт 10 минут."
  printf '%s\n' "Жду подтверждения в браузере…"
  open_browser "$HTTP_URI"
  export TASKLESS_DEVICE_CODE="$HTTP_DEVICE_CODE"
  while :; do
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
      printf '%s\n' "Код устарел. Запусти установщик ещё раз."
      exit 1
    fi
    if [ "$interval" -gt 0 ]; then
      sleep "$interval"
    fi
    capture_helper poll || die "Не достучался до Taskless."
    case "$HTTP_STATUS" in
      200)
        if [ -n "$HTTP_TOKEN" ]; then
          TOKEN=$HTTP_TOKEN
          return 0
        fi
        die "Сервер не отдал ключ."
        ;;
      400)
        case "$HTTP_OAUTH_ERROR" in
          authorization_pending) ;;
          slow_down)
            interval=$((interval + 5))
            if [ "$interval" -gt 60 ]; then
              interval=60
            fi
            ;;
          access_denied)
            printf '%s\n' "Вход отклонён. Ключ не сохранён."
            exit 1
            ;;
          expired_token)
            printf '%s\n' "Код устарел. Запусти установщик ещё раз."
            exit 1
            ;;
          invalid_grant)
            printf '%s\n' "Код не принят. Запусти установщик ещё раз."
            exit 1
            ;;
          *)
            printf 'Не получилось войти: %s\n' "${HTTP_OAUTH_ERROR:-неизвестная ошибка}"
            exit 1
            ;;
        esac
        ;;
      429)
        wait=$(digits "$HTTP_RETRY")
        if [ -z "$wait" ]; then
          wait=5
        fi
        sleep "$wait"
        ;;
      0)
        printf 'Не достучался до Taskless: %s\n' "$HTTP_NET"
        exit 1
        ;;
      *)
        printf 'Не получилось войти (HTTP %s).\n' "$HTTP_STATUS"
        exit 1
        ;;
    esac
  done
}

ensure_token() {
  if load_key; then
    rc=0
    probe_key || rc=$?
    if [ "$rc" = 0 ]; then
      printf '%s\n' "Ключ уже есть, вход не прошу."
      return 0
    fi
    if [ "$rc" = 1 ]; then
      clear_key
      TOKEN=
    else
      die "Не смог проверить ключ. Не достучался до Taskless."
    fi
  fi
  device_login
  printf '\n'
  save_key "$TOKEN"
  key_saved_line
}

apply_stub() {
  id=$1
  dry=$2
  file=$(stub_file "$id")
  begin="# >>> taskless:$id"
  end="# <<< taskless:$id"
  inner=$(printf 'taskless=1\nagent=%s\n' "$id")
  # Не через канал: capture_helper в подпроцессе канала потерял бы changed/backup.
  bodyfile=$(mktemp)
  printf '%s' "$inner" > "$bodyfile"
  rc=0
  capture_helper edit apply "$file" "$begin" "$end" "$dry" 644 < "$bodyfile" || rc=$?
  rm -f "$bodyfile"
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
}

export_mcp_config() {
  TASKLESS_MCP_URL="$BASE/mcp"
  TASKLESS_HEADER_COMMAND="sh \"$CONFIG_DIR/mcp-headers\""
  export TASKLESS_MCP_URL TASKLESS_HEADER_COMMAND
}

apply_key_helper() {
  dry=$1
  bodyfile=$(mktemp)
  cat > "$bodyfile" <<'TASKLESS_KEY_HELPER_END'
#!/bin/sh
set -eu
key=
if [ "${TASKLESS_KEY_STORE:-auto}" != "file" ] && [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  key=$(security find-generic-password -a taskless -s taskless-device -w 2>/dev/null || true)
fi
if [ "${TASKLESS_KEY_STORE:-auto}" != "file" ] && [ "$(uname -s)" != "Darwin" ] && command -v secret-tool >/dev/null 2>&1; then
  key=$(secret-tool lookup service taskless account device 2>/dev/null || true)
fi
if [ -z "$key" ]; then
  keyfile="$HOME/.config/taskless/device-key"
  [ -f "$keyfile" ] || exit 1
  key=$(tr -d '\r\n' < "$keyfile")
fi
[ -n "$key" ] || exit 1
printf '{"Authorization":"Bearer %s"}\n' "$key"
TASKLESS_KEY_HELPER_END
  rc=0
  capture_helper edit apply "$CONFIG_DIR/mcp-headers" "# >>> taskless:key-helper" "# <<< taskless:key-helper" "$dry" 700 < "$bodyfile" || rc=$?
  rm -f "$bodyfile"
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
}

claude_config_connected() {
  export_mcp_config
  capture_helper json status "$HOME/.claude.json" 0 || return 1
  [ "$EDIT_CHANGED" = 1 ]
}

codex_config_connected() {
  file="$HOME/.codex/config.toml"
  [ -f "$file" ] && grep -q '^# >>> taskless:codex$' "$file" && grep -q '^# <<< taskless:codex$' "$file"
}

remove_key_helper_if_unused() {
  dry=$1
  if claude_config_connected || codex_config_connected; then
    EDIT_CHANGED=0
    return 0
  fi
  capture_helper edit remove "$CONFIG_DIR/mcp-headers" "# >>> taskless:key-helper" "# <<< taskless:key-helper" "$dry" 700 || exit $?
}

apply_claude() {
  dry=$1
  apply_key_helper "$dry"
  export_mcp_config
  capture_helper json apply "$HOME/.claude.json" "$dry" || exit $?
  if [ "$dry" = 1 ]; then
    printf '%s\n' "  claude plugin marketplace add taskless-app/taskless"
    printf '%s\n' "  claude plugin install taskless@taskless-app --scope user"
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "Нет claude в PATH. Сервер и ключ прописаны, плагин поставь командами:"
    printf '%s\n' "  claude plugin marketplace add taskless-app/taskless"
    printf '%s\n' "  claude plugin install taskless@taskless-app --scope user"
    return 0
  fi
  claude plugin marketplace add taskless-app/taskless || die "Не поставил маркетплейс Claude Code."
  claude plugin install taskless@taskless-app --scope user || die "Не поставил плагин Claude Code."
}

apply_codex() {
  dry=$1
  apply_key_helper "$dry"
  export_mcp_config
  bodyfile=$(mktemp)
  run_helper toml_block > "$bodyfile"
  rc=0
  capture_helper edit apply "$HOME/.codex/config.toml" "# >>> taskless:codex" "# <<< taskless:codex" "$dry" 600 < "$bodyfile" || rc=$?
  rm -f "$bodyfile"
  if [ "$rc" != 0 ]; then
    exit "$rc"
  fi
  if [ "$dry" = 1 ]; then
    printf '%s\n' "  codex plugin marketplace add taskless-app/taskless"
    printf '%s\n' "  codex plugin add taskless@taskless-app"
    return 0
  fi
  if ! command -v codex >/dev/null 2>&1; then
    printf '%s\n' "Нет codex в PATH. Сервер и ключ прописаны, плагин поставь командами:"
    printf '%s\n' "  codex plugin marketplace add taskless-app/taskless"
    printf '%s\n' "  codex plugin add taskless@taskless-app"
    return 0
  fi
  codex plugin marketplace add taskless-app/taskless || die "Не поставил маркетплейс Codex."
  codex plugin add taskless@taskless-app || die "Не поставил плагин Codex."
}

agent_remove() {
  id=$1
  dry=$2
  EDIT_CHANGED=0
  EDIT_BACKUP=
  changed_any=0
  if stub_wants "$id"; then
    file=$(stub_file "$id")
    capture_helper edit remove "$file" "# >>> taskless:$id" "# <<< taskless:$id" "$dry" 644 || exit $?
    return 0
  fi
  case "$id" in
    claude-code)
      if [ "$dry" != 1 ] && command -v claude >/dev/null 2>&1; then
        claude plugin uninstall taskless@taskless-app --scope user >/dev/null 2>&1 || true
      fi
      export_mcp_config
      capture_helper json remove "$HOME/.claude.json" "$dry" || exit $?
      if [ "$EDIT_CHANGED" = 1 ]; then changed_any=1; fi
      remove_key_helper_if_unused "$dry"
      if [ "$EDIT_CHANGED" = 1 ]; then changed_any=1; fi
      ;;
    codex)
      if [ "$dry" != 1 ] && command -v codex >/dev/null 2>&1; then
        codex plugin remove taskless@taskless-app >/dev/null 2>&1 || true
      fi
      capture_helper edit remove "$HOME/.codex/config.toml" "# >>> taskless:codex" "# <<< taskless:codex" "$dry" 600 || exit $?
      if [ "$EDIT_CHANGED" = 1 ]; then changed_any=1; fi
      remove_key_helper_if_unused "$dry"
      if [ "$EDIT_CHANGED" = 1 ]; then changed_any=1; fi
      ;;
  esac
  EDIT_CHANGED=$changed_any
}

preview_install() {
  id=$1
  name=$(agent_name "$id")
  if stub_wants "$id"; then
    apply_stub "$id" 1
    file=$(stub_file "$id")
    if [ "$EDIT_CHANGED" = 1 ]; then
      printf '%s: прописал бы %s\n' "$name" "$(tilde_path "$file")"
      if [ -n "$EDIT_BACKUP" ]; then
        printf '  копия конфига: %s\n' "$(tilde_path "$EDIT_BACKUP")"
      fi
    else
      printf '%s: уже прописан, без изменений\n' "$name"
    fi
    return 0
  fi
  case "$id" in
    claude-code)
      printf '%s: прописал бы ~/.claude.json и плагин taskless@taskless-app\n' "$name"
      apply_claude 1
      ;;
    codex)
      printf '%s: прописал бы ~/.codex/config.toml и плагин taskless@taskless-app\n' "$name"
      apply_codex 1
      ;;
    *) printf '%s: адаптер ещё не подключает клиент\n' "$name" ;;
  esac
}

real_install() {
  id=$1
  name=$(agent_name "$id")
  if stub_wants "$id"; then
    apply_stub "$id" 0
    if [ "$EDIT_CHANGED" = 1 ]; then
      printf '%s: тестовая запись прописана\n' "$name"
      if [ -n "$EDIT_BACKUP" ]; then
        printf '  копия конфига: %s\n' "$(tilde_path "$EDIT_BACKUP")"
      fi
    else
      printf '%s: уже прописан\n' "$name"
    fi
    return 0
  fi
  case "$id" in
    claude-code)
      apply_claude 0
      printf '%s: сервер и ключ прописаны\n' "$name"
      ;;
    codex)
      apply_codex 0
      printf '%s: сервер и ключ прописаны\n' "$name"
      ;;
    *) printf '%s: адаптер ещё не подключает клиент\n' "$name" ;;
  esac
}

save_meta() {
  connected=$1
  export_base
  export TASKLESS_STORE="$STORE_KIND"
  TASKLESS_AGENTS=$(comma_ids "$connected")
  export TASKLESS_AGENTS
  capture_helper meta_write "$META_FILE" || die "Не записал сведения об устройстве."
}

print_memory_import_steps() {
  n=$1
  printf '%s. Спроси, забирать ли найденную память. Если нет — на этом всё.\n' "$n"
  n=$((n + 1))
  printf '%s. Прочитай файлы из списка, всего не больше 200 КБ текста. Если файлов больше, спроси, какие взять.\n' "$n"
  n=$((n + 1))
  printf '%s. Составь короткие записи: одно утверждение — одна запись, до 300 знаков. Вид: fact, rule, decision или promise. Для правила положи в quote дословную строку из файла. Пароли, токены, ключи и строки с пометкой «похоже на секрет» не бери.\n' "$n"
  n=$((n + 1))
  printf '%s. Покажи записи человеку по файлам и спроси: «Отправить в Taskless?» Убери то, что он попросит. Без явного «да» ничего не отправляй.\n' "$n"
  n=$((n + 1))
  printf '%s. Запиши пачку во временный файл JSON (формат: https://taskless.ru/invite-agent#memory-format) и запусти:\n' "$n"
  printf '   curl -fsSL https://taskless.ru/connect.sh | sh -s -- --import-memory <файл>\n'
  n=$((n + 1))
  printf '%s. Перескажи человеку отчёт установщика и удали временный файл.\n' "$n"
}

print_memory_intro_steps() {
  printf '%s\n' "1. Расскажи человеку о личной памяти и спроси, включить ли её. Агенты во всех его подключениях будут помнить его правила, решения и факты о работе. Записи видит только он: ни админ, ни команда, ни рой. Выключить и удалить всё можно в профиле Taskless, раздел «Личная память»."
  printf '%s\n' "2. Ответ запиши командой:"
  printf '%s\n' "   curl -fsSL https://taskless.ru/connect.sh | sh -s -- --memory on"
  printf '%s\n' "   Если человек против — та же команда с --memory off, и на этом всё."
}

scan_memory() {
  report=$(mktemp)
  export TASKLESS_MEMORY_DIRS="$MEMORY_DIRS"
  if ! capture_helper memory_scan "$report"; then
    rm -f "$report"
    printf '%s\n' "Не смог поискать память на компьютере."
    return 1
  fi
  if [ "$MEMORY_FOUND" = 1 ]; then
    printf '%s\n' "Память на этом компьютере. В Taskless пока ничего не ушло."
  else
    printf '%s\n' "Памяти агентов на компьютере не нашёл"
  fi
  if [ "$MEMORY_FOUND" = 1 ] || [ "$DRY" = 1 ]; then
    cat "$report"
  fi
  rm -f "$report"
  return 0
}

report_memory() {
  printf '\n'
  if [ "$DRY" = 1 ]; then
    scan_memory || return 0
    printf '%s\n' "Это проверка. Что делать с памятью, установщик скажет при настоящем запуске."
    return 0
  fi
  export TASKLESS_TOKEN="$TOKEN"
  export_base
  if ! capture_helper memory_state; then
    printf '%s\n' "Не узнал, включена ли личная память: помощник не запустился"
    return 0
  fi
  if [ "$HTTP_STATUS" != 200 ]; then
    printf 'Не узнал, включена ли личная память: %s\n' "${SERVER_MESSAGE:-$HTTP_NET}"
    return 0
  fi
  if [ "$MEMORY_STATE" = "off" ]; then
    printf '%s\n' "Личная память Taskless выключена, память с компьютера не ищу. Включить её можно в профиле, раздел «Личная память»."
    return 0
  fi
  memory_state_saved=$MEMORY_STATE
  scan_memory || return 0
  if [ "$memory_state_saved" = "on" ]; then
    if [ "$MEMORY_FOUND" = 1 ]; then
      printf '\n%s\n' "Агенту: как забрать эту память в Taskless"
      print_memory_import_steps 1
    fi
    return 0
  fi
  printf '\n%s\n' "Агенту: личная память Taskless пока не включена"
  print_memory_intro_steps
  if [ "$MEMORY_FOUND" = 1 ]; then
    print_memory_import_steps 3
  fi
}

do_memory_set() {
  if [ "$DRY" = 1 ]; then
    if [ "$MEMORY_SET" = "on" ]; then
      printf '%s\n' "Проверка: включил бы личную память, запросов не отправил."
    else
      printf '%s\n' "Проверка: выключил бы личную память, запросов не отправил."
    fi
    return 0
  fi
  if ! load_key; then
    printf '%s\n' "Сначала подключи агентов: запусти установщик без флагов" >&2
    return 1
  fi
  export TASKLESS_TOKEN="$TOKEN"
  export_base
  capture_helper memory_set "$MEMORY_SET" || return 1
  if [ "$MEMORY_SET" = "on" ]; then
    printf '%s\n' "Личная память включена."
  else
    printf '%s\n' "Личная память выключена. Записи, если были, остались, удалить их можно в профиле."
  fi
}

do_memory_import() {
  if [ "$DRY" != 1 ]; then
    if ! load_key; then
      printf '%s\n' "Сначала подключи агентов: запусти установщик без флагов" >&2
      return 1
    fi
    export TASKLESS_TOKEN="$TOKEN"
    export_base
  fi
  report=$(mktemp)
  errors=$(mktemp)
  if ! capture_helper memory_import "$IMPORT_FILE" "$report" "$DRY" 2>"$errors"; then
    cat "$report"
    cat "$errors" >&2
    rm -f "$report" "$errors"
    return 1
  fi
  cat "$report"
  rm -f "$report" "$errors"
}

do_install() {
  say_header
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "Только показ: ничего не меняю."
  fi
  printf 'Нашёл: %s\n' "$(names_of "$FOUND")"
  if [ "$DRY" = 1 ]; then
    if load_key; then
      printf '%s\n' "Ключ уже есть, вход не прошу."
    else
      printf '%s\n' "Ключ: попросит вход по коду"
    fi
    for id in $FOUND; do
      preview_install "$id"
    done
    printf '\n'
    print_manuals
    print_missing
    report_memory
    return 0
  fi
  ensure_token
  printf '\n'
  connected=
  for id in $FOUND; do
    real_install "$id"
    connected="$connected $id"
  done
  connected=${connected# }
  printf '\n'
  printf 'Подключены: %s\n' "$(names_of "$connected")"
  print_manuals
  print_missing
  save_meta "$connected"
  report_memory
}

agent_connected() {
  if stub_wants "$1"; then
    file=$(stub_file "$1")
    if [ -f "$file" ] && grep -q "# >>> taskless:$1" "$file"; then
      return 0
    fi
    return 1
  fi
  [ -f "$CONFIG_DIR/mcp-headers" ] || return 1
  case "$1" in
    claude-code) claude_config_connected ;;
    codex) codex_config_connected ;;
    *) return 1 ;;
  esac
}

do_status() {
  say_header
  META_DEVICE=
  if [ -f "$META_FILE" ]; then
    capture_helper meta_read "$META_FILE" || die "Не прочитал сведения об устройстве."
  fi
  if [ -n "$META_DEVICE" ]; then
    printf 'Устройство: %s\n' "$META_DEVICE"
  else
    printf '%s\n' "Устройство: нет"
  fi
  if load_key; then
    key_status_line
    rc=0
    probe_key || rc=$?
    if [ "$rc" = 0 ]; then
      printf '%s\n' "Ключ жив."
    elif [ "$rc" = 1 ]; then
      printf '%s\n' "Ключ не принят, запусти подключение ещё раз."
    else
      printf '%s\n' "Не смог проверить ключ."
    fi
  else
    printf '%s\n' "Ключ: нет"
  fi
  for id in $SEARCHED; do
    name=$(agent_name "$id")
    if agent_connected "$id"; then
      printf '%s: подключён\n' "$name"
    elif agent_found "$id"; then
      printf '%s: найден, не подключён\n' "$name"
    else
      printf '%s: не найден\n' "$name"
    fi
  done
}

do_uninstall() {
  say_header
  if [ "$DRY" = 1 ]; then
    printf '%s\n' "Только показ: ничего не меняю."
  fi
  printf '%s\n' "Снимаю поставленное."
  for id in $SEARCHED; do
    agent_remove "$id" "$DRY"
    if [ "$EDIT_CHANGED" = 1 ]; then
      name=$(agent_name "$id")
      if [ "$DRY" = 1 ]; then
        printf '%s: снял бы\n' "$name"
      else
        printf '%s: снято\n' "$name"
      fi
    fi
  done
  if load_key; then
    if [ "$DRY" = 1 ]; then
      printf '%s\n' "Ключ: отозвал бы."
      return 0
    fi
    export TASKLESS_TOKEN="$TOKEN"
    export_base
    capture_helper revoke || die "Не получилось отозвать ключ."
    if [ "$HTTP_STATUS" = 200 ]; then
      clear_key
      rm -f "$META_FILE"
      printf '%s\n' "Ключ отозван."
      return 0
    fi
    printf 'Не получилось отозвать ключ (HTTP %s). Ключ на диске оставил, запусти снятие ещё раз.\n' "$HTTP_STATUS"
    return 1
  fi
  rm -f "$META_FILE"
  printf '%s\n' "Ключа в связке не было."
}

main() {
  if [ -z "${HOME:-}" ]; then
    die "Нет HOME, некуда положить ключ."
  fi
  CONFIG_DIR="$HOME/.config/taskless"
  KEY_FILE="$CONFIG_DIR/device-key"
  META_FILE="$CONFIG_DIR/device.json"
  BASE=${TASKLESS_URL:-https://taskless.ru/api}
  BASE=${BASE%/}
  parse_args "$@"
  require_base
  DEVICE_NAME=$(detect_device_name)
  PLATFORM=$(detect_platform)
  OS_VERSION=$(detect_os_version || true)
  if [ -n "$MEMORY_SET" ]; then
    prepare_helper
    do_memory_set
    exit $?
  fi
  if [ -n "$IMPORT_FILE" ]; then
    prepare_helper
    do_memory_import
    exit $?
  fi
  if [ -n "$MEMORY_DIRS" ]; then
    prepare_helper
    export TASKLESS_MEMORY_DIRS="$MEMORY_DIRS"
    capture_helper memory_validate_dirs || exit 1
  fi
  collect_agents
  if [ "$DO_STATUS" = 1 ]; then
    prepare_helper
    do_status
    exit 0
  fi
  if [ "$DO_UNINSTALL" = 1 ]; then
    prepare_helper
    do_uninstall
    exit $?
  fi
  # Ни одного клиента — код не просим и браузер не открываем (решение 07.11).
  if [ -z "$FOUND" ]; then
    say_header
    printf '%s\n' "агентов не нашёл"
    printf 'Искал: %s\n' "$(names_of "$SEARCHED")"
    exit 0
  fi
  prepare_helper
  do_install
}

main "$@"
