// MCP-104: установщик connect.sh в песочнице. HOME — временный каталог,
// сервер — локальная заглушка. Настоящий taskless.ru отсюда не вызывается.
import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { createServer, type Server } from "node:http";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, afterEach, describe, expect, it } from "vitest";

const script = path.resolve(import.meta.dirname, "../connect/connect.sh");
const ps1 = path.resolve(import.meta.dirname, "../connect/connect.ps1");

function pwshWorks(): boolean {
  const res = spawnSync("pwsh", ["-NoProfile", "-Command", "exit 0"], {
    encoding: "utf8",
    timeout: 60_000,
  });
  return res.status === 0;
}

const hasPwsh = pwshWorks();
if (process.env.TASKLESS_REQUIRE_PWSH === "1" && !hasPwsh) {
  throw new Error("TASKLESS_REQUIRE_PWSH=1, а команда pwsh не запускается");
}

// На Маке connect.sh берёт Keychain: настоящий /usr/bin/security с временным
// HOME виснет дольше 12 с, и после vitest остаются висящие security и
// connect.sh. В PATH тестов — заглушка: пишет вызов в лог и отказывает,
// скрипт уходит в файл ~/.config/taskless/device-key, как на Linux без связки.
const FAKE_BIN = mkdtempSync(path.join(tmpdir(), "connect-fakebin-"));
const SECURITY_LOG = path.join(FAKE_BIN, "security.log");
writeFileSync(
  path.join(FAKE_BIN, "security"),
  `#!/bin/sh\nprintf '%s\\n' "$*" >> '${SECURITY_LOG}'\ncat > /dev/null\nexit 1\n`,
);
chmodSync(path.join(FAKE_BIN, "security"), 0o755);
const TEST_PATH = `${FAKE_BIN}:${process.env.PATH}`;
afterAll(() => rmSync(FAKE_BIN, { recursive: true, force: true }));
// Тесты связки secret-tool и platform=linux идут только на Linux: на Darwin
// скрипт выбирает Keychain, а не secret-tool, и шлёт platform=macos.
const IS_LINUX = process.platform === "linux";
const IS_MAC = process.platform === "darwin";
const PLATFORM = IS_MAC ? "macos" : "linux";

const ORIGINAL = "чужой сервер mcp\n";
// Наш блок из прошлой установки, файл потом пересохранили с CRLF. Хвост — человека.
const CRLF_CONF = `${ORIGINAL}# >>> taskless:claude-code\r\nold=1\r\n# <<< taskless:claude-code\r\nuser1=keep\r\n`;
const DEVICE = "тестовый-ноутбук";
const TOKEN = "tldev_testtoken";
const CODE_LINE = "Код подключения: ABCD-EFGH";
const BROWSER_LINE = "Открываю браузер: https://taskless.ru/connect?code=ABCD-EFGH";
const BROWSER_HINT = "Если браузер не открылся, открой ссылку сам. Код живёт 10 минут.";
const WAIT_LINE = "Жду подтверждения в браузере…";
const FILE_KEY_LINE = "Вход подтверждён, ключ сохранён в файле ~/.config/taskless/device-key.";
const SEARCHED =
  "Искал: Claude Code, Codex, Grok, ZCode, Cursor, Gemini CLI, OpenCode, Copilot CLI, Qwen Code, Kimi CLI";

// http:// на петле: хост — ровно localhost или 127.0.0.1, порт из цифр, дальше
// «/» или конец. userinfo, фрагмент, %40 и длинное имя уводят на чужой хост.
const BAD_HTTP = [
  "http://127.0.0.1:x@evil.invalid/api",
  "http://localhost:1@evil.invalid/api",
  "http://127.0.0.1@evil.invalid/api",
  "http://127.0.0.1#@evil.invalid/api",
  "http://localhost#@evil.invalid/api",
  "http://127.0.0.1%40evil.invalid/api",
  "http://127.0.0.1.evil.com/api",
  "http://localhost.evil.com/api",
  "http://localhost?@evil.invalid/api",
];
const GOOD_HTTP = [
  "http://127.0.0.1:56150/api",
  "http://localhost/api",
  "http://localhost:3000",
  "http://127.0.0.1",
];
// Регистр, «чужие» цифры и перевод строки: sh отказывает, ps1 должен так же (зеркало).
const BAD_ANY = [
  "HTTP://LOCALHOST/api",
  "HTTPS://taskless.ru/api",
  "http://127.0.0.1:\u0668\u0660/api",
  "http://localhost\n",
];

interface Hit {
  method: string;
  url: string;
  body: string;
  auth: string;
  at: number;
}

interface Stub {
  url: string;
  hits: Hit[];
  /** Какой ответ отдать на POST /oauth/token. По умолчанию сразу ключ. */
  token: (call: number) => { status: number; body: unknown; retryAfter?: string };
  /** Поле interval в ответе device_authorization. 0 — первый опрос без паузы. */
  pollInterval: number;
  memoryState: null | "on" | "off";
  memorySettingsStatus: number;
  memoryImportStatus: number;
  memoryImportFailAt: number;
  memoryImportReasons: boolean;
  close: () => Promise<void>;
}

const closers: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (closers.length) {
    const close = closers.pop();
    if (close) await close();
  }
});

function listen(server: Server): Promise<number> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("нет порта"));
        return;
      }
      resolve(addr.port);
    });
  });
}

async function startStub(): Promise<Stub> {
  const hits: Hit[] = [];
  let tokenCalls = 0;
  const stub: Stub = {
    url: "",
    hits,
    token: () => ({
      status: 200,
      body: { access_token: TOKEN, token_type: "Bearer", scope: "taskless:full" },
    }),
    pollInterval: 0,
    memoryState: "off",
    memorySettingsStatus: 200,
    memoryImportStatus: 200,
    memoryImportFailAt: 0,
    memoryImportReasons: false,
    close: async () => {},
  };
  const server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      const url = req.url ?? "";
      hits.push({
        method: req.method ?? "",
        url,
        body,
        auth: typeof req.headers.authorization === "string" ? req.headers.authorization : "",
        at: Date.now(),
      });
      const send = (status: number, payload: unknown, retryAfter?: string) => {
        const raw = JSON.stringify(payload);
        res.statusCode = status;
        res.setHeader("content-type", "application/json");
        if (retryAfter) res.setHeader("retry-after", retryAfter);
        res.end(raw);
      };
      if (url === "/oauth/device_authorization" && req.method === "POST") {
        send(200, {
          device_code: "tldc_test",
          user_code: "ABCD-EFGH",
          verification_uri: "https://taskless.ru/connect",
          verification_uri_complete: "https://taskless.ru/connect?code=ABCD-EFGH",
          expires_in: 600,
          interval: stub.pollInterval,
        });
        return;
      }
      if (url === "/oauth/token" && req.method === "POST") {
        tokenCalls += 1;
        const next = stub.token(tokenCalls);
        send(next.status, next.body, next.retryAfter);
        return;
      }
      if (url === "/auth/me" && req.method === "GET") {
        if (req.headers.authorization === `Bearer ${TOKEN}`) send(200, { ok: true });
        else send(401, { error: "unauthorized" });
        return;
      }
      if (url === "/memory/personal/settings" && req.method === "GET") {
        if (stub.memorySettingsStatus === 0) {
          req.socket.destroy();
          return;
        }
        if (stub.memorySettingsStatus === 200) send(200, { state: stub.memoryState, claims: [] });
        else send(stub.memorySettingsStatus, { error: "settings_unavailable", message: "Настройки памяти недоступны" });
        return;
      }
      if (url === "/memory/personal/settings" && req.method === "PUT") {
        if (stub.memorySettingsStatus === 200) {
          const enabled = Boolean(JSON.parse(body).enabled);
          send(200, { state: enabled ? "on" : "off", claims: [] });
        } else send(stub.memorySettingsStatus, { error: "settings_unavailable", message: "Не удалось сменить настройку" });
        return;
      }
      if (url === "/memory/personal/import" && req.method === "POST") {
        const importCall = hits.filter((hit) => hit.url === url && hit.method === "POST").length;
        const status = stub.memoryImportFailAt === importCall ? 429 : stub.memoryImportStatus;
        if (status !== 200) {
          send(status, { error: "import_refused", message: `Сервер отклонил импорт: ${status}` });
          return;
        }
        const batch = JSON.parse(body) as { files: Array<{ path: string; items: unknown[] }> };
        const skippedByReason = stub.memoryImportReasons
          ? { secret: 1, too_long: 1, empty: 1, rule_without_quote: 1, retracted: 1 }
          : {};
        const files = batch.files.map((file) => ({
          file: file.path,
          new: stub.memoryImportReasons ? Math.max(0, file.items.length - 7) : file.items.length,
          known: stub.memoryImportReasons ? 1 : 0,
          duplicate: stub.memoryImportReasons ? 1 : 0,
          skipped: stub.memoryImportReasons ? 5 : 0,
          skippedByReason,
        }));
        const itemCount = batch.files.reduce((sum, file) => sum + file.items.length, 0);
        send(200, {
          importId: "import-test",
          client: null,
          createdAt: new Date().toISOString(),
          itemCount,
          new: files.reduce((sum, file) => sum + file.new, 0),
          known: files.reduce((sum, file) => sum + file.known, 0),
          duplicate: files.reduce((sum, file) => sum + file.duplicate, 0),
          skipped: files.reduce((sum, file) => sum + file.skipped, 0),
          skippedByReason,
          files,
          items: [],
        });
        return;
      }
      if (url === "/oauth/revoke" && req.method === "POST") {
        send(200, {});
        return;
      }
      send(404, { error: "not_found" });
    });
  });
  const port = await listen(server);
  stub.url = `http://127.0.0.1:${port}`;
  stub.close = () =>
    new Promise((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()));
    });
  closers.push(stub.close);
  return stub;
}

function filesUnder(root: string): string[] {
  if (!existsSync(root)) return [];
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const ent of readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(p);
      else if (ent.isFile()) out.push(path.relative(root, p));
    }
  };
  walk(root);
  return out.sort();
}

function treeHash(root: string, ignore: (rel: string) => boolean = () => false): string {
  const h = createHash("sha256");
  const files = filesUnder(root).filter((rel) => !ignore(rel));
  for (const rel of files) {
    const abs = path.join(root, rel);
    h.update(rel);
    h.update("\0");
    h.update(readFileSync(abs));
    h.update("\0");
    h.update(String(statSync(abs).mode & 0o777));
    h.update("\0");
  }
  return `${files.length}:${h.digest("hex")}`;
}

