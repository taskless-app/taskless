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

function treeHash(root: string): string {
  const h = createHash("sha256");
  const files = filesUnder(root);
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
    const child = spawn("pwsh", ["-NoProfile", "-File", ps1, ...args], {
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
    const res = await run(home, [], {
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

  it.skipIf(!IS_LINUX)("secret-tool есть — ключ в связке, не в файле; второй запуск вход не просит [только Linux]", async () => {
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
    expect(existsSync(path.join(home, ".config", "taskless", "device-key"))).toBe(false);
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
