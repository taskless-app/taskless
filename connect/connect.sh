#!/bin/sh
# Taskless: подключение агентов на этом компьютере.
#
# Один файл, его отдают как https://taskless.ru/connect.sh и запускают
# `curl -fsSL https://taskless.ru/connect.sh | sh`. Рядом ничего нет, поэтому
# помощник на python3 или node встроен ниже, а не лежит отдельным файлом.
#
# Режимы: без флагов подключает всех найденных; --dry-run только показывает;
# --only claude-code,codex; --status; --uninstall снимает наши правки и
# отзывает ключ. Ключ — macOS Keychain (`security`), Linux libsecret
# (`secret-tool`), иначе файл ~/.config/taskless/device-key с правами 600.
#
# Адаптер клиента (MCP-105, MCP-106 допишут настоящие) — три действия:
# найти, прописать, снять. Правка файла только блоком между
# `# >>> taskless:<id>` и `# <<< taskless:<id>`. Перед первой правкой —
# копия `<файл>.bak-taskless`. Повтор заменяет блок, чужие строки не трогает.
# Сейчас поиск у всех десяти id из словаря устройства отвечает «нет».
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

# Найти. Настоящий поиск клиента — в адаптере следующей задачи.
# Пока клиент не написан, его на машине нет: код у сервера не просим.
agent_found() {
  if stub_wants "$1"; then
    return 0
  fi
  return 1
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
    if ! stub_wants "$id"; then
      continue
    fi
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
import json, os, re, sys, tempfile, urllib.error, urllib.request

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
        data = json.dumps(payload).encode("utf-8")
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
    # Строка-метка с \n или \r\n: файл могли пересохранить с CRLF. Ближняя из двух.
    # Возвращает (позиция, длина строки с переводом) или (-1, 0).
    best = (-1, 0)
    for nl in (b"\n", b"\r\n"):
        i = find_line(data, mark + nl, start)
        if i >= 0 and (best[0] < 0 or i < best[0]):
            best = (i, len(mark) + len(nl))
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
            sep = b"" if old.endswith(b"\n") or old == b"" else b"\n"
            new = old + sep + block
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
    new = stripped
    if bak is not None and (stripped == bak or (stripped == bak + b"\n" and not bak.endswith(b"\n"))):
        new = bak
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
    elif cmd == "meta_write":
        meta_write()
    elif cmd == "meta_read":
        meta_read()
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
import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync, unlinkSync, statSync, lstatSync, readlinkSync, openSync, closeSync, fchmodSync, writeSync, renameSync } from "node:fs";
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

// Строка-метка с \n или \r\n: файл могли пересохранить с CRLF. Ближняя из двух.
function findMark(data, mark, start) {
  let best = { pos: -1, len: 0 };
  for (const nl of ["\n", "\r\n"]) {
    const needle = Buffer.from(mark + nl);
    const i = findLine(data, needle, start);
    if (i >= 0 && (best.pos < 0 || i < best.pos)) best = { pos: i, len: needle.length };
  }
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
      const sep = old.length === 0 || old[old.length - 1] === 0x0a ? Buffer.alloc(0) : Buffer.from("\n");
      next = Buffer.concat([old, sep, block]);
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
  let next = stripped;
  if (bak && (stripped.equals(bak) || (stripped.equals(Buffer.concat([bak, Buffer.from("\n")])) && bak[bak.length - 1] !== 0x0a))) {
    next = bak;
  }
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
} else if (cmd === "meta_write") {
  metaWrite();
} else if (cmd === "meta_read") {
  metaRead();
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
      rm -f "$KEY_FILE"
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

agent_remove() {
  id=$1
  dry=$2
  EDIT_CHANGED=0
  EDIT_BACKUP=
  if stub_wants "$id"; then
    file=$(stub_file "$id")
    capture_helper edit remove "$file" "# >>> taskless:$id" "# <<< taskless:$id" "$dry" 644 || exit $?
  fi
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
  printf '%s: адаптер ещё не подключает клиент\n' "$name"
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
  printf '%s: адаптер ещё не подключает клиент\n' "$name"
}

save_meta() {
  connected=$1
  export_base
  export TASKLESS_STORE="$STORE_KIND"
  TASKLESS_AGENTS=$(comma_ids "$connected")
  export TASKLESS_AGENTS
  capture_helper meta_write "$META_FILE" || die "Не записал сведения об устройстве."
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
}

agent_connected() {
  if stub_wants "$1"; then
    file=$(stub_file "$1")
    if [ -f "$file" ] && grep -q "# >>> taskless:$1" "$file"; then
      return 0
    fi
  fi
  return 1
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