function run(
  home: string,
  args: string[],
  extra: Record<string, string | undefined>,
): Promise<{ code: number; stdout: string; stderr: string }> {
  const env: NodeJS.ProcessEnv = {
    PATH: extra.PATH ?? TEST_PATH,
    HOME: home,
    USERPROFILE: home,
    TMPDIR: process.env.TMPDIR || "/tmp",
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
  };
  for (const [k, v] of Object.entries(extra)) {
    if (k === "PATH") continue;
    if (v === undefined) continue;
    env[k] = v;
  }
  // tests-packages (self-hosted, прогон 42725784249): auto берёт python3,
  // и три теста входа оборваны на 5000 мс без ассёртов. Тот же вход с node
  // в этом прогоне занял ~1 с. Помощник на python в скрипте остаётся путём
  // по умолчанию для машин без node.
  if (env.TASKLESS_RUNTIME === undefined) env.TASKLESS_RUNTIME = "node";
  // spawn, не spawnSync: синхронный запуск глушит цикл событий, и заглушка
  // в этом же процессе не успевает ответить на вход по коду.
  return new Promise((resolve, reject) => {
    const child = spawn("sh", [script, ...args], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      // На загруженном self-hosted (turbo гоняет пакеты параллельно) один
      // запуск с python3 не укладывается в 20 с. spawn шлёт SIGTERM, ловушка
      // в connect.sh выходит 143. Так упал симлинк-тест на прогоне 42745947111.
      timeout: 60_000,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      reject(new Error(`${err.message}\n${stdout}\n${stderr}`));
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

function runPs1(
  home: string,
  args: string[],
  extra: Record<string, string | undefined>,
  scriptblock = false,
): Promise<{ code: number; stdout: string; stderr: string }> {
  const env: NodeJS.ProcessEnv = {
    PATH: extra.PATH ?? TEST_PATH,
    HOME: home,
    USERPROFILE: home,
    TMPDIR: process.env.TMPDIR || "/tmp",
    LANG: "C.UTF-8",
    LC_ALL: "C.UTF-8",
  };
  for (const [k, v] of Object.entries(extra)) {
    if (k === "PATH") continue;
    if (v === undefined) continue;
    env[k] = v;
  }
  return new Promise((resolve, reject) => {
    const quotedPath = ps1.replace(/'/g, "''");
    const quotedArgs = args.map((arg) => `'${arg.replace(/'/g, "''")}'`).join(" ");
    const invocation = scriptblock
      ? ["-Command", `& ([scriptblock]::Create((Get-Content -LiteralPath '${quotedPath}' -Raw))) ${quotedArgs}`]
      : ["-File", ps1, ...args];
    const child = spawn("pwsh", ["-NoProfile", ...invocation], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 40_000,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      reject(new Error(`${err.message}\n${stdout}\n${stderr}`));
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

function plant(home: string): string {
  const conf = path.join(home, ".taskless-stub", "claude-code.conf");
  mkdirSync(path.dirname(conf), { recursive: true });
  writeFileSync(conf, ORIGINAL);
  return conf;
}

function countMarker(text: string, id: string): number {
  return text.split(`# >>> taskless:${id}`).length - 1;
}

const CLAUDE_FOREIGN = `{
  "zBefore": true,
  "mcpServers": {
    "foreign": { "type": "http", "url": "https://foreign.example/mcp" }
  },
  "projects": { "/work": { "hasTrustDialogAccepted": true } }
}
`;
const CODEX_FOREIGN = `model = "gpt-test"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`;
const CODEX_EXISTING = `${CODEX_FOREIGN}[mcp_servers.taskless]
url = "https://old.example/mcp"
startup_timeout_sec = 5
`;
const CODEX_EXISTING_VARIANTS = [
  { name: "голая таблица", text: CODEX_EXISTING },
  {
    name: "массив таблиц после taskless",
    text: `model = "gpt-test"
[mcp_servers.taskless]
url = "https://old.example/mcp"
[[skills.config]]
path = "keep/skill"
enabled = false
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
    keep: ["[[skills.config]]", 'path = "keep/skill"', "enabled = false"],
  },
  {
    name: "таблица в двойных кавычках",
    text: `${CODEX_FOREIGN}[mcp_servers."taskless"]
url = "https://old.example/mcp"
[mcp_servers."taskless".env]
OLD = "1"
`,
  },
  {
    name: "таблица в одинарных кавычках и с пробелами",
    text: `${CODEX_FOREIGN}[ mcp_servers . 'taskless' ]
url = "https://old.example/mcp"
`,
  },
  {
    name: "inline-таблица",
    text: `model = "gpt-test"
[mcp_servers]
taskless = { url = "https://old.example/mcp", startup_timeout_sec = 5 }
foreign = { url = "https://foreign.example/mcp" }
`,
  },
  {
    name: "plugin-таблица",
    text: `${CODEX_FOREIGN}[plugins."taskless@taskless-app".mcp_servers.taskless]
enabled = true
`,
  },
  {
    name: "dotted-ключи",
    text: `model = "gpt-test"
mcp_servers.taskless.url = "https://old.example/mcp"
mcp_servers.taskless.startup_timeout_sec = 5
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
  },
];
const CODEX_SCANNER_VARIANTS = [
  {
    name: "многострочная basic-строка",
    outcome: "keep",
    text: `description = """
[mcp_servers.taskless]
url = "https://old.example/mcp"
"""
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
  },
  {
    name: "многострочная literal-строка",
    outcome: "keep",
    text: `description = '''
[mcp_servers.taskless]
url = "https://old.example/mcp"
'''
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
  },
  {
    name: "установка после файла без завершающего перевода строки",
    outcome: "replace",
    text: CODEX_FOREIGN.trimEnd(),
  },
  {
    name: "одноимённый inline-ключ внутри чужой таблицы",
    outcome: "keep",
    text: `[profiles.work]
mcp_servers = { url = "https://old.example/mcp" }
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
  },
  {
    name: "корневая inline-таблица",
    outcome: "reject",
    text: `mcp_servers = { taskless = { url = "https://old.example/mcp" }, foreign = { url = "https://foreign.example/mcp" } }
`,
  },
  {
    name: "корневая inline-таблица с taskless не первым",
    outcome: "reject",
    text: `mcp_servers = { foreign = { url = "https://foreign.example/mcp" }, taskless = { url = "https://old.example/mcp" } }
`,
  },
  {
    name: "многострочный dotted-ключ",
    outcome: "replace",
    text: `mcp_servers.taskless.args = [
  "--old",
]
mcp_servers.taskless.url = "https://old.example/mcp"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`,
  },
];

function realHome(stubUrl: string, runtime = "node", empty = false) {
  const home = mkdtempSync(path.join(tmpdir(), "connect-real-home-"));
  const bin = mkdtempSync(path.join(tmpdir(), "connect-real-bin-"));
  const log = path.join(bin, "clients.log");
  for (const client of ["claude", "codex"]) {
    const file = path.join(bin, client);
    writeFileSync(file, `#!/bin/sh\nprintf '%s|%s\\n' '${client}' "$*" >> "$TASKLESS_TEST_CLIENT_LOG"\n`);
    chmodSync(file, 0o755);
  }
  const claudeJson = path.join(home, ".claude.json");
  const codexToml = path.join(home, ".codex", "config.toml");
  mkdirSync(path.dirname(codexToml), { recursive: true });
  writeFileSync(claudeJson, empty ? "{}" : CLAUDE_FOREIGN);
  writeFileSync(codexToml, empty ? "" : CODEX_FOREIGN);
  const env = {
    PATH: `${bin}:${TEST_PATH}`,
    TASKLESS_TEST_CLIENT_LOG: log,
    TASKLESS_URL: stubUrl,
    TASKLESS_DEVICE_NAME: DEVICE,
    TASKLESS_BROWSER: "true",
    TASKLESS_KEY_STORE: "file",
    TASKLESS_RUNTIME: runtime,
  };
  return { home, bin, log, env, claudeJson, codexToml };
}

function removeRealHome(setup: ReturnType<typeof realHome>) {
  rmSync(setup.home, { recursive: true, force: true });
  rmSync(setup.bin, { recursive: true, force: true });
}

describe("connect.sh: настоящие адаптеры Claude Code и Codex", () => {
  it("чужие конфиги: dry-run, установка, повтор, status и uninstall", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const helper = path.join(setup.home, ".config", "taskless", "mcp-headers");
    const args = ["--only", "claude-code,codex"];
    const before = treeHash(setup.home);
    const dry = await run(setup.home, [...args, "--dry-run"], setup.env);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(treeHash(setup.home)).toBe(before);
    expect(existsSync(setup.log)).toBe(false);

    const first = await run(setup.home, args, setup.env);
    expect(first.code, first.stdout + first.stderr).toBe(0);
    expect(first.stdout).toContain("в Codex одобри хуки командой /hooks");
    const claude = JSON.parse(readFileSync(setup.claudeJson, "utf8")) as {
      zBefore: boolean;
      mcpServers: Record<string, Record<string, unknown>>;
      projects: Record<string, unknown>;
    };
    expect(Object.keys(claude)).toEqual(["zBefore", "mcpServers", "projects"]);
    expect(claude.zBefore).toBe(true);
    expect(claude.mcpServers.foreign).toEqual({ type: "http", url: "https://foreign.example/mcp" });
    expect(claude.mcpServers.taskless).toEqual({
      type: "http",
      url: `${stub.url}/mcp`,
      headersHelper: `sh "${helper}"`,
    });
    const codex = readFileSync(setup.codexToml, "utf8");
    expect(codex.startsWith(CODEX_FOREIGN)).toBe(true);
    expect(countMarker(codex, "codex")).toBe(1);
    expect(codex).toContain("[mcp_servers.taskless]");
    expect(codex).toContain(`url = "${stub.url}/mcp"`);
    expect(codex).toContain("http_headers_helper");
    expect(codex).toContain('[plugins."taskless@taskless-app".mcp_servers.taskless]');
    expect(codex).toContain("enabled = false");
    expect(statSync(helper).mode & 0o777).toBe(0o700);
    const headers = spawnSync("sh", [helper], { env: { ...process.env, HOME: setup.home }, encoding: "utf8" });
    expect(headers.status, headers.stderr).toBe(0);
    expect(JSON.parse(headers.stdout)).toEqual({ Authorization: `Bearer ${TOKEN}` });
    const calls = readFileSync(setup.log, "utf8");
    expect(calls).toContain("claude|plugin marketplace add taskless-app/taskless");
    expect(calls).toContain("claude|plugin install taskless@taskless-app --scope user");
    expect(calls).toContain("codex|plugin marketplace add taskless-app/taskless");
    expect(calls).toContain("codex|plugin add taskless@taskless-app");

    const installedClaude = readFileSync(setup.claudeJson);
    const installedCodex = readFileSync(setup.codexToml);
    const again = await run(setup.home, args, setup.env);
    expect(again.code, again.stdout + again.stderr).toBe(0);
    expect(readFileSync(setup.claudeJson)).toEqual(installedClaude);
    expect(readFileSync(setup.codexToml)).toEqual(installedCodex);
    expect(countMarker(readFileSync(setup.codexToml, "utf8"), "codex")).toBe(1);
    const status = await run(setup.home, ["--status", ...args], setup.env);
    expect(status.code, status.stdout + status.stderr).toBe(0);
    expect(status.stdout).toContain("Claude Code: подключён");
    expect(status.stdout).toContain("Codex: подключён");

    const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(readFileSync(setup.claudeJson, "utf8")).toBe(CLAUDE_FOREIGN);
    expect(readFileSync(setup.codexToml, "utf8")).toBe(CODEX_FOREIGN);
    expect(existsSync(helper)).toBe(false);
    const removed = readFileSync(setup.log, "utf8");
    expect(removed).toContain("claude|plugin uninstall taskless@taskless-app --scope user");
    expect(removed).toContain("codex|plugin remove taskless@taskless-app");
    removeRealHome(setup);
  }, 90_000);

  for (const runtime of ["node", "python3"]) {
    it(`Claude JSON на ${runtime}: status и uninstall после смены TASKLESS_URL`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime);
      const args = ["--only", "claude-code"];
      const installed = await run(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      const driftStub = await startStub();
      const driftEnv = { ...setup.env, TASKLESS_URL: driftStub.url };

      const status = await run(setup.home, ["--status", ...args], driftEnv);
      expect(status.code, status.stdout + status.stderr).toBe(0);
      expect.soft(status.stdout).toContain("Claude Code: подключён");
      const gone = await run(setup.home, ["--uninstall", ...args], driftEnv);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      expect(readFileSync(setup.claudeJson, "utf8")).toBe(CLAUDE_FOREIGN);
      expect(existsSync(path.join(setup.home, ".config", "taskless", "mcp-headers"))).toBe(false);
      removeRealHome(setup);
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`права копии Claude JSON на ${runtime}: не шире 600`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime);
      chmodSync(setup.claudeJson, 0o600);
      const installed = await run(setup.home, ["--only", "claude-code"], setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      expect(statSync(`${setup.claudeJson}.bak-taskless`).mode & 0o777).toBe(0o600);
      removeRealHome(setup);
    }, 90_000);
  }

  it("python3 сохраняет исходный порядок верхних ключей Claude JSON", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url, "python3");
    const installed = await run(setup.home, ["--only", "claude-code"], setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    const claude = JSON.parse(readFileSync(setup.claudeJson, "utf8")) as Record<string, unknown>;
    expect(Object.keys(claude)).toEqual(["zBefore", "mcpServers", "projects"]);
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!IS_LINUX)("libsecret без D-Bus: Codex helper возвращает Authorization из файловой копии", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const store = path.join(setup.home, "keyring");
    writeFileSync(
      path.join(setup.bin, "secret-tool"),
      `#!/bin/sh
case "$1" in
  store) cat > "${store}" ;;
  lookup) [ -n "\${DBUS_SESSION_BUS_ADDRESS:-}" ] || exit 1; cat "${store}" ;;
  clear) rm -f "${store}" ;;
  *) exit 1 ;;
esac
`,
    );
    chmodSync(path.join(setup.bin, "secret-tool"), 0o755);
    const env = { ...setup.env, TASKLESS_KEY_STORE: undefined };
    const installed = await run(setup.home, ["--only", "codex"], env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    expect(readFileSync(store, "utf8")).toBe(TOKEN);

    const helper = path.join(setup.home, ".config", "taskless", "mcp-headers");
    const headers = spawnSync("sh", [helper], {
      env: { HOME: setup.home, PATH: setup.env.PATH },
      encoding: "utf8",
    });
    expect(headers.status, headers.stderr).toBe(0);
    expect(JSON.parse(headers.stdout)).toEqual({ Authorization: `Bearer ${TOKEN}` });
    const keyFile = path.join(setup.home, ".config", "taskless", "device-key");
    expect(readFileSync(keyFile, "utf8")).toBe(`${TOKEN}\n`);
    expect(statSync(keyFile).mode & 0o777).toBe(0o600);
    removeRealHome(setup);
  }, 90_000);

  for (const runtime of ["node", "python3"]) {
    it(`существующий Codex taskless на ${runtime}: замена без дублей и uninstall`, async () => {
      const stub = await startStub();
      for (const variant of CODEX_EXISTING_VARIANTS) {
        const setup = realHome(stub.url, runtime);
        writeFileSync(setup.codexToml, variant.text);
        const args = ["--only", "codex"];
        const before = treeHash(setup.home);
        const dry = await run(setup.home, [...args, "--dry-run"], setup.env);
        expect(dry.code, `${variant.name}: ${dry.stdout}${dry.stderr}`).toBe(0);
        expect(treeHash(setup.home), variant.name).toBe(before);

        const first = await run(setup.home, args, setup.env);
        expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(0);
        const codex = readFileSync(setup.codexToml, "utf8");
        expect(codex.split("[mcp_servers.taskless]").length - 1, variant.name).toBe(1);
        expect(codex.split('[plugins."taskless@taskless-app".mcp_servers.taskless]').length - 1, variant.name).toBe(1);
        expect(codex, variant.name).toContain("https://foreign.example/mcp");
        for (const kept of variant.keep ?? []) expect(codex, variant.name).toContain(kept);
        expect(codex, variant.name).not.toContain("https://old.example/mcp");
        expect(codex, variant.name).toContain(`url = "${stub.url}/mcp"`);
        const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
          input: codex,
          encoding: "utf8",
        });
        expect(parsed.status, `${variant.name}: ${parsed.stderr}`).toBe(0);

        const again = await run(setup.home, args, setup.env);
        expect(again.code, `${variant.name}: ${again.stdout}${again.stderr}`).toBe(0);
        expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(codex);
        const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
        expect(gone.code, `${variant.name}: ${gone.stdout}${gone.stderr}`).toBe(0);
        expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
        removeRealHome(setup);
      }
    }, 180_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`Codex TOML на ${runtime}: строки и многострочные значения не ломают установку`, async () => {
      const stub = await startStub();
      for (const variant of CODEX_SCANNER_VARIANTS) {
        const setup = realHome(stub.url, runtime);
        writeFileSync(setup.codexToml, variant.text);
        const args = ["--only", "codex"];
        const first = await run(setup.home, args, setup.env);
        if (variant.outcome === "reject") {
          expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(1);
          expect(first.stdout + first.stderr, variant.name).toContain("Файл не меняю");
          expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
          removeRealHome(setup);
          continue;
        }
        expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(0);
        const codex = readFileSync(setup.codexToml, "utf8");
        expect(codex, variant.name).toContain("https://foreign.example/mcp");
        if (variant.outcome === "keep") expect(codex, variant.name).toContain("https://old.example/mcp");
        else expect(codex, variant.name).not.toContain("https://old.example/mcp");
        const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
          input: codex,
          encoding: "utf8",
        });
        expect(parsed.status, `${variant.name}: ${parsed.stderr}`).toBe(0);
        const again = await run(setup.home, args, setup.env);
        expect(again.code, `${variant.name}: ${again.stdout}${again.stderr}`).toBe(0);
        expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(codex);
        const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
        expect(gone.code, `${variant.name}: ${gone.stdout}${gone.stderr}`).toBe(0);
        expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
        removeRealHome(setup);
      }
    }, 180_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`uninstall Codex на ${runtime} сохраняет внешнюю правку выше старой таблицы`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime);
      const original = `model = "gpt-5"
[mcp_servers.taskless]
url = "https://old.example/mcp"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`;
      writeFileSync(setup.codexToml, original);
      const args = ["--only", "codex"];
      const installed = await run(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      const edited = readFileSync(setup.codexToml, "utf8").replace('model = "gpt-5"', 'model = "gpt-5.1-codex-max"');
      writeFileSync(setup.codexToml, edited);

      const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      const expected = original.replace('model = "gpt-5"', 'model = "gpt-5.1-codex-max"');
      const restored = readFileSync(setup.codexToml, "utf8");
      expect(restored).toBe(expected);
      const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
        input: restored,
        encoding: "utf8",
      });
      expect(parsed.status, parsed.stderr).toBe(0);
      removeRealHome(setup);
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`uninstall Codex на ${runtime} сохраняет новую строку выше старой таблицы`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime);
      const original = `model = "gpt-5"
[mcp_servers.taskless]
url = "https://old.example/mcp"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`;
      writeFileSync(setup.codexToml, original);
      const args = ["--only", "codex"];
      const installed = await run(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      const replacement = 'model = "gpt-5"\nmodel_reasoning_effort = "xhigh"';
      writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8").replace('model = "gpt-5"', replacement));

      const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      const restored = readFileSync(setup.codexToml, "utf8");
      expect(restored).toBe(original.replace('model = "gpt-5"', replacement));
      const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
        input: restored,
        encoding: "utf8",
      });
      expect(parsed.status, parsed.stderr).toBe(0);
      removeRealHome(setup);
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`uninstall Codex на ${runtime}: внешний хвост без перевода строки`, async () => {
      const stub = await startStub();
      const oldTaskless = `[mcp_servers.taskless]
url = "https://old.example/mcp"
`;
      const original = `${CODEX_FOREIGN}${oldTaskless}`;
      for (const eol of ["\n", "\r\n"]) {
        const setup = realHome(stub.url, runtime);
        writeFileSync(setup.codexToml, original.replaceAll("\n", eol));
        const args = ["--only", "codex"];
        const installed = await run(setup.home, args, setup.env);
        expect(installed.code, installed.stdout + installed.stderr).toBe(0);
        const addition = `\n[tui]\nnotifications = true`;
        writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8") + addition.replaceAll("\n", eol));

        const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
        expect(gone.code, gone.stdout + gone.stderr).toBe(0);
        const expected = `${CODEX_FOREIGN}${addition}\n${oldTaskless}`.replaceAll("\n", eol);
        const restored = readFileSync(setup.codexToml, "utf8");
        expect(restored).toBe(expected);
        const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
          input: restored,
          encoding: "utf8",
        });
        expect(parsed.status, parsed.stderr).toBe(0);
        removeRealHome(setup);
      }
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`uninstall Codex на ${runtime}: предупреждение о потерянном якоре массива`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime);
      const original = CODEX_EXISTING_VARIANTS.find((variant) => variant.name === "массив таблиц после taskless")!.text;
      writeFileSync(setup.codexToml, original);
      const args = ["--only", "codex"];
      const installed = await run(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8").replace("[[skills.config]]\n", ""));

      const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      expect(gone.stderr).toContain("заголовок [[skills.config]] не найден");
      expect(gone.stderr).not.toContain("заголовок []skills.config не найден");
      removeRealHome(setup);
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`Codex без исходного config.toml на ${runtime}: dry-run и uninstall`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime, true);
      rmSync(setup.codexToml);
      const args = ["--only", "codex"];
      const installed = await run(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      const before = readFileSync(setup.codexToml);
      const dry = await run(setup.home, ["--uninstall", ...args, "--dry-run"], setup.env);
      expect(dry.code, dry.stdout + dry.stderr).toBe(0);
      expect(readFileSync(setup.codexToml)).toEqual(before);
      expect(stub.hits.filter((hit) => hit.url === "/oauth/revoke")).toHaveLength(0);
      const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      expect(existsSync(setup.codexToml)).toBe(false);
      expect(stub.hits.filter((hit) => hit.url === "/oauth/revoke")).toHaveLength(1);
      removeRealHome(setup);
    }, 90_000);
  }

  for (const runtime of ["node", "python3"]) {
    it(`пустые конфиги на ${runtime}: uninstall возвращает их как были`, async () => {
      const stub = await startStub();
      const setup = realHome(stub.url, runtime, true);
      const args = ["--only", "claude-code,codex"];
      const first = await run(setup.home, args, setup.env);
      expect(first.code, first.stdout + first.stderr).toBe(0);
      expect(readFileSync(setup.claudeJson, "utf8")).toContain('"taskless"');
      expect(readFileSync(setup.codexToml, "utf8")).toContain("[mcp_servers.taskless]");
      const gone = await run(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      expect(readFileSync(setup.claudeJson, "utf8")).toBe("{}");
      expect(readFileSync(setup.codexToml, "utf8")).toBe("");
      removeRealHome(setup);
    }, 90_000);
  }
});

describe("connect.ps1", () => {
  it.skipIf(!hasPwsh)("pwsh: scriptblock получает --dry-run и не меняет HOME", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const installerHash = () => treeHash(setup.home, (rel) => rel.startsWith(".cache/powershell/"));
    const before = installerHash();
    const dry = await runPs1(setup.home, ["--only", "claude-code,codex", "--dry-run"], setup.env, true);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(dry.stdout).toContain("Только показ: ничего не меняю.");
    expect(installerHash()).toBe(before);
    removeRealHome(setup);
  }, 60_000);

  it.skipIf(!hasPwsh)("pwsh: dry-run, повтор без дублей и uninstall чужих конфигов", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const args = ["--only", "claude-code,codex"];
    // Сам pwsh создаёт telemetry.uuid и StartupProfileData даже при -NoProfile.
    // Это не файлы установщика; все остальные байты HOME обязаны остаться как были.
    const installerHash = () => treeHash(setup.home, (rel) => rel.startsWith(".cache/powershell/"));
    const before = installerHash();
    const dry = await runPs1(setup.home, [...args, "--dry-run"], setup.env);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(installerHash()).toBe(before);
    const first = await runPs1(setup.home, args, setup.env);
    expect(first.code, first.stdout + first.stderr).toBe(0);
    expect(first.stdout).toContain("claude plugin install taskless@taskless-app --scope user");
    expect(first.stdout).toContain("codex plugin add taskless@taskless-app");
    const claude = JSON.parse(readFileSync(setup.claudeJson, "utf8")) as { mcpServers: Record<string, { url?: string; headersHelper?: string }> };
    expect(claude.mcpServers.foreign?.url).toBe("https://foreign.example/mcp");
    expect(claude.mcpServers.taskless?.url).toBe(`${stub.url}/mcp`);
    expect(claude.mcpServers.taskless?.headersHelper).toContain("mcp-headers.ps1");
    expect(claude.mcpServers.taskless?.headersHelper).toContain("-NoProfile -ExecutionPolicy Bypass -File");
    const codex = readFileSync(setup.codexToml, "utf8");
    expect(codex).toContain("[mcp_servers.taskless]");
    expect(codex).toContain('http_headers_helper = "pwsh -NoProfile -ExecutionPolicy Bypass -File');
    const installedClaude = readFileSync(setup.claudeJson);
    const installedCodex = readFileSync(setup.codexToml);
    const again = await runPs1(setup.home, args, setup.env);
    expect(again.code, again.stdout + again.stderr).toBe(0);
    expect(readFileSync(setup.claudeJson)).toEqual(installedClaude);
    expect(readFileSync(setup.codexToml)).toEqual(installedCodex);
    const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(readFileSync(setup.claudeJson, "utf8")).toBe(CLAUDE_FOREIGN);
    expect(readFileSync(setup.codexToml, "utf8")).toBe(CODEX_FOREIGN);
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: Claude status и uninstall после смены TASKLESS_URL", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const args = ["--only", "claude-code"];
    const installed = await runPs1(setup.home, args, setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    const driftStub = await startStub();
    const driftEnv = { ...setup.env, TASKLESS_URL: driftStub.url };

    const status = await runPs1(setup.home, ["--status", ...args], driftEnv);
    expect(status.code, status.stdout + status.stderr).toBe(0);
    expect.soft(status.stdout).toContain("Claude Code: подключён");
    const gone = await runPs1(setup.home, ["--uninstall", ...args], driftEnv);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(readFileSync(setup.claudeJson, "utf8")).toBe(CLAUDE_FOREIGN);
    expect(existsSync(path.join(setup.home, ".config", "taskless", "mcp-headers.ps1"))).toBe(false);
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: пустой, отсутствующий и без mcpServers Claude JSON", async () => {
    const stub = await startStub();
    for (const initial of [
      "{}",
      null,
      '{"projects":{"/work":{"hasTrustDialogAccepted":true}}}',
    ]) {
      const setup = realHome(stub.url, "node", true);
      if (initial === null) {
        rmSync(setup.claudeJson);
        mkdirSync(path.join(setup.home, ".claude"));
      } else writeFileSync(setup.claudeJson, initial);
      const args = ["--only", "claude-code"];
      const first = await runPs1(setup.home, args, setup.env);
      expect(first.code, `${initial}: ${first.stdout}${first.stderr}`).toBe(0);
      const claude = JSON.parse(readFileSync(setup.claudeJson, "utf8")) as {
        mcpServers?: Record<string, { url?: string; headersHelper?: string }>;
      };
      expect(claude.mcpServers?.taskless?.url, `исходник: ${initial}`).toBe(`${stub.url}/mcp`);
      expect(claude.mcpServers?.taskless?.headersHelper).toContain("mcp-headers.ps1");
      const status = await runPs1(setup.home, ["--status", ...args], setup.env);
      expect(status.code, status.stdout + status.stderr).toBe(0);
      expect(status.stdout).toContain("Claude Code: подключён");
      const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, `${initial}: ${gone.stdout}${gone.stderr}`).toBe(0);
      if (initial === null) expect(existsSync(setup.claudeJson)).toBe(false);
      else expect(readFileSync(setup.claudeJson, "utf8"), `исходник: ${initial}`).toBe(initial);
      removeRealHome(setup);
    }
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: существующий Codex taskless заменяется и возвращается при uninstall", async () => {
    const stub = await startStub();
    for (const variant of CODEX_EXISTING_VARIANTS) {
      const setup = realHome(stub.url);
      writeFileSync(setup.codexToml, variant.text);
      const args = ["--only", "codex"];
      const first = await runPs1(setup.home, args, setup.env);
      expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(0);
      const codex = readFileSync(setup.codexToml, "utf8");
      expect(codex.split("[mcp_servers.taskless]").length - 1, variant.name).toBe(1);
      expect(codex.split('[plugins."taskless@taskless-app".mcp_servers.taskless]').length - 1, variant.name).toBe(1);
      expect(codex, variant.name).toContain("https://foreign.example/mcp");
      for (const kept of variant.keep ?? []) expect(codex, variant.name).toContain(kept);
      expect(codex, variant.name).not.toContain("https://old.example/mcp");
      const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
        input: codex,
        encoding: "utf8",
      });
      expect(parsed.status, `${variant.name}: ${parsed.stderr}`).toBe(0);
      const again = await runPs1(setup.home, args, setup.env);
      expect(again.code, `${variant.name}: ${again.stdout}${again.stderr}`).toBe(0);
      expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(codex);
      const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, `${variant.name}: ${gone.stdout}${gone.stderr}`).toBe(0);
      expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
      removeRealHome(setup);
    }
  }, 180_000);

  it.skipIf(!hasPwsh)("pwsh: Codex TOML строки и многострочные значения не ломают установку", async () => {
    const stub = await startStub();
    for (const variant of CODEX_SCANNER_VARIANTS) {
      const setup = realHome(stub.url);
      writeFileSync(setup.codexToml, variant.text);
      const args = ["--only", "codex"];
      const first = await runPs1(setup.home, args, setup.env);
      if (variant.outcome === "reject") {
        expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(1);
        expect(first.stdout + first.stderr, variant.name).toContain("Файл не меняю");
        expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
        removeRealHome(setup);
        continue;
      }
      expect(first.code, `${variant.name}: ${first.stdout}${first.stderr}`).toBe(0);
      const codex = readFileSync(setup.codexToml, "utf8");
      expect(codex, variant.name).toContain("https://foreign.example/mcp");
      if (variant.outcome === "keep") expect(codex, variant.name).toContain("https://old.example/mcp");
      else expect(codex, variant.name).not.toContain("https://old.example/mcp");
      const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
        input: codex,
        encoding: "utf8",
      });
      expect(parsed.status, `${variant.name}: ${parsed.stderr}`).toBe(0);
      const again = await runPs1(setup.home, args, setup.env);
      expect(again.code, `${variant.name}: ${again.stdout}${again.stderr}`).toBe(0);
      expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(codex);
      const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, `${variant.name}: ${gone.stdout}${gone.stderr}`).toBe(0);
      expect(readFileSync(setup.codexToml, "utf8"), variant.name).toBe(variant.text);
      removeRealHome(setup);
    }
  }, 180_000);

  it.skipIf(!hasPwsh)("pwsh: uninstall Codex сохраняет внешнюю правку выше старой таблицы", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const original = `model = "gpt-5"
[mcp_servers.taskless]
url = "https://old.example/mcp"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`;
    writeFileSync(setup.codexToml, original);
    const args = ["--only", "codex"];
    const installed = await runPs1(setup.home, args, setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    const edited = readFileSync(setup.codexToml, "utf8").replace('model = "gpt-5"', 'model = "gpt-5.1-codex-max"');
    writeFileSync(setup.codexToml, edited);

    const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    const expected = original.replace('model = "gpt-5"', 'model = "gpt-5.1-codex-max"');
    const restored = readFileSync(setup.codexToml, "utf8");
    expect(restored).toBe(expected);
    const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
      input: restored,
      encoding: "utf8",
    });
    expect(parsed.status, parsed.stderr).toBe(0);
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: uninstall Codex сохраняет новую строку выше старой таблицы", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const original = `model = "gpt-5"
[mcp_servers.taskless]
url = "https://old.example/mcp"
[mcp_servers.foreign]
url = "https://foreign.example/mcp"
`;
    writeFileSync(setup.codexToml, original);
    const args = ["--only", "codex"];
    const installed = await runPs1(setup.home, args, setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    const replacement = 'model = "gpt-5"\nmodel_reasoning_effort = "xhigh"';
    writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8").replace('model = "gpt-5"', replacement));

    const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    const restored = readFileSync(setup.codexToml, "utf8");
    expect(restored).toBe(original.replace('model = "gpt-5"', replacement));
    const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
      input: restored,
      encoding: "utf8",
    });
    expect(parsed.status, parsed.stderr).toBe(0);
    removeRealHome(setup);
  }, 90_000);
  it.skipIf(!hasPwsh)("pwsh: uninstall Codex сохраняет внешний хвост без перевода строки", async () => {
    const stub = await startStub();
    const oldTaskless = `[mcp_servers.taskless]
url = "https://old.example/mcp"
`;
    const original = `${CODEX_FOREIGN}${oldTaskless}`;
    for (const eol of ["\n", "\r\n"]) {
      const setup = realHome(stub.url);
      writeFileSync(setup.codexToml, original.replaceAll("\n", eol));
      const args = ["--only", "codex"];
      const installed = await runPs1(setup.home, args, setup.env);
      expect(installed.code, installed.stdout + installed.stderr).toBe(0);
      const addition = `\n[tui]\nnotifications = true`;
      writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8") + addition.replaceAll("\n", eol));

      const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
      expect(gone.code, gone.stdout + gone.stderr).toBe(0);
      const expected = `${CODEX_FOREIGN}${addition}\n${oldTaskless}`.replaceAll("\n", eol);
      const restored = readFileSync(setup.codexToml, "utf8");
      expect(restored).toBe(expected);
      const parsed = spawnSync("python3", ["-c", "import sys,tomllib; tomllib.loads(sys.stdin.read())"], {
        input: restored,
        encoding: "utf8",
      });
      expect(parsed.status, parsed.stderr).toBe(0);
      removeRealHome(setup);
    }
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: uninstall Codex печатает потерянный якорь массива", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    const original = CODEX_EXISTING_VARIANTS.find((variant) => variant.name === "массив таблиц после taskless")!.text;
    writeFileSync(setup.codexToml, original);
    const args = ["--only", "codex"];
    const installed = await runPs1(setup.home, args, setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    writeFileSync(setup.codexToml, readFileSync(setup.codexToml, "utf8").replace("[[skills.config]]\n", ""));

    const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(gone.stderr).toContain("заголовок [[skills.config]] не найден");
    expect(gone.stderr).not.toContain("заголовок []skills.config не найден");
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: Codex без исходного config.toml, dry-run и uninstall", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url, "node", true);
    rmSync(setup.codexToml);
    const args = ["--only", "codex"];
    const installed = await runPs1(setup.home, args, setup.env);
    expect(installed.code, installed.stdout + installed.stderr).toBe(0);
    const before = readFileSync(setup.codexToml);
    const dry = await runPs1(setup.home, ["--uninstall", ...args, "--dry-run"], setup.env);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(readFileSync(setup.codexToml)).toEqual(before);
    expect(stub.hits.filter((hit) => hit.url === "/oauth/revoke")).toHaveLength(0);
    const gone = await runPs1(setup.home, ["--uninstall", ...args], setup.env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(existsSync(setup.codexToml)).toBe(false);
    expect(stub.hits.filter((hit) => hit.url === "/oauth/revoke")).toHaveLength(1);
    removeRealHome(setup);
  }, 90_000);
});

describe("connect.sh", () => {
  // Пять запусков скрипта. Лимит vitest по умолчанию — 5 с, на загруженном
  // раннере это впритык даже когда каждый вход занимает ~1 с.
  it("песочница: dry-run не меняет файлы, повтор без дублей, uninstall возвращает файлы, ключ 600", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-"));
    const conf = plant(home);
    const codex = path.join(home, ".taskless-stub", "codex.conf");
    const key = path.join(home, ".config", "taskless", "device-key");
    const baseEnv = {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code,codex",
    };

    const beforeFiles = filesUnder(home);
    const beforeHash = treeHash(home);
    const dry = await run(home, ["--dry-run"], baseEnv);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(dry.stdout).toContain("Только показ: ничего не меняю.");
    expect(dry.stdout).toContain("Нашёл: Claude Code, Codex");
    expect(dry.stdout).not.toContain("Код подключения");
    expect(filesUnder(home)).toEqual(beforeFiles);
    expect(treeHash(home)).toBe(beforeHash);
    expect(existsSync(codex)).toBe(false);
    expect(stub.hits).toHaveLength(0);

    const first = await run(home, [], baseEnv);
    expect(first.code, first.stdout + first.stderr).toBe(0);
    expect(first.stdout).toContain("Taskless: подключение агентов");
    expect(first.stdout).toContain("Нашёл: Claude Code, Codex");
    expect(first.stdout).toContain(CODE_LINE);
    expect(first.stdout).toContain(BROWSER_LINE);
    expect(first.stdout).toContain(BROWSER_HINT);
    expect(first.stdout).toContain(WAIT_LINE);
    expect(first.stdout).toContain(FILE_KEY_LINE);
    expect(first.stdout).toContain("  копия конфига: ~/.taskless-stub/claude-code.conf.bak-taskless");
    expect(first.stdout).toContain("Подключены: Claude Code, Codex");
    expect(first.stdout).toContain("Сделай руками:");
    expect(first.stdout).toContain("  1. в Codex одобри хуки командой /hooks");
    expect(first.stdout).toContain("  2. перезапусти Claude Code");
    // Макет пишет «Не найдены: Grok, ZCode» — на рисунке только эти четверо.
    // Реестр задачи — десять id, отчёт называет каждого, кого не нашёл.
    expect(first.stdout).toContain(
      "Не найдены: Grok, ZCode, Cursor, Gemini CLI, OpenCode, Copilot CLI, Qwen Code, Kimi CLI",
    );
    const written = readFileSync(conf, "utf8");
    expect(written.startsWith(ORIGINAL)).toBe(true);
    expect(written).toContain("чужой сервер mcp");
    expect(countMarker(written, "claude-code")).toBe(1);
    expect(countMarker(readFileSync(codex, "utf8"), "codex")).toBe(1);
    expect(statSync(key).mode & 0o777).toBe(0o600);
    expect(readFileSync(key, "utf8").trim()).toBe(TOKEN);
    const posted = stub.hits.filter((h) => h.url === "/oauth/device_authorization");
    expect(posted).toHaveLength(1);
    const req = JSON.parse(posted[0]!.body) as { client_id: string; agents: string[]; device_name: string; platform: string };
    expect(req.client_id).toBe("taskless-device");
    expect(req.device_name).toBe(DEVICE);
    expect(req.platform).toBe(PLATFORM);
    expect(req.agents).toEqual(["claude-code", "codex"]);

    const again = await run(home, [], baseEnv);
    expect(again.code, again.stdout + again.stderr).toBe(0);
    expect(again.stdout).toContain("Ключ уже есть, вход не прошу.");
    expect(again.stdout).not.toContain("Код подключения");
    expect(countMarker(readFileSync(conf, "utf8"), "claude-code")).toBe(1);
    expect(countMarker(readFileSync(codex, "utf8"), "codex")).toBe(1);
    expect(stub.hits.filter((h) => h.url === "/oauth/device_authorization")).toHaveLength(1);
    expect(stub.hits.some((h) => h.url === "/auth/me" && h.auth === `Bearer ${TOKEN}`)).toBe(true);

    const status = await run(home, ["--status"], baseEnv);
    expect(status.code, status.stdout + status.stderr).toBe(0);
    expect(status.stdout).toContain(`Устройство: ${DEVICE}`);
    expect(status.stdout).toContain("Ключ: в файле ~/.config/taskless/device-key");

    const gone = await run(home, ["--uninstall"], baseEnv);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(existsSync(conf + ".bak-taskless")).toBe(false);
    expect(existsSync(codex)).toBe(false);
    expect(existsSync(codex + ".bak-taskless")).toBe(false);
    expect(existsSync(key)).toBe(false);
    const revoked = stub.hits.filter((h) => h.url === "/oauth/revoke");
    expect(revoked).toHaveLength(1);
    expect(JSON.parse(revoked[0]!.body)).toMatchObject({ token: TOKEN, client_id: "taskless-device" });
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it("агентов нет — код не просит, браузер не открывает, выход 0", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-none-"));
    const clientFreePath = [FAKE_BIN, ...(process.env.PATH ?? "").split(path.delimiter).filter((dir) =>
      !existsSync(path.join(dir, "claude")) && !existsSync(path.join(dir, "codex")),
    )].join(path.delimiter);
    const res = await run(home, [], {
      PATH: clientFreePath,
      TASKLESS_URL: stub.url,
      TASKLESS_BROWSER: "true",
    });
    expect(res.code, res.stdout + res.stderr).toBe(0);
    expect(res.stdout).toContain("агентов не нашёл");
    expect(res.stdout).toContain(SEARCHED);
    expect(res.stdout).not.toContain("Код подключения");
    expect(res.stdout).not.toContain("Открываю браузер");
    expect(stub.hits).toHaveLength(0);
    expect(filesUnder(home)).toEqual([]);
    rmSync(home, { recursive: true, force: true });
  });

  it("--only подключает только названных и шлёт на сервер только их id", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-only-"));
    const conf = plant(home);
    const res = await run(home, ["--only", "codex"], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code,codex",
      TASKLESS_RUNTIME: "node",
    });
    expect(res.code, res.stdout + res.stderr).toBe(0);
    expect(res.stdout).toContain("Нашёл: Codex");
    expect(res.stdout).not.toContain("Нашёл: Claude Code");
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(existsSync(conf + ".bak-taskless")).toBe(false);
    const codex = path.join(home, ".taskless-stub", "codex.conf");
    expect(countMarker(readFileSync(codex, "utf8"), "codex")).toBe(1);
    const posted = stub.hits.find((h) => h.url === "/oauth/device_authorization");
    expect(JSON.parse(posted!.body).agents).toEqual(["codex"]);
    expect(statSync(path.join(home, ".config", "taskless", "device-key")).mode & 0o777).toBe(0o600);
    rmSync(home, { recursive: true, force: true });
  });

  it("отказ человека не сохраняет ключ", async () => {
    const stub = await startStub();
    stub.token = () => ({ status: 400, body: { error: "access_denied" } });
    const home = mkdtempSync(path.join(tmpdir(), "connect-deny-"));
    plant(home);
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    expect(res.code).not.toBe(0);
    expect(res.stdout).toContain("Вход отклонён. Ключ не сохранён.");
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
    const conf = path.join(home, ".taskless-stub", "claude-code.conf");
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it.skipIf(!IS_LINUX)("secret-tool есть — ключ в связке и файле 600; второй запуск вход не просит [только Linux]", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-secret-"));
    const bin = path.join(home, "bin");
    mkdirSync(bin);
    const store = path.join(home, "keyring");
    const log = path.join(home, "secret.log");
    writeFileSync(
      path.join(bin, "secret-tool"),
      `#!/bin/sh
case "$1" in
  store) cat > "${store}"; echo store >> "${log}" ;;
  lookup) echo lookup >> "${log}"; cat "${store}" ;;
  clear) echo clear >> "${log}"; rm -f "${store}" ;;
  *) echo "bad \$*" >> "${log}"; exit 1 ;;
esac
`,
    );
    chmodSync(path.join(bin, "secret-tool"), 0o755);
    const env = {
      PATH: `${bin}:${TEST_PATH}`,
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    };
    const first = await run(home, [], env);
    expect(first.code, first.stdout + first.stderr).toBe(0);
    expect(first.stdout).toContain("Вход подтверждён, ключ сохранён в связке ключей.");
    const keyFile = path.join(home, ".config", "taskless", "device-key");
    expect(readFileSync(keyFile, "utf8")).toBe(`${TOKEN}\n`);
    expect(statSync(keyFile).mode & 0o777).toBe(0o600);
    expect(readFileSync(store, "utf8")).toBe(TOKEN);
    const again = await run(home, [], env);
    expect(again.code, again.stdout + again.stderr).toBe(0);
    expect(again.stdout).toContain("Ключ уже есть, вход не прошу.");
    expect(stub.hits.filter((h) => h.url === "/oauth/device_authorization")).toHaveLength(1);
    expect(readFileSync(log, "utf8")).toContain("lookup");
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  // На машине человека auto берёт python3. Повтор должен заменить блок,
  // а не дописать второй в конец (мутация ветки python это краснит).
  it("песочница на python3: установка, повтор заменяет блок, uninstall", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-py-"));
    const conf = plant(home);
    const env = {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
      TASKLESS_RUNTIME: "python3",
    };
    const first = await run(home, [], env);
    expect(first.code, first.stdout + first.stderr).toBe(0);
    expect(first.stdout).toContain(FILE_KEY_LINE);
    const written = readFileSync(conf, "utf8");
    expect(written.startsWith(ORIGINAL)).toBe(true);
    expect(countMarker(written, "claude-code")).toBe(1);

    const again = await run(home, [], env);
    expect(again.code, again.stdout + again.stderr).toBe(0);
    expect(again.stdout).toContain("Ключ уже есть, вход не прошу.");
    expect(readFileSync(conf, "utf8")).toBe(written);
    expect(countMarker(readFileSync(conf, "utf8"), "claude-code")).toBe(1);

    const gone = await run(home, ["--uninstall"], env);
    expect(gone.code, gone.stdout + gone.stderr).toBe(0);
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(existsSync(conf + ".bak-taskless")).toBe(false);
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it("slow_down: три опроса, пауза растёт на 5 с, потом ключ", async () => {
    const stub = await startStub();
    stub.token = (call) => {
      if (call <= 2) return { status: 400, body: { error: "slow_down" } };
      return { status: 200, body: { access_token: TOKEN, token_type: "Bearer" } };
    };
    const home = mkdtempSync(path.join(tmpdir(), "connect-slow-"));
    const conf = plant(home);
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    expect(res.code, res.stdout + res.stderr).toBe(0);
    expect(res.stdout).toContain(FILE_KEY_LINE);
    const urls = stub.hits.map((h) => h.url);
    expect(urls[0]).toBe("/oauth/device_authorization");
    const polls = stub.hits.filter((h) => h.url === "/oauth/token");
    expect(polls).toHaveLength(3);
    expect(urls.slice(1, 4)).toEqual(["/oauth/token", "/oauth/token", "/oauth/token"]);
    const gap1 = polls[1]!.at - polls[0]!.at;
    const gap2 = polls[2]!.at - polls[1]!.at;
    // interval в заглушке 0: после slow_down паузы 5 с и 10 с.
    // Пороги абсолютные: холодный старт помощника раздувает первый зазор,
    // и «второй на 5 с длиннее первого» мигает. Без +5 оба зазора около нуля.
    expect(gap1).toBeGreaterThanOrEqual(4_500);
    expect(gap2).toBeGreaterThanOrEqual(9_000);
    expect(gap2).toBeGreaterThan(gap1);
    expect(countMarker(readFileSync(conf, "utf8"), "claude-code")).toBe(1);
    rmSync(home, { recursive: true, force: true });
  }, 45_000);

  it("expired_token не сохраняет ключ и не пишет блок", async () => {
    const stub = await startStub();
    stub.token = () => ({ status: 400, body: { error: "expired_token" } });
    const home = mkdtempSync(path.join(tmpdir(), "connect-expired-"));
    const conf = plant(home);
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).not.toBe(0);
    expect(out).toContain("Код устарел. Запусти установщик ещё раз.");
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it("access_denied не сохраняет ключ", async () => {
    const stub = await startStub();
    stub.token = () => ({ status: 400, body: { error: "access_denied" } });
    const home = mkdtempSync(path.join(tmpdir(), "connect-denied-"));
    const conf = plant(home);
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).not.toBe(0);
    expect(out).toContain("Вход отклонён. Ключ не сохранён.");
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(stub.hits.filter((h) => h.url === "/oauth/token")).toHaveLength(1);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it("429 ждёт Retry-After и следующим опросом берёт ключ", async () => {
    const stub = await startStub();
    stub.token = (call) => {
      if (call === 1) return { status: 429, body: {}, retryAfter: "1" };
      return { status: 200, body: { access_token: TOKEN, token_type: "Bearer" } };
    };
    const home = mkdtempSync(path.join(tmpdir(), "connect-429-"));
    plant(home);
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    expect(res.code, res.stdout + res.stderr).toBe(0);
    expect(res.stdout).toContain(FILE_KEY_LINE);
    const polls = stub.hits.filter((h) => h.url === "/oauth/token");
    expect(polls).toHaveLength(2);
    expect(polls[1]!.at - polls[0]!.at).toBeGreaterThanOrEqual(800);
    const urls = stub.hits.map((h) => h.url);
    expect(urls[0]).toBe("/oauth/device_authorization");
    expect(urls[1]).toBe("/oauth/token");
    expect(urls[2]).toBe("/oauth/token");
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it("конфиг-симлинк остаётся симлинком на тот же файл", async () => {
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-link-"));
      const real = path.join(home, "real", "claude-code.conf");
      mkdirSync(path.dirname(real), { recursive: true });
      writeFileSync(real, ORIGINAL);
      const link = path.join(home, ".taskless-stub", "claude-code.conf");
      mkdirSync(path.dirname(link), { recursive: true });
      symlinkSync(real, link);
      const env = {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      };
      const first = await run(home, [], env);
      expect(first.code, `${runtime}\n${first.stdout}${first.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), runtime).toBe(true);
      expect(readlinkSync(link), runtime).toBe(real);
      expect(readFileSync(real, "utf8"), runtime).toContain("# >>> taskless:claude-code");
      const gone = await run(home, ["--uninstall"], env);
      expect(gone.code, `${runtime}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), runtime).toBe(true);
      expect(readlinkSync(link), runtime).toBe(real);
      expect(readFileSync(real, "utf8"), runtime).toBe(ORIGINAL);
      rmSync(home, { recursive: true, force: true });
    }
  }, 120_000);

  // Битая ссылка (stow до создания цели): установка создаёт цель через ссылку,
  // uninstall убирает цель, которой не было, ссылка остаётся ссылкой.
  it("битая конфиг-ссылка: ссылка остаётся, uninstall возвращает цель как было", async () => {
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-dangle-"));
      const real = path.join(home, "real", "claude-code.conf");
      mkdirSync(path.dirname(real), { recursive: true });
      const link = path.join(home, ".taskless-stub", "claude-code.conf");
      mkdirSync(path.dirname(link), { recursive: true });
      const target = path.join("..", "real", "claude-code.conf");
      symlinkSync(target, link);
      const env = {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      };
      const first = await run(home, [], env);
      expect(first.code, `${runtime}\n${first.stdout}${first.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), runtime).toBe(true);
      expect(readlinkSync(link), runtime).toBe(target);
      expect(readFileSync(real, "utf8"), runtime).toContain("# >>> taskless:claude-code");
      const gone = await run(home, ["--uninstall"], env);
      expect(gone.code, `${runtime}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), runtime).toBe(true);
      expect(readlinkSync(link), runtime).toBe(target);
      expect(existsSync(real), runtime).toBe(false);
      rmSync(home, { recursive: true, force: true });
    }
  }, 120_000);

  it("метка начала без метки конца не меняет файл", async () => {
    const broken = `${ORIGINAL}# >>> taskless:claude-code\nold=1\nuser1=keep\nuser2=keep\n`;
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-open-"));
      const conf = plant(home);
      writeFileSync(conf, broken);
      const res = await run(home, [], {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      });
      const out = res.stdout + res.stderr;
      expect(res.code, `${runtime}\n${out}`).not.toBe(0);
      expect(out, runtime).toContain(conf);
      expect(out, runtime).toContain("метки конца");
      expect(readFileSync(conf, "utf8"), runtime).toBe(broken);
      expect(existsSync(conf + ".bak-taskless"), runtime).toBe(false);
      rmSync(home, { recursive: true, force: true });
    }
  }, 90_000);

  it("метка конца последней строкой без \\n: установка заменяет блок, uninstall его снимает", async () => {
    const finalMarker = `${ORIGINAL}# >>> taskless:claude-code\nold=1\n# <<< taskless:claude-code`;
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-eof-mark-"));
      const conf = plant(home);
      writeFileSync(conf, finalMarker);
      const env = {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      };
      const removed = await run(home, ["--uninstall"], env);
      expect(removed.code, `${runtime}\n${removed.stdout}${removed.stderr}`).toBe(0);
      expect(readFileSync(conf), runtime).toEqual(Buffer.from(ORIGINAL));
      writeFileSync(conf, finalMarker);
      const first = await run(home, [], env);
      expect(first.code, `${runtime}\n${first.stdout}${first.stderr}`).toBe(0);
      const installed = readFileSync(conf, "utf8");
      expect(countMarker(installed, "claude-code"), `${runtime}\n${installed}`).toBe(1);
      expect(installed, runtime).not.toContain("old=1");
      const gone = await run(home, ["--uninstall"], env);
      expect(gone.code, `${runtime}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(readFileSync(conf), runtime).toEqual(Buffer.from(ORIGINAL));
      rmSync(home, { recursive: true, force: true });
    }
  }, 120_000);

  // Файл пересохранили с CRLF: метки с \r\n — тот же блок, не чужой текст.
  it("CRLF-метки: установка заменяет блок, uninstall его снимает", async () => {
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-crlf-"));
      const conf = plant(home);
      writeFileSync(conf, CRLF_CONF);
      const env = {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      };
      const first = await run(home, [], env);
      expect(first.code, `${runtime}\n${first.stdout}${first.stderr}`).toBe(0);
      const installed = readFileSync(conf, "utf8");
      expect(countMarker(installed, "claude-code"), `${runtime}\n${installed}`).toBe(1);
      expect(installed, runtime).not.toContain("old=1");
      expect(installed, runtime).toContain("user1=keep\r\n");
      const gone = await run(home, ["--uninstall"], env);
      expect(gone.code, `${runtime}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(readFileSync(conf, "utf8"), runtime).toBe(`${ORIGINAL}user1=keep\r\n`);
      rmSync(home, { recursive: true, force: true });
    }
  }, 120_000);

  it("пустой файл после uninstall остаётся пустым", async () => {
    for (const runtime of ["node", "python3"]) {
      const stub = await startStub();
      const home = mkdtempSync(path.join(tmpdir(), "connect-empty-"));
      const conf = plant(home);
      writeFileSync(conf, "");
      const env = {
        TASKLESS_URL: stub.url,
        TASKLESS_DEVICE_NAME: DEVICE,
        TASKLESS_BROWSER: "true",
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
        TASKLESS_RUNTIME: runtime,
      };
      const first = await run(home, [], env);
      expect(first.code, `${runtime}\n${first.stdout}${first.stderr}`).toBe(0);
      expect(existsSync(conf), runtime).toBe(true);
      const gone = await run(home, ["--uninstall"], env);
      expect(gone.code, `${runtime}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(existsSync(conf), runtime).toBe(true);
      expect(readFileSync(conf, "utf8"), runtime).toBe("");
      expect(statSync(conf).size, runtime).toBe(0);
      rmSync(home, { recursive: true, force: true });
    }
  }, 90_000);

  it("ключ для security уходит в stdin, не в argv", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-sec-"));
    const bin = path.join(home, "bin");
    mkdirSync(bin);
    const argvLog = path.join(home, "argv.log");
    const stdinLog = path.join(home, "stdin.log");
    writeFileSync(
      path.join(bin, "uname"),
      `#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -r) echo 24.0.0 ;;
  *) echo Darwin ;;
esac
`,
    );
    writeFileSync(
      path.join(bin, "security"),
      `#!/bin/sh
printf 'argv:%s\\n' "$*" >> "${argvLog}"
if [ "$1" = "-i" ]; then
  cat >> "${stdinLog}"
  exit 0
fi
exit 1
`,
    );
    chmodSync(path.join(bin, "uname"), 0o755);
    chmodSync(path.join(bin, "security"), 0o755);
    const res = await run(home, [], {
      PATH: `${bin}:${TEST_PATH}`,
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(out).toContain("Вход подтверждён, ключ сохранён в Keychain.");
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
    const argv = readFileSync(argvLog, "utf8");
    const stdin = readFileSync(stdinLog, "utf8");
    expect(argv).not.toContain(TOKEN);
    expect(argv).toContain("argv:-i");
    expect(stdin).toContain("add-generic-password");
    expect(stdin).toContain(TOKEN);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  // Без заглушки настоящий security на Маке виснет, тест падает по таймауту.
  it.skipIf(!IS_MAC)("на Маке тесты зовут заглушку security, ключ уходит в файл [только macOS]", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-mac-"));
    plant(home);
    rmSync(SECURITY_LOG, { force: true });
    const res = await run(home, [], {
      TASKLESS_URL: stub.url,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    expect(res.code, res.stdout + res.stderr).toBe(0);
    expect(res.stdout).toContain(FILE_KEY_LINE);
    const calls = readFileSync(SECURITY_LOG, "utf8");
    expect(calls).toContain("find-generic-password");
    expect(calls).toContain("-i");
    rmSync(home, { recursive: true, force: true });
  }, 15_000);

  it("http:// разрешён только для localhost и 127.0.0.1", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-url-"));
    const conf = plant(home);
    const env = {
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    };
    const bad = await run(home, [], { ...env, TASKLESS_URL: "http://not-local.test/api" });
    const badOut = bad.stdout + bad.stderr;
    expect(bad.code, badOut).not.toBe(0);
    expect(badOut).toContain("localhost");
    expect(badOut).toContain("127.0.0.1");
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(stub.hits).toHaveLength(0);

    const spoof = await run(home, [], { ...env, TASKLESS_URL: "http://127.0.0.1.evil.test/api" });
    const spoofOut = spoof.stdout + spoof.stderr;
    expect(spoof.code, spoofOut).not.toBe(0);
    expect(spoofOut).toContain("разрешён только");

    const local = await run(home, [], { ...env, TASKLESS_URL: "http://localhost:1/api" });
    const localOut = local.stdout + local.stderr;
    expect(local.code, localOut).not.toBe(0);
    expect(localOut).not.toContain("разрешён только");

    const ok = await run(home, [], { ...env, TASKLESS_URL: stub.url });
    expect(ok.code, ok.stdout + ok.stderr).toBe(0);
    expect(stub.hits.some((h) => h.url === "/oauth/device_authorization")).toBe(true);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  // --dry-run в сеть не ходит: адрес проверяется до всего остального.
  it("http://: userinfo, # и %40 не уводят за петлю, петля проходит", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "connect-host-"));
    const conf = plant(home);
    const env = {
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    };
    for (const url of BAD_HTTP) {
      const res = await run(home, ["--dry-run"], { ...env, TASKLESS_URL: url });
      const out = res.stdout + res.stderr;
      expect(res.code, `${url}\n${out}`).not.toBe(0);
      expect(out, url).toContain("разрешён только");
    }
    for (const url of BAD_ANY) {
      const res = await run(home, ["--dry-run"], { ...env, TASKLESS_URL: url });
      expect(res.code, JSON.stringify(url)).not.toBe(0);
    }
    for (const url of GOOD_HTTP) {
      const res = await run(home, ["--dry-run"], { ...env, TASKLESS_URL: url });
      const out = res.stdout + res.stderr;
      expect(res.code, `${url}\n${out}`).toBe(0);
      expect(out, url).toContain("Только показ: ничего не меняю.");
    }
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    rmSync(home, { recursive: true, force: true });
  }, 60_000);
});

describe("connect.ps1", () => {
  function psEnv(stubUrl: string): Record<string, string> {
    return {
      TASKLESS_URL: stubUrl,
      TASKLESS_DEVICE_NAME: DEVICE,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
      TASKLESS_KEY_STORE: "file",
    };
  }

  // Локально pwsh может не быть: шаг CI ставит его и гоняет эти сценарии.
  // Без метки :poll оба красные — continue внутри switch не возвращает цикл.
  it.skipIf(!hasPwsh)("pwsh: 2 × authorization_pending, потом ключ", async () => {
    const stub = await startStub();
    stub.token = (call) => {
      if (call <= 2) return { status: 400, body: { error: "authorization_pending" } };
      return { status: 200, body: { access_token: TOKEN, token_type: "Bearer" } };
    };
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-pending-"));
    plant(home);
    const res = await runPs1(home, [], psEnv(stub.url));
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(out).toContain("Вход подтверждён");
    const polls = stub.hits.filter((h) => h.url === "/oauth/token");
    expect(polls.map((h) => h.method)).toEqual(["POST", "POST", "POST"]);
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it.skipIf(!hasPwsh)("pwsh: 2 × slow_down, интервал +5 с, потом ключ", async () => {
    const stub = await startStub();
    stub.token = (call) => {
      if (call <= 2) return { status: 400, body: { error: "slow_down" } };
      return { status: 200, body: { access_token: TOKEN, token_type: "Bearer" } };
    };
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-slow-"));
    plant(home);
    const res = await runPs1(home, [], psEnv(stub.url));
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(out).toContain("Вход подтверждён");
    const polls = stub.hits.filter((h) => h.url === "/oauth/token");
    expect(polls).toHaveLength(3);
    const gap1 = polls[1]!.at - polls[0]!.at;
    const gap2 = polls[2]!.at - polls[1]!.at;
    // Старт interval=0: после первого slow_down пауза 5 с, после второго — 10 с.
    expect(gap1).toBeGreaterThanOrEqual(4_000);
    expect(gap2).toBeGreaterThanOrEqual(gap1 + 4_000);
    rmSync(home, { recursive: true, force: true });
  }, 45_000);

  // Как в консоли: -Command, а не -File — у probe.ps1 своя область script:, и
  // утечка в глобальную область под -File не видна. Ключ заглушка реально выдаёт.
  it.skipIf(!hasPwsh)("pwsh: iex не оставляет переменных, функций и ErrorActionPreference", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-iex-"));
    plant(home);
    // Ключ в тексте пробы не пишем: он попал бы в $MyInvocation. Берём из файла.
    const probe = [
      "$ErrorActionPreference = 'Continue'",
      "$tlBeforeVars = @(Get-Variable -Scope Global | ForEach-Object { $_.Name })",
      "$tlBeforeFuncs = @(Get-ChildItem function: | ForEach-Object { $_.Name })",
      `Invoke-Expression (Get-Content -Raw -LiteralPath '${ps1.replace(/'/g, "''")}')`,
      "$tlKey = [IO.File]::ReadAllText((Join-Path $HOME '.config/taskless/device-key')).Trim()",
      "if (-not $tlKey) { Write-Output 'NO-KEY' }",
      "$tlSkip = @('tlBeforeVars', 'tlBeforeFuncs', 'tlKey', 'tlSkip')",
      "foreach ($v in @(Get-Variable -Scope Global)) {",
      "  if ($tlSkip -contains $v.Name) { continue }",
      "  if ($tlBeforeVars -notcontains $v.Name) { Write-Output ('LEAK-VAR ' + $v.Name) }",
      "  if ($tlKey -and (($v.Value | Out-String -Width 4096) -as [string]).Contains($tlKey)) { Write-Output ('LEAK-TOKEN ' + $v.Name) }",
      "}",
      "if (Get-Variable Token -Scope Global -ErrorAction SilentlyContinue) { Write-Output 'LEAK-TOKEN-GLOBAL' }",
      "foreach ($f in @(Get-ChildItem function:)) {",
      "  if ($tlBeforeFuncs -notcontains $f.Name) { Write-Output ('LEAK-FUNC ' + $f.Name) }",
      "}",
      "if ($ErrorActionPreference -ne 'Continue') { Write-Output ('LEAK-PREF ' + $ErrorActionPreference) }",
      "Write-Output 'PROBE-DONE'",
    ].join("\n");
    const res = await new Promise<{ code: number; stdout: string; stderr: string }>((resolve, reject) => {
      const child = spawn("pwsh", ["-NoProfile", "-NonInteractive", "-Command", probe], {
        env: {
          PATH: process.env.PATH,
          HOME: home,
          USERPROFILE: home,
          TMPDIR: process.env.TMPDIR || "/tmp",
          LANG: "C.UTF-8",
          LC_ALL: "C.UTF-8",
          ...psEnv(stub.url),
        },
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 40_000,
      });
      let stdout = "";
      let stderr = "";
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.on("error", reject);
      child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(out).toContain("Вход подтверждён");
    expect(stub.hits.some((h) => h.url === "/oauth/token")).toBe(true);
    expect(readFileSync(path.join(home, ".config", "taskless", "device-key"), "utf8").trim()).toBe(TOKEN);
    expect(out).toContain("PROBE-DONE");
    expect(out).not.toContain("NO-KEY");
    expect(out.split("\n").filter((l) => l.startsWith("LEAK"))).toEqual([]);
    rmSync(home, { recursive: true, force: true });
  }, 60_000);

  // Как в connect.sh: метка начала без метки конца — отказ с путём, хвост цел.
  it.skipIf(!hasPwsh)("pwsh: метка начала без метки конца не меняет файл", async () => {
    const broken = `${ORIGINAL}# >>> taskless:claude-code\nold=1\nuser1=keep\nuser2=keep\n`;
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-open-"));
    const conf = plant(home);
    writeFileSync(conf, broken);
    for (const args of [[], ["--uninstall"]]) {
      const res = await runPs1(home, args, psEnv(stub.url));
      const out = res.stdout + res.stderr;
      const label = args.join(" ") || "установка";
      expect(res.code, `${label}\n${out}`).not.toBe(0);
      expect(out, label).toContain(conf);
      expect(out, label).toContain("метки конца");
      expect(readFileSync(conf, "utf8"), label).toBe(broken);
      expect(existsSync(conf + ".bak-taskless"), label).toBe(false);
    }
    rmSync(home, { recursive: true, force: true });
  }, 60_000);

  // Как в connect.sh: конфиг-симлинк (stow) остаётся ссылкой, блок — в цели.
  it.skipIf(!hasPwsh)("pwsh: конфиг-симлинк остаётся симлинком на тот же файл", async () => {
    const stub = await startStub();
    for (const kind of ["абсолютная", "относительная"]) {
      const home = mkdtempSync(path.join(tmpdir(), "connect-ps-link-"));
      const real = path.join(home, "real", "claude-code.conf");
      mkdirSync(path.dirname(real), { recursive: true });
      writeFileSync(real, ORIGINAL);
      const link = path.join(home, ".taskless-stub", "claude-code.conf");
      mkdirSync(path.dirname(link), { recursive: true });
      const target = kind === "абсолютная" ? real : path.join("..", "real", "claude-code.conf");
      symlinkSync(target, link);
      const first = await runPs1(home, [], psEnv(stub.url));
      expect(first.code, `${kind}\n${first.stdout}${first.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), kind).toBe(true);
      expect(readlinkSync(link), kind).toBe(target);
      expect(readFileSync(real, "utf8"), kind).toContain("# >>> taskless:claude-code");
      const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
      expect(gone.code, `${kind}\n${gone.stdout}${gone.stderr}`).toBe(0);
      expect(lstatSync(link).isSymbolicLink(), kind).toBe(true);
      expect(readlinkSync(link), kind).toBe(target);
      expect(readFileSync(real, "utf8"), kind).toBe(ORIGINAL);
      rmSync(home, { recursive: true, force: true });
    }
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: битая конфиг-ссылка создаёт цель, uninstall без цели не падает", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-dangle-"));
    const real = path.join(home, "real", "claude-code.conf");
    mkdirSync(path.dirname(real), { recursive: true });
    const link = path.join(home, ".taskless-stub", "claude-code.conf");
    mkdirSync(path.dirname(link), { recursive: true });
    const target = path.join("..", "real", "claude-code.conf");
    symlinkSync(target, link);
    const empty = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(empty.code, `${empty.stdout}${empty.stderr}`).toBe(0);
    expect(lstatSync(link).isSymbolicLink()).toBe(true);
    expect(existsSync(real)).toBe(false);
    const first = await runPs1(home, [], psEnv(stub.url));
    expect(first.code, `${first.stdout}${first.stderr}`).toBe(0);
    expect(lstatSync(link).isSymbolicLink()).toBe(true);
    expect(readlinkSync(link)).toBe(target);
    expect(readFileSync(real, "utf8")).toContain("# >>> taskless:claude-code");
    const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(gone.code, `${gone.stdout}${gone.stderr}`).toBe(0);
    expect(lstatSync(link).isSymbolicLink()).toBe(true);
    expect(readlinkSync(link)).toBe(target);
    expect(existsSync(real)).toBe(false);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: установка и uninstall сохраняют права конфига", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-mode-"));
    const conf = plant(home);
    chmodSync(conf, 0o444);
    const first = await runPs1(home, [], psEnv(stub.url));
    expect(first.code, `${first.stdout}${first.stderr}`).toBe(0);
    expect(statSync(conf).mode & 0o777).toBe(0o444);
    const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(gone.code, `${gone.stdout}${gone.stderr}`).toBe(0);
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    expect(statSync(conf).mode & 0o777).toBe(0o444);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: повторная установка возвращает device.json режим 600", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-meta-mode-"));
    plant(home);
    const first = await runPs1(home, [], psEnv(stub.url));
    expect(first.code, `${first.stdout}${first.stderr}`).toBe(0);
    const meta = path.join(home, ".config", "taskless", "device.json");
    chmodSync(meta, 0o644);
    const again = await runPs1(home, [], psEnv(stub.url));
    expect(again.code, `${again.stdout}${again.stderr}`).toBe(0);
    expect(statSync(meta).mode & 0o777).toBe(0o600);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: копия обычного конфига сохраняет режим 600", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-backup-mode-"));
    const conf = plant(home);
    chmodSync(conf, 0o600);
    const installed = await runPs1(home, [], psEnv(stub.url));
    expect(installed.code, `${installed.stdout}${installed.stderr}`).toBe(0);
    expect(statSync(`${conf}.bak-taskless`).mode & 0o777).toBe(0o600);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: копия Claude JSON сохраняет режим 600", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    chmodSync(setup.claudeJson, 0o600);
    const installed = await runPs1(setup.home, ["--only", "claude-code"], setup.env);
    expect(installed.code, `${installed.stdout}${installed.stderr}`).toBe(0);
    expect(statSync(`${setup.claudeJson}.bak-taskless`).mode & 0o777).toBe(0o600);
    removeRealHome(setup);
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: копия обычного конфига сохраняет режим 640", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-backup-mode-"));
    const conf = plant(home);
    chmodSync(conf, 0o640);
    const installed = await runPs1(home, [], psEnv(stub.url));
    expect(installed.code, `${installed.stdout}${installed.stderr}`).toBe(0);
    expect(statSync(`${conf}.bak-taskless`).mode & 0o777).toBe(0o640);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: копия Claude JSON сохраняет режим 640", async () => {
    const stub = await startStub();
    const setup = realHome(stub.url);
    chmodSync(setup.claudeJson, 0o640);
    const installed = await runPs1(setup.home, ["--only", "claude-code"], setup.env);
    expect(installed.code, `${installed.stdout}${installed.stderr}`).toBe(0);
    expect(statSync(`${setup.claudeJson}.bak-taskless`).mode & 0o777).toBe(0o640);
    removeRealHome(setup);
  }, 90_000);

  // Как в connect.sh: файл был пустым — после --uninstall пустой и остаётся.
  // Файла не было — установка его создала, --uninstall удаляет.
  it.skipIf(!hasPwsh)("pwsh: пустой файл после uninstall остаётся пустым", async () => {
    const stub = await startStub();
    for (const kind of ["пустой", "не было"]) {
      const home = mkdtempSync(path.join(tmpdir(), "connect-ps-empty-"));
      const conf = plant(home);
      if (kind === "пустой") writeFileSync(conf, "");
      else rmSync(conf);
      const first = await runPs1(home, [], psEnv(stub.url));
      expect(first.code, `${kind}\n${first.stdout}${first.stderr}`).toBe(0);
      expect(readFileSync(conf, "utf8"), kind).toContain("# >>> taskless:claude-code");
      const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
      expect(gone.code, `${kind}\n${gone.stdout}${gone.stderr}`).toBe(0);
      if (kind === "пустой") {
        expect(existsSync(conf), kind).toBe(true);
        expect(statSync(conf).size, kind).toBe(0);
      } else {
        expect(existsSync(conf), kind).toBe(false);
      }
      expect(existsSync(conf + ".bak-taskless"), kind).toBe(false);
      rmSync(home, { recursive: true, force: true });
    }
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: CRLF-метки — установка заменяет блок, uninstall его снимает", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-crlf-"));
    const conf = plant(home);
    writeFileSync(conf, CRLF_CONF);
    const first = await runPs1(home, [], psEnv(stub.url));
    expect(first.code, `${first.stdout}${first.stderr}`).toBe(0);
    const installed = readFileSync(conf, "utf8");
    expect(countMarker(installed, "claude-code"), installed).toBe(1);
    expect(installed).not.toContain("old=1");
    expect(installed).toContain("user1=keep\r\n");
    const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(gone.code, `${gone.stdout}${gone.stderr}`).toBe(0);
    expect(readFileSync(conf, "utf8")).toBe(`${ORIGINAL}user1=keep\r\n`);
    rmSync(home, { recursive: true, force: true });
  }, 60_000);

  it.skipIf(!hasPwsh)("pwsh: метка конца последней строкой без \\n: установка заменяет блок, uninstall его снимает", async () => {
    const finalMarker = `${ORIGINAL}# >>> taskless:claude-code\nold=1\n# <<< taskless:claude-code`;
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-eof-mark-"));
    const conf = plant(home);
    writeFileSync(conf, finalMarker);
    const removed = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(removed.code, `${removed.stdout}${removed.stderr}`).toBe(0);
    expect(readFileSync(conf)).toEqual(Buffer.from(ORIGINAL));
    writeFileSync(conf, finalMarker);
    const first = await runPs1(home, [], psEnv(stub.url));
    expect(first.code, `${first.stdout}${first.stderr}`).toBe(0);
    const installed = readFileSync(conf, "utf8");
    expect(countMarker(installed, "claude-code"), installed).toBe(1);
    expect(installed).not.toContain("old=1");
    const gone = await runPs1(home, ["--uninstall"], psEnv(stub.url));
    expect(gone.code, `${gone.stdout}${gone.stderr}`).toBe(0);
    expect(readFileSync(conf)).toEqual(Buffer.from(ORIGINAL));
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  // Тот же набор адресов, что у connect.sh. Адрес проверяется до всего, как
  // require_base, поэтому --dry-run хватает и в сеть никто не ходит.
  it.skipIf(!hasPwsh)("pwsh: http:// — userinfo, # и %40 не уводят за петлю", async () => {
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-host-"));
    const conf = plant(home);
    for (const url of BAD_HTTP) {
      const res = await runPs1(home, ["--dry-run"], psEnv(url));
      const out = res.stdout + res.stderr;
      expect(res.code, `${url}\n${out}`).not.toBe(0);
      expect(out, url).toContain("разрешён только");
    }
    for (const url of BAD_ANY) {
      const res = await runPs1(home, ["--dry-run"], psEnv(url));
      expect(res.code, JSON.stringify(url)).not.toBe(0);
    }
    for (const url of GOOD_HTTP) {
      const res = await runPs1(home, ["--dry-run"], psEnv(url));
      const out = res.stdout + res.stderr;
      expect(res.code, `${url}\n${out}`).toBe(0);
      expect(out, url).toContain("Только показ: ничего не меняю.");
    }
    expect(readFileSync(conf, "utf8")).toBe(ORIGINAL);
    rmSync(home, { recursive: true, force: true });
  }, 180_000);
});


describe("connect.sh: личная память", () => {
  const runtimes = ["node", "python3"] as const;

  function memoryEnv(home: string, stub: Stub, runtime: "node" | "python3") {
    plant(home);
    const key = path.join(home, ".config", "taskless", "device-key");
    mkdirSync(path.dirname(key), { recursive: true });
    writeFileSync(key, `${TOKEN}\n`, { mode: 0o600 });
    return {
      TASKLESS_URL: stub.url,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
      TASKLESS_KEY_STORE: "file",
      TASKLESS_RUNTIME: runtime,
    };
  }

  function argvLogger(home: string, runtime: "node" | "python3") {
    const bin = path.join(home, "argv-bin");
    mkdirSync(bin, { recursive: true });
    const log = path.join(home, "argv.log");
    const executable = runtime === "node"
      ? process.execPath
      : spawnSync("python3", ["-c", "import sys; print(sys.executable)"], { encoding: "utf8" }).stdout.trim();
    writeFileSync(
      path.join(bin, runtime),
      `#!/bin/sh\nprintf '%s\\n' "$@" >> '${log}'\nexec '${executable}' "$@"\n`,
      { mode: 0o755 },
    );
    return { log, PATH: `${bin}:${TEST_PATH}` };
  }

  function importFile(file: string, counts: number[]) {
    writeFileSync(file, JSON.stringify({
      files: counts.map((count, fileIndex) => ({
        path: `~/notes/file-${fileIndex + 1}.md`,
        source: "notes",
        items: Array.from({ length: count }, (_, itemIndex) => ({
          statement: `Факт ${fileIndex + 1}.${itemIndex + 1}`,
          kind: "fact",
        })),
      })),
    }));
  }

  for (const runtime of runtimes) {
    describe(runtime, () => {
      it("dry-run находит личные источники, две notes-папки, пропуски и только номер строки секрета", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-scan-${runtime}-`));
        plant(home);
        const secret = `ghp_${"a".repeat(30)}`;
        mkdirSync(path.join(home, ".claude", "projects", "project-a", "memory"), { recursive: true });
        writeFileSync(path.join(home, ".claude", "CLAUDE.md"), `Правило\n${secret}\nЕщё правило\n`);
        writeFileSync(path.join(home, ".claude", "projects", "project-a", "memory", "MEMORY.md"), "Память Claude\n");
        mkdirSync(path.join(home, ".codex", "memories"), { recursive: true });
        mkdirSync(path.join(home, ".codex", "memories_v2"), { recursive: true });
        writeFileSync(path.join(home, ".codex", "AGENTS.md"), "Правило Codex\n");
        writeFileSync(path.join(home, ".codex", "memories", "old.md"), "Старая память\n");
        writeFileSync(path.join(home, ".codex", "memories_v2", "new.markdown"), "Новая память\n");
        const notesA = path.join(home, "notes-a");
        const notesB = path.join(home, "notes-b");
        mkdirSync(path.join(notesA, ".git"), { recursive: true });
        mkdirSync(path.join(notesA, "node_modules"), { recursive: true });
        mkdirSync(notesB, { recursive: true });
        writeFileSync(path.join(notesA, "keep.md"), "Заметка\n");
        writeFileSync(path.join(notesB, "keep.txt"), "Вторая папка\n");
        writeFileSync(path.join(notesB, "token-notes.md"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, ".env"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, ".env.md"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, ".env.local.txt"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, "id_rsa"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, "x.pem"), "should-not-be-read\n");
        writeFileSync(path.join(notesA, "binary.md"), Buffer.from([0x61, 0, 0x62]));
        writeFileSync(path.join(notesA, "large.txt"), "x".repeat(300 * 1024));
        writeFileSync(path.join(notesA, "scan.pdf"), "not text\n");
        writeFileSync(path.join(notesA, "CLAUDE.md"), "rules of the team\n");
        writeFileSync(path.join(notesA, ".git", "hidden.md"), "hidden\n");
        writeFileSync(path.join(notesA, "node_modules", "dependency.md"), "dependency\n");
        const outside = path.join(home, "outside.md");
        writeFileSync(outside, "outside\n");
        symlinkSync(outside, path.join(notesA, "linked.md"));

        const res = await run(home, ["--dry-run", "--memory-dir", notesB, "--memory-dir", notesA], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        expect(res.stdout).toContain("~/.claude/CLAUDE.md —");
        expect(res.stdout).toContain("~/.claude/projects/…/memory/ — 1 файл");
        expect(res.stdout).not.toContain("~/.claude/projects/project-a/memory/");
        expect(res.stdout).toContain("~/.codex/AGENTS.md —");
        expect(res.stdout).toContain("~/.codex/memories/ — 1 файл");
        expect(res.stdout).toContain("~/.codex/memories_v2/ — 1 файл");
        expect(res.stdout).toContain("~/notes-a/ — 1 файл");
        expect(res.stdout).toContain("~/notes-b/ — 1 файл");
        expect(res.stdout).toContain("Похоже на секрет: ~/.claude/CLAUDE.md, строка 2. Эту строку в записи не бери.");
        expect(out).not.toContain(secret);
        expect(readFileSync(script, "utf8")).not.toContain(secret);
        for (const skipped of [".env — похоже на ключи", ".env.md — похоже на ключи", ".env.local.txt — похоже на ключи", "token-notes.md — похоже на ключи", "id_rsa", "binary.md", "large.txt", ".git", "linked.md", "CLAUDE.md — правила команды"]) {
          expect(res.stdout).toContain(skipped);
        }
        expect(res.stdout).toContain("Это проверка. Что делать с памятью, установщик скажет при настоящем запуске.");
        expect(res.stdout).not.toContain("Агенту: личная память");
        expect(stub.hits).toHaveLength(0);
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("state null/on/off, пустые источники и ошибка settings управляют поиском и шагами", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-state-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        stub.memoryState = null;
        const emptyNull = await run(home, [], env);
        expect(emptyNull.code, emptyNull.stdout + emptyNull.stderr).toBe(0);
        expect(emptyNull.stdout).toContain("Памяти агентов на компьютере не нашёл");
        expect(emptyNull.stdout).toContain("Агенту: личная память Taskless пока не включена");
        expect(emptyNull.stdout).toContain("--memory on");
        expect(emptyNull.stdout).not.toContain("Спроси, забирать ли найденную память");

        mkdirSync(path.join(home, ".claude"), { recursive: true });
        writeFileSync(path.join(home, ".claude", "CLAUDE.md"), "Личное правило\n");
        const foundNull = await run(home, [], env);
        expect(foundNull.stdout).toContain("Память на этом компьютере. В Taskless пока ничего не ушло.");
        expect(foundNull.stdout).toContain("3. Спроси, забирать ли найденную память");
        expect(foundNull.stdout).toContain("--import-memory <файл>");

        stub.memoryState = "on";
        const foundOn = await run(home, [], env);
        expect(foundOn.stdout).toContain("Агенту: как забрать эту память в Taskless");
        expect(foundOn.stdout).toContain("1. Спроси, забирать ли найденную память");
        expect(foundOn.stdout).not.toContain("Агенту: личная память Taskless пока не включена");
        expect(foundOn.stdout).not.toContain("--memory on");

        stub.memoryState = "off";
        const off = await run(home, [], env);
        expect(off.stdout).toContain("Личная память Taskless выключена, память с компьютера не ищу. Включить её можно в профиле, раздел «Личная память».");
        expect(off.stdout).not.toContain("~/.claude/CLAUDE.md —");
        expect(off.stdout).not.toContain("Память на этом компьютере");

        const emptyHome = mkdtempSync(path.join(tmpdir(), `connect-memory-empty-${runtime}-`));
        const emptyEnv = memoryEnv(emptyHome, stub, runtime);
        stub.memoryState = "on";
        const emptyOn = await run(emptyHome, [], emptyEnv);
        expect(emptyOn.stdout).toContain("Памяти агентов на компьютере не нашёл");
        expect(emptyOn.stdout).not.toContain("Агенту:");

        stub.memorySettingsStatus = 503;
        const failed = await run(home, [], env);
        expect(failed.stdout).toContain("Не узнал, включена ли личная память: Настройки памяти недоступны");
        expect(failed.stdout).not.toContain("Память на этом компьютере");
        stub.memorySettingsStatus = 0;
        const unavailable = await run(home, [], env);
        expect(unavailable.code, unavailable.stdout + unavailable.stderr).toBe(0);
        expect(unavailable.stdout).toContain("Не узнал, включена ли личная память:");
        expect(unavailable.stdout).not.toContain("Память на этом компьютере");
        expect(stub.hits.filter((hit) => hit.url === "/memory/personal/settings")).toHaveLength(7);
        expect(stub.hits.filter((hit) => hit.url === "/memory/personal/settings").every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
        expect(stub.hits.filter((hit) => !["/memory/personal/settings", "/auth/me"].includes(hit.url))).toHaveLength(0);
        rmSync(home, { recursive: true, force: true });
        rmSync(emptyHome, { recursive: true, force: true });
      }, 90_000);

      it("--memory on/off шлёт PUT без ключа в argv; dry-run и ошибки не скрывает", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-set-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const argv = argvLogger(home, runtime);
        const withLog = { ...env, PATH: argv.PATH };

        const on = await run(home, ["--memory", "on"], withLog);
        expect(on.code, on.stdout + on.stderr).toBe(0);
        expect(on.stdout).toContain("Личная память включена.");
        const off = await run(home, ["--memory", "off"], withLog);
        expect(off.code, off.stdout + off.stderr).toBe(0);
        expect(off.stdout).toContain("Личная память выключена. Записи, если были, остались, удалить их можно в профиле.");
        const puts = stub.hits.filter((hit) => hit.url === "/memory/personal/settings" && hit.method === "PUT");
        expect(puts.map((hit) => JSON.parse(hit.body))).toEqual([{ enabled: true }, { enabled: false }]);
        expect(puts.every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
        expect(readFileSync(argv.log, "utf8")).not.toContain(TOKEN);

        stub.hits.length = 0;
        const dry = await run(home, ["--dry-run", "--memory", "on"], withLog);
        expect(dry.code, dry.stdout + dry.stderr).toBe(0);
        expect(dry.stdout).toContain("включил бы личную память");
        expect(stub.hits).toHaveLength(0);

        stub.memorySettingsStatus = 403;
        const failed = await run(home, ["--memory", "on"], withLog);
        expect(failed.code).not.toBe(0);
        expect(failed.stdout + failed.stderr).toContain("Не удалось сменить настройку");

        const noKeyHome = mkdtempSync(path.join(tmpdir(), `connect-memory-nokey-${runtime}-`));
        const noKey = await run(noKeyHome, ["--memory", "on"], {
          TASKLESS_URL: stub.url,
          TASKLESS_KEY_STORE: "file",
          TASKLESS_RUNTIME: runtime,
        });
        expect(noKey.code).not.toBe(0);
        expect(noKey.stdout + noKey.stderr).toContain("Сначала подключи агентов: запусти установщик без флагов");
        const emptyValue = await run(noKeyHome, ["--memory="], {
          TASKLESS_URL: stub.url,
          TASKLESS_KEY_STORE: "file",
          TASKLESS_RUNTIME: runtime,
        });
        expect(emptyValue.code).not.toBe(0);
        expect(emptyValue.stdout + emptyValue.stderr).toContain("После --memory нужно on или off");
        rmSync(home, { recursive: true, force: true });
        rmSync(noKeyHome, { recursive: true, force: true });
      }, 90_000);

      it("--import-memory проверяет JSON, делит 650 записей на 3 запроса и печатает отчёт и ошибки", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-import-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const argv = argvLogger(home, runtime);
        const withLog = { ...env, PATH: argv.PATH };
        const batch = path.join(home, "batch.json");
        importFile(batch, [250, 200, 200]);

        const dry = await run(home, ["--dry-run", "--import-memory", batch], withLog);
        expect(dry.code, dry.stdout + dry.stderr).toBe(0);
        expect(dry.stdout).toContain("650");
        expect(dry.stdout).toContain("file-1.md");
        expect(stub.hits).toHaveLength(0);
        expect(existsSync(batch)).toBe(true);

        const imported = await run(home, ["--import-memory", batch], withLog);
        expect(imported.code, imported.stdout + imported.stderr).toBe(0);
        const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
        expect(posts).toHaveLength(3);
        expect(posts.map((hit) => (JSON.parse(hit.body) as { files: Array<{ items: unknown[] }> }).files.reduce((sum, file) => sum + file.items.length, 0))).toEqual([250, 200, 200]);
        expect(posts.every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
        expect(imported.stdout).toContain("Взял новых: 650. Уже было: 0. Повтор: 0. Пропущено: 0");
        expect(imported.stdout).toContain("file-1.md");
        expect(imported.stdout).toContain("file-3.md");
        expect(readFileSync(argv.log, "utf8")).not.toContain(TOKEN);
        expect(existsSync(batch)).toBe(true);

        importFile(batch, [7]);
        stub.memoryImportReasons = true;
        const withReasons = await run(home, ["--import-memory", batch], withLog);
        expect(withReasons.code, withReasons.stdout + withReasons.stderr).toBe(0);
        expect(withReasons.stdout).toContain("Взял новых: 0. Уже было: 1. Повтор: 1. Пропущено: 5");
        for (const reason of ["секрет — 1", "длиннее 300 знаков — 1", "пусто — 1", "правило без цитаты — 1", "ты это раньше удалил — 1"]) {
          expect(withReasons.stdout).toContain(reason);
        }
        stub.memoryImportReasons = false;

        for (const status of [401, 403, 413, 429]) {
          stub.hits.length = 0;
          stub.memoryImportStatus = status;
          const failed = await run(home, ["--import-memory", batch], withLog);
          expect(failed.code).not.toBe(0);
          expect(failed.stdout + failed.stderr).toContain(`Сервер отклонил импорт: ${status}`);
          expect(stub.hits).toHaveLength(1);
        }
        stub.memoryImportStatus = 200;

        stub.hits.length = 0;
        writeFileSync(batch, "{broken");
        const broken = await run(home, ["--import-memory", batch], withLog);
        expect(broken.code).not.toBe(0);
        expect(broken.stdout + broken.stderr).toContain("batch.json");
        expect(stub.hits).toHaveLength(0);
        writeFileSync(batch, JSON.stringify({ files: [{ path: "x.md", source: "notes", items: [{ kind: "fact" }] }] }));
        const invalid = await run(home, ["--import-memory", batch], withLog);
        expect(invalid.code).not.toBe(0);
        expect(invalid.stdout + invalid.stderr).toContain("файл 1, запись 1");
        expect(stub.hits).toHaveLength(0);
        writeFileSync(batch, JSON.stringify({ files: [{ path: "x.md", source: "notes", modifiedAt: "не дата", items: [{ statement: "Факт" }] }] }));
        const invalidDate = await run(home, ["--import-memory", batch], withLog);
        expect(invalidDate.code).not.toBe(0);
        expect(invalidDate.stdout + invalidDate.stderr).toContain("файл 1: modifiedAt");
        expect(stub.hits).toHaveLength(0);

        const noKeyHome = mkdtempSync(path.join(tmpdir(), `connect-import-nokey-${runtime}-`));
        importFile(batch, [1]);
        const noKey = await run(noKeyHome, ["--import-memory", batch], {
          TASKLESS_URL: stub.url,
          TASKLESS_KEY_STORE: "file",
          TASKLESS_RUNTIME: runtime,
        });
        expect(noKey.code).not.toBe(0);
        expect(noKey.stdout + noKey.stderr).toContain("Сначала подключи агентов: запусти установщик без флагов");
        const emptyValue = await run(noKeyHome, ["--import-memory="], {
          TASKLESS_URL: stub.url,
          TASKLESS_KEY_STORE: "file",
          TASKLESS_RUNTIME: runtime,
        });
        expect(emptyValue.code).not.toBe(0);
        expect(emptyValue.stdout + emptyValue.stderr).toContain("После --import-memory нужен JSON-файл");
        expect(existsSync(batch)).toBe(true);
        rmSync(home, { recursive: true, force: true });
        rmSync(noKeyHome, { recursive: true, force: true });
      }, 120_000);

      it("одни пропуски не считаются найденной памятью и не дают шагов чтения", async () => {
        const stub = await startStub();
        for (const kind of ["symlink", "env"] as const) {
          const home = mkdtempSync(path.join(tmpdir(), `connect-memory-only-skips-${runtime}-${kind}-`));
          const env = memoryEnv(home, stub, runtime);
          stub.memoryState = null;
          const args: string[] = [];
          if (kind === "symlink") {
            mkdirSync(path.join(home, ".claude"), { recursive: true });
            const target = path.join(home, "dotfiles", "CLAUDE.md");
            mkdirSync(path.dirname(target), { recursive: true });
            writeFileSync(target, "Правило из dotfiles\n");
            symlinkSync(target, path.join(home, ".claude", "CLAUDE.md"));
          } else {
            const notes = path.join(home, "notes");
            mkdirSync(notes, { recursive: true });
            writeFileSync(path.join(notes, ".env"), "should-not-be-read\n");
            args.push("--memory-dir", notes);
          }
          const res = await run(home, args, env);
          const out = res.stdout + res.stderr;
          expect(res.code, out).toBe(0);
          expect(res.stdout).toContain("Памяти агентов на компьютере не нашёл");
          expect(res.stdout).not.toContain("Память на этом компьютере");
          expect(res.stdout).not.toContain("Прочитай файлы из списка");
          rmSync(home, { recursive: true, force: true });
        }
      }, 90_000);

      it("печатает первые 10 пропусков и помечает закрытый ключ целиком", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-skips-key-${runtime}-`));
        plant(home);
        const notes = path.join(home, "notes");
        mkdirSync(notes, { recursive: true });
        for (let index = 1; index <= 30; index += 1) {
          writeFileSync(path.join(notes, `skip-${String(index).padStart(2, "0")}.pdf`), "not text\n");
        }
        const privateValue = "private-value-that-must-not-leak";
        writeFileSync(path.join(notes, "keep.md"), [
          "Вступление",
          "-----BEGIN PRIVATE KEY-----",
          privateValue,
          "second-private-line",
          "third-private-line",
          "-----END PRIVATE KEY-----",
          "После ключа",
          "",
        ].join("\n"));
        const res = await run(home, ["--dry-run", "--memory-dir", notes], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const skipped = res.stdout.split("\n").find((line) => line.startsWith("Пропущены:")) || "";
        expect(skipped.match(/~\/notes\/skip-\d+\.pdf/g) || []).toHaveLength(10);
        expect(skipped).toContain("и ещё 20");
        const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/keep.md,"));
        expect(secretLines).toEqual(["Похоже на секрет: ~/notes/keep.md, строки 2–6. Эти строки в записи не бери."]);
        for (const number of [3, 4, 5, 6]) {
          expect(res.stdout).not.toContain(`Похоже на секрет: ~/notes/keep.md, строка ${number}.`);
        }
        expect(out).not.toContain(privateValue);
        expect(out).not.toContain("second-private-line");
        expect(out).not.toContain("third-private-line");
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("сворачивает незакрытый ключ до конца файла в один диапазон без пустой строки", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-open-key-${runtime}-`));
        plant(home);
        const notes = path.join(home, "notes");
        mkdirSync(notes, { recursive: true });
        const fileLines = [
          "Вступление",
          "-----BEGIN PRIVATE KEY-----",
          ...Array.from({ length: 1999 }, (_, index) => `Содержимое ${index + 3}`),
        ];
        writeFileSync(path.join(notes, "open-key.md"), `${fileLines.join("\n")}\n`);
        // Без \n в конце: секрет на последней строке, пустого хвоста нет.
        writeFileSync(path.join(notes, "tail.md"), [
          "Первая",
          "Вторая",
          `ghp_${"b".repeat(30)}`,
        ].join("\n"));
        const res = await run(home, ["--dry-run", "--memory-dir", notes], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/open-key.md,"));
        expect(secretLines).toEqual(["Похоже на секрет: ~/notes/open-key.md, строки 2–2001. Эти строки в записи не бери."]);
        expect(out).not.toContain("2002");
        const tailLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/tail.md,"));
        expect(tailLines).toEqual(["Похоже на секрет: ~/notes/tail.md, строка 3. Эту строку в записи не бери."]);
        expect(res.stdout).not.toContain("Похоже на секрет: ~/notes/tail.md, строка 4");
        expect(res.stdout).not.toContain("Похоже на секрет: ~/notes/tail.md, строки");
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("не объединяет отдельный секрет и закрытый ключ в один диапазон", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-secret-ranges-${runtime}-`));
        plant(home);
        const notes = path.join(home, "notes");
        mkdirSync(notes, { recursive: true });
        writeFileSync(path.join(notes, "mixed.md"), [
          "Вступление",
          "Обычная строка",
          `ghp_${"a".repeat(30)}`,
          ...Array.from({ length: 6 }, (_, index) => `Обычная строка ${index + 4}`),
          "-----BEGIN PRIVATE KEY-----",
          "private-line-1",
          "private-line-2",
          "private-line-3",
          "-----END PRIVATE KEY-----",
          "После ключа",
          "",
        ].join("\n"));
        writeFileSync(path.join(notes, "a.md"), [
          "Обычная строка",
          `ghp_${"c".repeat(30)}`,
          "",
        ].join("\n"));
        writeFileSync(path.join(notes, "b.md"), [
          "Обычная строка",
          "Ещё строка",
          `ghp_${"d".repeat(30)}`,
          "",
        ].join("\n"));
        const res = await run(home, ["--dry-run", "--memory-dir", notes], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/mixed.md,"));
        expect(secretLines).toEqual([
          "Похоже на секрет: ~/notes/mixed.md, строка 3. Эту строку в записи не бери.",
          "Похоже на секрет: ~/notes/mixed.md, строки 10–14. Эти строки в записи не бери.",
        ]);
        const boundary = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/a.md,") || line.startsWith("Похоже на секрет: ~/notes/b.md,"));
        expect(boundary).toEqual([
          "Похоже на секрет: ~/notes/a.md, строка 2. Эту строку в записи не бери.",
          "Похоже на секрет: ~/notes/b.md, строка 3. Эту строку в записи не бери.",
        ]);
        const allSecrets = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет:"));
        const aIndex = allSecrets.findIndex((line) => line.includes("~/notes/a.md"));
        const bIndex = allSecrets.findIndex((line) => line.includes("~/notes/b.md"));
        expect(bIndex).toBe(aIndex + 1);
        expect(res.stdout).not.toContain("строки 2–3");
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("--import-memory отправляет одиночную половинку эмодзи escape-последовательностью", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-surrogate-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const batch = path.join(home, "batch.json");
        const escapedStatement = "оборвано \\ud83d";
        writeFileSync(batch, `{"files":[{"path":"~/notes/broken.md","source":"notes","items":[{"statement":"${escapedStatement}","kind":"fact"}]}]}`);
        const res = await run(home, ["--import-memory", batch], env);
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
        expect(posts).toHaveLength(1);
        const payload = JSON.parse(posts[0]?.body ?? "") as { files: Array<{ items: Array<{ statement: string }> }> };
        expect(payload.files[0]?.items[0]?.statement).toBe(JSON.parse(`"${escapedStatement}"`));
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("--import-memory печатает половинку эмодзи из пути отчёта заменой", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-surrogate-path-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const batch = path.join(home, "batch.json");
        // Нижняя половинка: сужение [\ud800-\udfff] до [\ud800-\udbff] оставляет
        // верхнюю \ud83d зелёной, а python3 падает на \udc00 при записи utf-8.
        const high = "p\uFFFD.md";
        const low = "q\uFFFD.md";
        writeFileSync(batch, JSON.stringify({
          files: [
            { path: "p\ud83d.md", source: "notes", items: [{ statement: "Факт", kind: "fact" }] },
            { path: "q\udc00.md", source: "notes", items: [{ statement: "Факт", kind: "fact" }] },
          ],
        }));
        const res = await run(home, ["--import-memory", batch], env);
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        expect(res.stdout).toBe([
          "Взял новых: 2. Уже было: 0. Повтор: 0. Пропущено: 0",
          `  ${high} — новых 1, уже было 0, повтор 0, пропущено 0`,
          `  ${low} — новых 1, уже было 0, повтор 0, пропущено 0`,
          "",
        ].join("\n"));
        expect(res.stdout).toContain(high);
        expect(res.stdout).toContain(low);
        expect(res.stdout).not.toContain("\ud83d");
        expect(res.stdout).not.toContain("\udc00");
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("сводит память Claude в одну строку и не дублирует нормализованные папки", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-claude-dedup-${runtime}-`));
        plant(home);
        for (const project of ["project-a", "project-b", "project-c"]) {
          const memory = path.join(home, ".claude", "projects", project, "memory");
          mkdirSync(memory, { recursive: true });
          writeFileSync(path.join(memory, "MEMORY.md"), `Память ${project}\n`);
        }
        const notes = path.join(home, "notes");
        mkdirSync(notes, { recursive: true });
        writeFileSync(path.join(notes, "keep.md"), "Заметка\n");
        const res = await run(home, [
          "--dry-run",
          "--memory-dir", notes,
          "--memory-dir", `${notes}${path.sep}`,
          "--memory-dir", `${notes}${path.sep}.${path.sep}`,
        ], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const claudeRows = res.stdout.split("\n").filter((line) => line.includes("~/.claude/projects/"));
        expect(claudeRows).toHaveLength(1);
        expect(claudeRows[0]).toContain("~/.claude/projects/…/memory/ — 3 файла");
        expect(res.stdout.split("\n").filter((line) => line.includes("~/notes/ —"))).toHaveLength(1);
        expect(res.stdout).toContain("~/notes/ — 1 файл");
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("отклоняет несуществующую --memory-dir до запросов", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-missing-${runtime}-`));
        plant(home);
        const missing = `${path.join(home, "missing")}${path.sep}.${path.sep}`;
        const res = await run(home, ["--dry-run", "--memory-dir", missing], {
          TASKLESS_URL: stub.url,
          TASKLESS_CONNECT_STUB: "1",
          TASKLESS_STUB_AGENTS: "claude-code",
          TASKLESS_RUNTIME: runtime,
        });
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(1);
        expect(out).toContain(`Нет такой папки: ${missing}`);
        expect(stub.hits).toHaveLength(0);
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("отправляет 300 кириллических записей одним запросом меньше 1 МиБ", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-utf8-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const batch = path.join(home, "batch.json");
        writeFileSync(batch, JSON.stringify({
          files: [{
            path: "~/notes/cyrillic.md",
            source: "notes",
            items: Array.from({ length: 300 }, () => ({ statement: "я".repeat(300), quote: "я".repeat(300), kind: "fact" })),
          }],
        }));
        const res = await run(home, ["--import-memory", batch], env);
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
        expect(posts).toHaveLength(1);
        expect(Buffer.byteLength(posts[0]!.body, "utf8")).toBeLessThan(1024 * 1024);
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("склоняет записи в общей сводке и по файлам", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-plural-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const batch = path.join(home, "batch.json");
        importFile(batch, [1, 2, 5, 21]);
        const res = await run(home, ["--dry-run", "--import-memory", batch], env);
        const out = res.stdout + res.stderr;
        expect(res.code, out).toBe(0);
        expect(res.stdout).toContain("Проверка: ушло бы 29 записей, запросов не отправил.");
        expect(res.stdout).toContain("file-1.md — 1 запись");
        expect(res.stdout).toContain("file-2.md — 2 записи");
        expect(res.stdout).toContain("file-3.md — 5 записей");
        expect(res.stdout).toContain("file-4.md — 21 запись");
        expect(stub.hits).toHaveLength(0);
        rmSync(home, { recursive: true, force: true });
      }, 90_000);

      it("при ошибке третьего POST печатает отчёты двух пачек и отправленное число", async () => {
        const stub = await startStub();
        const home = mkdtempSync(path.join(tmpdir(), `connect-memory-partial-${runtime}-`));
        const env = memoryEnv(home, stub, runtime);
        const batch = path.join(home, "batch.json");
        importFile(batch, [250, 200, 200]);
        stub.memoryImportFailAt = 3;
        const res = await run(home, ["--import-memory", batch], env);
        const out = res.stdout + res.stderr;
        expect(res.code, out).not.toBe(0);
        expect(res.stdout).toContain("Взял новых: 450. Уже было: 0. Повтор: 0. Пропущено: 0");
        expect(res.stdout).toContain("file-1.md");
        expect(res.stdout).toContain("file-2.md");
        expect(res.stdout).not.toContain("file-3.md");
        expect(res.stdout).toContain("Отправил 450 из 650 записей, дальше остановился:");
        expect(out).toContain("Сервер отклонил импорт: 429");
        expect(stub.hits.filter((hit) => hit.url === "/memory/personal/import")).toHaveLength(3);
        expect(out.indexOf("Взял новых: 450")).toBeLessThan(out.indexOf("Отправил 450 из 650"));
        expect(out.indexOf("Отправил 450 из 650")).toBeLessThan(out.indexOf("Сервер отклонил импорт: 429"));
        rmSync(home, { recursive: true, force: true });
      }, 90_000);
    });
  }
});


describe("connect.ps1", () => {
  function memoryEnv(home: string, stub: Stub) {
    plant(home);
    const key = path.join(home, ".config", "taskless", "device-key");
    mkdirSync(path.dirname(key), { recursive: true });
    writeFileSync(key, `${TOKEN}\n`, { mode: 0o600 });
    return {
      TASKLESS_URL: stub.url,
      TASKLESS_BROWSER: "true",
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
      TASKLESS_KEY_STORE: "file",
    };
  }

  function importFile(file: string, counts: number[]) {
    writeFileSync(file, JSON.stringify({
      files: counts.map((count, fileIndex) => ({
        path: `~/notes/file-${fileIndex + 1}.md`,
        source: "notes",
        items: Array.from({ length: count }, (_, itemIndex) => ({
          statement: `Факт ${fileIndex + 1}.${itemIndex + 1}`,
          kind: "fact",
        })),
      })),
    }));
  }

  it.skipIf(!hasPwsh)("pwsh: dry-run находит личные источники, две notes-папки, пропуски и только номер строки секрета", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-scan-"));
    plant(home);
    const secret = `ghp_${"a".repeat(30)}`;
    mkdirSync(path.join(home, ".claude", "projects", "project-a", "memory"), { recursive: true });
    writeFileSync(path.join(home, ".claude", "CLAUDE.md"), `Правило\n${secret}\nЕщё правило\n`);
    writeFileSync(path.join(home, ".claude", "projects", "project-a", "memory", "MEMORY.md"), "Память Claude\n");
    mkdirSync(path.join(home, ".codex", "memories"), { recursive: true });
    mkdirSync(path.join(home, ".codex", "memories_v2"), { recursive: true });
    writeFileSync(path.join(home, ".codex", "AGENTS.md"), "Правило Codex\n");
    writeFileSync(path.join(home, ".codex", "memories", "old.md"), "Старая память\n");
    writeFileSync(path.join(home, ".codex", "memories_v2", "new.markdown"), "Новая память\n");
    const notesA = path.join(home, "notes-a");
    const notesB = path.join(home, "notes-b");
    mkdirSync(path.join(notesA, ".git"), { recursive: true });
    mkdirSync(path.join(notesA, "node_modules"), { recursive: true });
    mkdirSync(notesB, { recursive: true });
    writeFileSync(path.join(notesA, "keep.md"), "Заметка\n");
    writeFileSync(path.join(notesB, "keep.txt"), "Вторая папка\n");
    writeFileSync(path.join(notesB, "token-notes.md"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, ".env"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, ".env.md"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, ".env.local.txt"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, "id_rsa"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, "x.pem"), "should-not-be-read\n");
    writeFileSync(path.join(notesA, "binary.md"), Buffer.from([0x61, 0, 0x62]));
    writeFileSync(path.join(notesA, "large.txt"), "x".repeat(300 * 1024));
    writeFileSync(path.join(notesA, "scan.pdf"), "not text\n");
    writeFileSync(path.join(notesA, "CLAUDE.md"), "rules of the team\n");
    writeFileSync(path.join(notesA, ".git", "hidden.md"), "hidden\n");
    writeFileSync(path.join(notesA, "node_modules", "dependency.md"), "dependency\n");
    const outside = path.join(home, "outside.md");
    writeFileSync(outside, "outside\n");
    symlinkSync(outside, path.join(notesA, "linked.md"));

    const res = await runPs1(home, ["--dry-run", "--memory-dir", notesB, "--memory-dir", notesA], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(res.stdout).toContain("~/.claude/CLAUDE.md —");
    expect(res.stdout).toContain("~/.claude/projects/…/memory/ — 1 файл");
    expect(res.stdout).not.toContain("~/.claude/projects/project-a/memory/");
    expect(res.stdout).toContain("~/.codex/AGENTS.md —");
    expect(res.stdout).toContain("~/.codex/memories/ — 1 файл");
    expect(res.stdout).toContain("~/.codex/memories_v2/ — 1 файл");
    expect(res.stdout).toContain("~/notes-a/ — 1 файл");
    expect(res.stdout).toContain("~/notes-b/ — 1 файл");
    expect(res.stdout).toContain("Похоже на секрет: ~/.claude/CLAUDE.md, строка 2. Эту строку в записи не бери.");
    expect(out).not.toContain(secret);
    expect(readFileSync(ps1, "utf8")).not.toContain(secret);
    for (const skipped of [".env — похоже на ключи", ".env.md — похоже на ключи", ".env.local.txt — похоже на ключи", "token-notes.md — похоже на ключи", "id_rsa", "binary.md", "large.txt", ".git", "linked.md", "CLAUDE.md — правила команды"]) {
      expect(res.stdout).toContain(skipped);
    }
    expect(res.stdout).toContain("Это проверка. Что делать с памятью, установщик скажет при настоящем запуске.");
    expect(res.stdout).not.toContain("Агенту: личная память");
    expect(stub.hits).toHaveLength(0);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: state null/on/off, пустые источники и ошибка settings управляют поиском и шагами", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-state-"));
    const env = memoryEnv(home, stub);
    stub.memoryState = null;
    const emptyNull = await runPs1(home, [], env);
    expect(emptyNull.code, emptyNull.stdout + emptyNull.stderr).toBe(0);
    expect(emptyNull.stdout).toContain("Памяти агентов на компьютере не нашёл");
    expect(emptyNull.stdout).toContain("Агенту: личная память Taskless пока не включена");
    expect(emptyNull.stdout).toContain("--memory on");
    expect(emptyNull.stdout).not.toContain("Спроси, забирать ли найденную память");

    mkdirSync(path.join(home, ".claude"), { recursive: true });
    writeFileSync(path.join(home, ".claude", "CLAUDE.md"), "Личное правило\n");
    const foundNull = await runPs1(home, [], env);
    expect(foundNull.stdout).toContain("Память на этом компьютере. В Taskless пока ничего не ушло.");
    expect(foundNull.stdout).toContain("3. Спроси, забирать ли найденную память");
    expect(foundNull.stdout).toContain("--import-memory <файл>");

    stub.memoryState = "on";
    const foundOn = await runPs1(home, [], env);
    expect(foundOn.stdout).toContain("Агенту: как забрать эту память в Taskless");
    expect(foundOn.stdout).toContain("1. Спроси, забирать ли найденную память");
    expect(foundOn.stdout).not.toContain("Агенту: личная память Taskless пока не включена");
    expect(foundOn.stdout).not.toContain("--memory on");

    stub.memoryState = "off";
    const off = await runPs1(home, [], env);
    expect(off.stdout).toContain("Личная память Taskless выключена, память с компьютера не ищу. Включить её можно в профиле, раздел «Личная память».");
    expect(off.stdout).not.toContain("~/.claude/CLAUDE.md —");
    expect(off.stdout).not.toContain("Память на этом компьютере");

    const emptyHome = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-empty-"));
    const emptyEnv = memoryEnv(emptyHome, stub);
    stub.memoryState = "on";
    const emptyOn = await runPs1(emptyHome, [], emptyEnv);
    expect(emptyOn.stdout).toContain("Памяти агентов на компьютере не нашёл");
    expect(emptyOn.stdout).not.toContain("Агенту:");

    stub.memorySettingsStatus = 503;
    const failed = await runPs1(home, [], env);
    expect(failed.stdout).toContain("Не узнал, включена ли личная память: Настройки памяти недоступны");
    expect(failed.stdout).not.toContain("Память на этом компьютере");
    stub.memorySettingsStatus = 0;
    const unavailable = await runPs1(home, [], env);
    expect(unavailable.code, unavailable.stdout + unavailable.stderr).toBe(0);
    expect(unavailable.stdout).toContain("Не узнал, включена ли личная память:");
    expect(unavailable.stdout).not.toContain("Память на этом компьютере");
    // .NET повторяет GET четыре раза, если сервер разрушил сокет без ответа.
    expect(stub.hits.filter((hit) => hit.url === "/memory/personal/settings")).toHaveLength(10);
    expect(stub.hits.filter((hit) => hit.url === "/memory/personal/settings").every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
    expect(stub.hits.filter((hit) => !["/memory/personal/settings", "/auth/me"].includes(hit.url))).toHaveLength(0);
    rmSync(home, { recursive: true, force: true });
    rmSync(emptyHome, { recursive: true, force: true });
  }, 120_000);

  it.skipIf(!hasPwsh)("pwsh: --memory on/off шлёт PUT, dry-run и ошибки не скрывает, ключ не печатает", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-set-"));
    const env = memoryEnv(home, stub);

    const on = await runPs1(home, ["--memory", "on"], env);
    expect(on.code, on.stdout + on.stderr).toBe(0);
    expect(on.stdout).toContain("Личная память включена.");
    const off = await runPs1(home, ["--memory", "off"], env);
    expect(off.code, off.stdout + off.stderr).toBe(0);
    expect(off.stdout).toContain("Личная память выключена. Записи, если были, остались, удалить их можно в профиле.");
    const puts = stub.hits.filter((hit) => hit.url === "/memory/personal/settings" && hit.method === "PUT");
    expect(puts.map((hit) => JSON.parse(hit.body))).toEqual([{ enabled: true }, { enabled: false }]);
    expect(puts.every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
    expect(on.stdout + on.stderr + off.stdout + off.stderr).not.toContain(TOKEN);

    stub.hits.length = 0;
    const dry = await runPs1(home, ["--dry-run", "--memory", "on"], env);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(dry.stdout).toContain("включил бы личную память");
    expect(dry.stdout + dry.stderr).not.toContain(TOKEN);
    expect(stub.hits).toHaveLength(0);

    stub.memorySettingsStatus = 403;
    const failed = await runPs1(home, ["--memory", "on"], env);
    expect(failed.code).not.toBe(0);
    expect(failed.stdout + failed.stderr).toContain("Не удалось сменить настройку");

    const noKeyHome = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-nokey-"));
    const noKey = await runPs1(noKeyHome, ["--memory", "on"], {
      TASKLESS_URL: stub.url,
      TASKLESS_KEY_STORE: "file",
    });
    expect(noKey.code).not.toBe(0);
    expect(noKey.stdout + noKey.stderr).toContain("Сначала подключи агентов: запусти установщик без флагов");
    const emptyValue = await runPs1(noKeyHome, ["--memory="], {
      TASKLESS_URL: stub.url,
      TASKLESS_KEY_STORE: "file",
    });
    expect(emptyValue.code).not.toBe(0);
    expect(emptyValue.stdout + emptyValue.stderr).toContain("После --memory нужно on или off");
    rmSync(home, { recursive: true, force: true });
    rmSync(noKeyHome, { recursive: true, force: true });
  }, 120_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory проверяет JSON, делит 650 записей на 3 запроса и печатает отчёт и ошибки", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-import-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    importFile(batch, [250, 200, 200]);

    const dry = await runPs1(home, ["--dry-run", "--import-memory", batch], env);
    expect(dry.code, dry.stdout + dry.stderr).toBe(0);
    expect(dry.stdout).toContain("650");
    expect(dry.stdout).toContain("file-1.md");
    expect(dry.stdout + dry.stderr).not.toContain(TOKEN);
    expect(stub.hits).toHaveLength(0);
    expect(existsSync(batch)).toBe(true);

    const imported = await runPs1(home, ["--import-memory", batch], env);
    expect(imported.code, imported.stdout + imported.stderr).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(3);
    expect(posts.map((hit) => (JSON.parse(hit.body) as { files: Array<{ items: unknown[] }> }).files.reduce((sum, file) => sum + file.items.length, 0))).toEqual([250, 200, 200]);
    expect(posts.every((hit) => hit.auth === `Bearer ${TOKEN}`)).toBe(true);
    expect(imported.stdout).toContain("Взял новых: 650. Уже было: 0. Повтор: 0. Пропущено: 0");
    expect(imported.stdout).toContain("file-1.md");
    expect(imported.stdout).toContain("file-3.md");
    expect(imported.stdout + imported.stderr).not.toContain(TOKEN);
    expect(existsSync(batch)).toBe(true);

    importFile(batch, [7]);
    stub.memoryImportReasons = true;
    const withReasons = await runPs1(home, ["--import-memory", batch], env);
    expect(withReasons.code, withReasons.stdout + withReasons.stderr).toBe(0);
    expect(withReasons.stdout).toContain("Взял новых: 0. Уже было: 1. Повтор: 1. Пропущено: 5");
    for (const reason of ["секрет — 1", "длиннее 300 знаков — 1", "пусто — 1", "правило без цитаты — 1", "ты это раньше удалил — 1"]) {
      expect(withReasons.stdout).toContain(reason);
    }
    stub.memoryImportReasons = false;

    for (const status of [401, 403, 413, 429]) {
      stub.hits.length = 0;
      stub.memoryImportStatus = status;
      const failed = await runPs1(home, ["--import-memory", batch], env);
      expect(failed.code).not.toBe(0);
      expect(failed.stdout + failed.stderr).toContain(`Сервер отклонил импорт: ${status}`);
      expect(stub.hits).toHaveLength(1);
    }
    stub.memoryImportStatus = 200;

    stub.hits.length = 0;
    writeFileSync(batch, "{broken");
    const broken = await runPs1(home, ["--import-memory", batch], env);
    expect(broken.code).not.toBe(0);
    expect(broken.stdout + broken.stderr).toContain("batch.json");
    expect(stub.hits).toHaveLength(0);
    writeFileSync(batch, JSON.stringify({ files: [{ path: "x.md", source: "notes", items: [{ kind: "fact" }] }] }));
    const invalid = await runPs1(home, ["--import-memory", batch], env);
    expect(invalid.code).not.toBe(0);
    expect(invalid.stdout + invalid.stderr).toContain("файл 1, запись 1");
    expect(stub.hits).toHaveLength(0);
    writeFileSync(batch, JSON.stringify({ files: [{ path: "x.md", source: "notes", modifiedAt: "не дата", items: [{ statement: "Факт" }] }] }));
    const invalidDate = await runPs1(home, ["--import-memory", batch], env);
    expect(invalidDate.code).not.toBe(0);
    expect(invalidDate.stdout + invalidDate.stderr).toContain("файл 1: modifiedAt");
    expect(stub.hits).toHaveLength(0);

    const noKeyHome = mkdtempSync(path.join(tmpdir(), "connect-ps-import-nokey-"));
    importFile(batch, [1]);
    const noKey = await runPs1(noKeyHome, ["--import-memory", batch], {
      TASKLESS_URL: stub.url,
      TASKLESS_KEY_STORE: "file",
    });
    expect(noKey.code).not.toBe(0);
    expect(noKey.stdout + noKey.stderr).toContain("Сначала подключи агентов: запусти установщик без флагов");
    writeFileSync(batch, "{broken");
    const noKeyBroken = await runPs1(noKeyHome, ["--import-memory", batch], {
      TASKLESS_URL: stub.url,
      TASKLESS_KEY_STORE: "file",
    });
    expect(noKeyBroken.code).not.toBe(0);
    expect(noKeyBroken.stdout + noKeyBroken.stderr).toContain("Сначала подключи агентов: запусти установщик без флагов");
    const emptyValue = await runPs1(noKeyHome, ["--import-memory="], {
      TASKLESS_URL: stub.url,
      TASKLESS_KEY_STORE: "file",
    });
    expect(emptyValue.code).not.toBe(0);
    expect(emptyValue.stdout + emptyValue.stderr).toContain("После --import-memory нужен JSON-файл");
    expect(existsSync(batch)).toBe(true);
    rmSync(home, { recursive: true, force: true });
    rmSync(noKeyHome, { recursive: true, force: true });
  }, 180_000);

  it.skipIf(!hasPwsh)("pwsh: одни пропуски не считаются найденной памятью и не дают шагов чтения", async () => {
    const stub = await startStub();
    for (const kind of ["symlink", "env"] as const) {
      const home = mkdtempSync(path.join(tmpdir(), `connect-ps-memory-only-skips-${kind}-`));
      const env = memoryEnv(home, stub);
      stub.memoryState = null;
      const args: string[] = [];
      if (kind === "symlink") {
        mkdirSync(path.join(home, ".claude"), { recursive: true });
        const target = path.join(home, "dotfiles", "CLAUDE.md");
        mkdirSync(path.dirname(target), { recursive: true });
        writeFileSync(target, "Правило из dotfiles\n");
        symlinkSync(target, path.join(home, ".claude", "CLAUDE.md"));
      } else {
        const notes = path.join(home, "notes");
        mkdirSync(notes, { recursive: true });
        writeFileSync(path.join(notes, ".env"), "should-not-be-read\n");
        args.push("--memory-dir", notes);
      }
      const res = await runPs1(home, args, env);
      const out = res.stdout + res.stderr;
      expect(res.code, out).toBe(0);
      expect(res.stdout).toContain("Памяти агентов на компьютере не нашёл");
      expect(res.stdout).not.toContain("Память на этом компьютере");
      expect(res.stdout).not.toContain("Прочитай файлы из списка");
      rmSync(home, { recursive: true, force: true });
    }
  }, 120_000);

  it.skipIf(!hasPwsh)("pwsh: печатает первые 10 пропусков и помечает закрытый ключ целиком", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-skips-key-"));
    plant(home);
    const notes = path.join(home, "notes");
    mkdirSync(notes, { recursive: true });
    for (let index = 1; index <= 30; index += 1) {
      writeFileSync(path.join(notes, `skip-${String(index).padStart(2, "0")}.pdf`), "not text\n");
    }
    const privateValue = "private-value-that-must-not-leak";
    writeFileSync(path.join(notes, "keep.md"), [
      "Вступление",
      "-----BEGIN PRIVATE KEY-----",
      privateValue,
      "second-private-line",
      "third-private-line",
      "-----END PRIVATE KEY-----",
      "После ключа",
      "",
    ].join("\n"));
    const res = await runPs1(home, ["--dry-run", "--memory-dir", notes], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    const skipped = res.stdout.split("\n").find((line) => line.startsWith("Пропущены:")) || "";
    expect(skipped.match(/~\/notes\/skip-\d+\.pdf/g) || []).toHaveLength(10);
    expect(skipped).toContain("и ещё 20");
    const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/keep.md,"));
    expect(secretLines).toEqual(["Похоже на секрет: ~/notes/keep.md, строки 2–6. Эти строки в записи не бери."]);
    for (const number of [3, 4, 5, 6]) {
      expect(res.stdout).not.toContain(`Похоже на секрет: ~/notes/keep.md, строка ${number}.`);
    }
    expect(out).not.toContain(privateValue);
    expect(out).not.toContain("second-private-line");
    expect(out).not.toContain("third-private-line");
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: сворачивает незакрытый ключ до конца файла в один диапазон без пустой строки", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-open-key-"));
    plant(home);
    const notes = path.join(home, "notes");
    mkdirSync(notes, { recursive: true });
    const fileLines = [
      "Вступление",
      "-----BEGIN PRIVATE KEY-----",
      ...Array.from({ length: 1999 }, (_, index) => `Содержимое ${index + 3}`),
    ];
    const expected = "Похоже на секрет: ~/notes/open-key.md, строки 2–2001. Эти строки в записи не бери.";
    // Без \n в конце: секрет на последней строке, пустого хвоста нет (PRJ2-122).
    writeFileSync(path.join(notes, "tail.md"), [
      "Первая",
      "Вторая",
      `ghp_${"b".repeat(30)}`,
    ].join("\n"));
    for (const ending of ["\n", "", "\r\n"] as const) {
      const body = ending === "\r\n" ? `${fileLines.join("\r\n")}\r\n` : `${fileLines.join("\n")}${ending}`;
      writeFileSync(path.join(notes, "open-key.md"), body);
      const res = await runPs1(home, ["--dry-run", "--memory-dir", notes], {
        TASKLESS_URL: stub.url,
        TASKLESS_CONNECT_STUB: "1",
        TASKLESS_STUB_AGENTS: "claude-code",
      });
      const out = res.stdout + res.stderr;
      expect(res.code, out).toBe(0);
      const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/open-key.md,"));
      expect(secretLines, `ending ${JSON.stringify(ending)}`).toEqual([expected]);
      expect(out).not.toContain("2002");
      const tailLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/tail.md,"));
      expect(tailLines).toEqual(["Похоже на секрет: ~/notes/tail.md, строка 3. Эту строку в записи не бери."]);
      expect(res.stdout).not.toContain("Похоже на секрет: ~/notes/tail.md, строка 4");
      expect(res.stdout).not.toContain("Похоже на секрет: ~/notes/tail.md, строки");
    }
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: не объединяет отдельный секрет и закрытый ключ в один диапазон", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-secret-ranges-"));
    plant(home);
    const notes = path.join(home, "notes");
    mkdirSync(notes, { recursive: true });
    writeFileSync(path.join(notes, "mixed.md"), [
      "Вступление",
      "Обычная строка",
      `ghp_${"a".repeat(30)}`,
      ...Array.from({ length: 6 }, (_, index) => `Обычная строка ${index + 4}`),
      "-----BEGIN PRIVATE KEY-----",
      "private-line-1",
      "private-line-2",
      "private-line-3",
      "-----END PRIVATE KEY-----",
      "После ключа",
      "",
    ].join("\n"));
    writeFileSync(path.join(notes, "a.md"), [
      "Обычная строка",
      `ghp_${"c".repeat(30)}`,
      "",
    ].join("\n"));
    writeFileSync(path.join(notes, "b.md"), [
      "Обычная строка",
      "Ещё строка",
      `ghp_${"d".repeat(30)}`,
      "",
    ].join("\n"));
    const res = await runPs1(home, ["--dry-run", "--memory-dir", notes], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    const secretLines = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/mixed.md,"));
    expect(secretLines).toEqual([
      "Похоже на секрет: ~/notes/mixed.md, строка 3. Эту строку в записи не бери.",
      "Похоже на секрет: ~/notes/mixed.md, строки 10–14. Эти строки в записи не бери.",
    ]);
    const boundary = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет: ~/notes/a.md,") || line.startsWith("Похоже на секрет: ~/notes/b.md,"));
    expect(boundary).toEqual([
      "Похоже на секрет: ~/notes/a.md, строка 2. Эту строку в записи не бери.",
      "Похоже на секрет: ~/notes/b.md, строка 3. Эту строку в записи не бери.",
    ]);
    const allSecrets = res.stdout.split("\n").filter((line) => line.startsWith("Похоже на секрет:"));
    const aIndex = allSecrets.findIndex((line) => line.includes("~/notes/a.md"));
    const bIndex = allSecrets.findIndex((line) => line.includes("~/notes/b.md"));
    expect(bIndex).toBe(aIndex + 1);
    expect(res.stdout).not.toContain("строки 2–3");
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: пропускает FIFO в --memory-dir и не зависает", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-fifo-"));
    plant(home);
    const notes = path.join(home, "notes");
    mkdirSync(notes, { recursive: true });
    writeFileSync(path.join(notes, "keep.md"), "Заметка\n");
    const fifo = path.join(notes, "pipe.md");
    const made = spawnSync("mkfifo", [fifo]);
    expect(made.status, made.stderr?.toString()).toBe(0);
    const started = Date.now();
    const res = await runPs1(home, ["--dry-run", "--memory-dir", notes], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(Date.now() - started).toBeLessThan(15_000);
    expect(res.code, out).toBe(0);
    expect(out).not.toContain("pipe.md");
    expect(res.stdout).toContain("~/notes/ — 1 файл");
    rmSync(home, { recursive: true, force: true });
  }, 20_000);

  it.skipIf(!hasPwsh)("pwsh: сводит память Claude в одну строку и не дублирует нормализованные папки", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-claude-dedup-"));
    plant(home);
    for (const project of ["project-a", "project-b", "project-c"]) {
      const memory = path.join(home, ".claude", "projects", project, "memory");
      mkdirSync(memory, { recursive: true });
      writeFileSync(path.join(memory, "MEMORY.md"), `Память ${project}\n`);
    }
    const notes = path.join(home, "notes");
    mkdirSync(notes, { recursive: true });
    writeFileSync(path.join(notes, "keep.md"), "Заметка\n");
    const res = await runPs1(home, [
      "--dry-run",
      "--memory-dir", notes,
      "--memory-dir", `${notes}${path.sep}`,
      "--memory-dir", `${notes}${path.sep}.${path.sep}`,
    ], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    const claudeRows = res.stdout.split("\n").filter((line) => line.includes("~/.claude/projects/"));
    expect(claudeRows).toHaveLength(1);
    expect(claudeRows[0]).toContain("~/.claude/projects/…/memory/ — 3 файла");
    expect(res.stdout.split("\n").filter((line) => line.includes("~/notes/ —"))).toHaveLength(1);
    expect(res.stdout).toContain("~/notes/ — 1 файл");
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: отклоняет несуществующую --memory-dir до запросов", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-missing-"));
    plant(home);
    const missing = `${path.join(home, "missing")}${path.sep}.${path.sep}`;
    const res = await runPs1(home, ["--dry-run", "--memory-dir", missing], {
      TASKLESS_URL: stub.url,
      TASKLESS_CONNECT_STUB: "1",
      TASKLESS_STUB_AGENTS: "claude-code",
    });
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(1);
    expect(out).toContain(`Нет такой папки: ${missing}`);
    expect(stub.hits).toHaveLength(0);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: отправляет 300 кириллических записей одним запросом меньше 1 МиБ", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-utf8-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    writeFileSync(batch, JSON.stringify({
      files: [{
        path: "~/notes/cyrillic.md",
        source: "notes",
        items: Array.from({ length: 300 }, () => ({ statement: "я".repeat(300), quote: "я".repeat(300), kind: "fact" })),
      }],
    }));
    const res = await runPs1(home, ["--import-memory", batch], env);
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(1);
    expect(Buffer.byteLength(posts[0]!.body, "utf8")).toBeLessThan(1024 * 1024);
    expect(posts[0]!.body).toContain("я".repeat(300));
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: склоняет записи в общей сводке и по файлам", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-plural-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    importFile(batch, [1, 2, 5, 21]);
    const res = await runPs1(home, ["--dry-run", "--import-memory", batch], env);
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    expect(res.stdout).toContain("Проверка: ушло бы 29 записей, запросов не отправил.");
    expect(res.stdout).toContain("file-1.md — 1 запись");
    expect(res.stdout).toContain("file-2.md — 2 записи");
    expect(res.stdout).toContain("file-3.md — 5 записей");
    expect(res.stdout).toContain("file-4.md — 21 запись");
    expect(stub.hits).toHaveLength(0);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: при ошибке третьего POST печатает отчёты двух пачек и отправленное число", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-partial-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    importFile(batch, [250, 200, 200]);
    stub.memoryImportFailAt = 3;
    const res = await runPs1(home, ["--import-memory", batch], env);
    const out = res.stdout + res.stderr;
    expect(res.code, out).not.toBe(0);
    expect(res.stdout).toContain("Взял новых: 450. Уже было: 0. Повтор: 0. Пропущено: 0");
    expect(res.stdout).toContain("file-1.md");
    expect(res.stdout).toContain("file-2.md");
    expect(res.stdout).not.toContain("file-3.md");
    expect(res.stdout).toContain("Отправил 450 из 650 записей, дальше остановился:");
    expect(out).toContain("Сервер отклонил импорт: 429");
    expect(stub.hits.filter((hit) => hit.url === "/memory/personal/import")).toHaveLength(3);
    expect(out.indexOf("Взял новых: 450")).toBeLessThan(out.indexOf("Отправил 450 из 650"));
    expect(out.indexOf("Отправил 450 из 650")).toBeLessThan(out.indexOf("Сервер отклонил импорт: 429"));
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory отправляет modifiedAt и statement-дату байт в байт", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-dates-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    const modifiedZ = "2026-11-12T01:02:03.456Z";
    const modifiedOffset = "2026-11-01T13:00:00.123+03:00";
    const statementDate = "2026-11-01T10:00:00Z";
    const text = JSON.stringify({
      files: [
        { path: "z.md", source: "notes", modifiedAt: modifiedZ, items: [{ statement: statementDate, kind: "fact" }] },
        { path: "offset.md", source: "notes", modifiedAt: modifiedOffset, items: [{ statement: "Факт", quote: statementDate, kind: "fact" }] },
      ],
    });
    writeFileSync(batch, text);
    const fileBytes = readFileSync(batch);
    const res = await runPs1(home, ["--import-memory", batch], env);
    const out = res.stdout + res.stderr;
    expect(res.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(1);
    const body = Buffer.from(posts[0]?.body ?? "", "utf8");
    for (const date of [modifiedZ, modifiedOffset, statementDate]) {
      const slice = Buffer.from(date, "utf8");
      expect(fileBytes.includes(slice)).toBe(true);
      expect(body.includes(slice)).toBe(true);
    }
    const payload = JSON.parse(posts[0]?.body ?? "") as {
      files: Array<{ modifiedAt: string; items: Array<{ statement: string; quote?: string }> }>;
    };
    expect(payload.files[0]?.modifiedAt).toBe(modifiedZ);
    expect(payload.files[0]?.items[0]?.statement).toBe(statementDate);
    expect(payload.files[1]?.modifiedAt).toBe(modifiedOffset);
    expect(payload.files[1]?.items[0]?.quote).toBe(statementDate);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory отправляет одиночную половинку эмодзи escape-последовательностью", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-surrogate-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    const escapedStatement = "оборвано \\ud83d";
    writeFileSync(batch, `{"files":[{"path":"~/notes/broken.md","source":"notes","items":[{"statement":"${escapedStatement}","kind":"fact"}]}]}`);
    const sh = await run(home, ["--import-memory", batch], { ...env, TASKLESS_RUNTIME: "node" });
    const ps = await runPs1(home, ["--import-memory", batch], env);
    const out = `${sh.stdout}${sh.stderr}${ps.stdout}${ps.stderr}`;
    expect(sh.code, out).toBe(0);
    expect(ps.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(2);
    expect(posts[1]?.body).toBe(posts[0]?.body);
    expect(Buffer.from(posts[1]?.body ?? "", "utf8").includes(Buffer.from([0xef, 0xbf, 0xbd]))).toBe(false);
    const payload = JSON.parse(posts[1]?.body ?? "") as { files: Array<{ items: Array<{ statement: string }> }> };
    expect(payload.files[0]?.items[0]?.statement).toBe(JSON.parse(`"${escapedStatement}"`));
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory отправляет половинку суррогата после экранированного слеша байт в байт", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-surrogate-slash-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    // В файле текст a\\\ud83d: экранированный слеш и одинокий \ud83d.
    const statementSrc = "a\\\\\\ud83d";
    writeFileSync(
      batch,
      `{"files":[{"path":"~/notes/slash.md","source":"notes","items":[{"statement":"${statementSrc}","kind":"fact"}]}]}`,
    );
    expect(readFileSync(batch, "utf8")).toContain(String.raw`a\\\ud83d`);
    const sh = await run(home, ["--import-memory", batch], { ...env, TASKLESS_RUNTIME: "node" });
    const ps = await runPs1(home, ["--import-memory", batch], env);
    const out = `${sh.stdout}${sh.stderr}${ps.stdout}${ps.stderr}`;
    expect(sh.code, out).toBe(0);
    expect(ps.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(2);
    expect(Buffer.from(posts[1]?.body ?? "", "utf8")).toEqual(Buffer.from(posts[0]?.body ?? "", "utf8"));
    expect(Buffer.from(posts[1]?.body ?? "", "utf8").includes(Buffer.from([0xef, 0xbf, 0xbd]))).toBe(false);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory отправляет нижнюю половинку после букв ud83d и после шести слешей байт в байт", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-surrogate-low-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    // В файле буквы ud83d после экранированного слеша и одинокий \udc00; то же с шестью слешами.
    const twoSlashes = "x\\\\ud83d\\udc00";
    const sixSlashes = "x\\\\\\\\\\\\ud83d\\udc00";
    writeFileSync(
      batch,
      `{"files":[{"path":"~/notes/low.md","source":"notes","items":[{"statement":"${twoSlashes}","kind":"fact"},{"statement":"${sixSlashes}","kind":"fact"}]}]}`,
    );
    const raw = readFileSync(batch, "utf8");
    expect(raw).toContain(String.raw`x\\ud83d\udc00`);
    expect(raw).toContain(String.raw`x\\\\\\ud83d\udc00`);
    const sh = await run(home, ["--import-memory", batch], { ...env, TASKLESS_RUNTIME: "node" });
    const ps = await runPs1(home, ["--import-memory", batch], env);
    const out = `${sh.stdout}${sh.stderr}${ps.stdout}${ps.stderr}`;
    expect(sh.code, out).toBe(0);
    expect(ps.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(2);
    expect(Buffer.from(posts[1]?.body ?? "", "utf8")).toEqual(Buffer.from(posts[0]?.body ?? "", "utf8"));
    expect(Buffer.from(posts[1]?.body ?? "", "utf8").includes(Buffer.from([0xef, 0xbf, 0xbd]))).toBe(false);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);

  it.skipIf(!hasPwsh)("pwsh: --import-memory не подменяет текст ~TL118~d83d~", async () => {
    const stub = await startStub();
    const home = mkdtempSync(path.join(tmpdir(), "connect-ps-memory-marker-"));
    const env = memoryEnv(home, stub);
    const batch = path.join(home, "batch.json");
    const statement = "~TL118~d83d~";
    writeFileSync(batch, JSON.stringify({
      files: [{ path: "mark.md", source: "notes", items: [{ statement, kind: "fact" }] }],
    }));
    const sh = await run(home, ["--import-memory", batch], { ...env, TASKLESS_RUNTIME: "node" });
    const ps = await runPs1(home, ["--import-memory", batch], env);
    const out = `${sh.stdout}${sh.stderr}${ps.stdout}${ps.stderr}`;
    expect(sh.code, out).toBe(0);
    expect(ps.code, out).toBe(0);
    const posts = stub.hits.filter((hit) => hit.url === "/memory/personal/import");
    expect(posts).toHaveLength(2);
    expect(Buffer.from(posts[1]?.body ?? "", "utf8")).toEqual(Buffer.from(posts[0]?.body ?? "", "utf8"));
    const payload = JSON.parse(posts[1]?.body ?? "") as { files: Array<{ items: Array<{ statement: string }> }> };
    expect(payload.files[0]?.items[0]?.statement).toBe(statement);
    rmSync(home, { recursive: true, force: true });
  }, 90_000);
});
