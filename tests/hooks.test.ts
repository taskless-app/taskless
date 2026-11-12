// Хуки плагина: скрипты гоняются как есть, через sh, а gh и git подменены стабами в PATH.
// Стаб отвечает тем, что лежит в переменных окружения теста, — так проверяется решение
// хука, а не поведение настоящего GitHub.
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

const kitDir = fileURLToPath(new URL("..", import.meta.url));
const hook = (name: string) => path.join(kitDir, "hooks", name);

let stubDir = "";

beforeAll(() => {
  stubDir = mkdtempSync(path.join(tmpdir(), "kit-hooks-"));
  writeFileSync(
    path.join(stubDir, "gh"),
    `#!/bin/sh
# STUB_FAIL=head|runs|workflows|commits|review — обычный ответ и exit 1 только на этом вызове.
# gh api отвечает числами только для repos/acme/widget/. Чужой репозиторий — пустые счётчики,
# как репозиторий без CI: иначе тест «ссылка + -R other/empty» зелёный ещё на сломанном хуке.
fail() { [ "$STUB_FAIL" = "$1" ] && exit 1; exit 0; }
case "$*" in
  *"pr checks"*"--required"*)
    printf '%s' "$STUB_REQUIRED"
    # gh 2.88 пишет «no checks reported» на stderr и выходит с 1 ещё до фильтра --required.
    # «no required checks reported» этой подстроки не содержит и остаётся exit 0, как раньше.
    case "$STUB_REQUIRED" in
      *"no checks reported"*) exit 1 ;;
    esac
    exit 0
    ;;
  *"pr checks"*) printf '%s' "$STUB_ALL"; exit 0 ;;
  *"pr view"*headRefOid*) printf '%s\\n' "$STUB_HEAD"; fail head ;;
  *"pr view"*reviewDecision*) printf '%s\\n' "$STUB_REVIEW"; fail review ;;
  *"pr view"*url*) printf '%s\\n' "$STUB_URL"; exit 0 ;;
  *"repos/acme/widget/actions/runs"*) printf '%s\\n' "$STUB_RUNS"; fail runs ;;
  *"repos/acme/widget/actions/workflows"*) printf '%s\\n' "$STUB_WORKFLOWS"; fail workflows ;;
  *"repos/acme/widget/commits/"*) printf '%s\\n' "$STUB_AGE"; fail commits ;;
  *"actions/runs"*|*"actions/workflows"*|*"commits/"*) printf '0\\n'; exit 0 ;;
esac
exit 1
`,
  );
  writeFileSync(
    path.join(stubDir, "git"),
    `#!/bin/sh
case "$*" in
  *"rev-parse --abbrev-ref HEAD"*) printf '%s\\n' "\${STUB_BRANCH:-main}"; exit 0 ;;
esac
exit 1
`,
  );
  chmodSync(path.join(stubDir, "gh"), 0o755);
  chmodSync(path.join(stubDir, "git"), 0o755);
});

function run(script: string, command: string, env: Record<string, string> = {}) {
  const res = spawnSync("sh", [hook(script)], {
    input: JSON.stringify({ session_id: "s", tool_name: "Bash", tool_input: { command } }),
    encoding: "utf8",
    env: { ...process.env, PATH: `${stubDir}:${process.env.PATH ?? ""}`, TASKLESS_MERGE_GATE: "", ...env },
  });
  expect(res.status).toBe(0);
  return res.stdout.trim();
}

const denied = (out: string) => out.includes('"permissionDecision":"deny"');

describe("commit-slug.sh", () => {
  it("коммит без слага — подсказка без блока", () => {
    const out = run("commit-slug.sh", 'git commit -m "поправил опечатку"');
    expect(out).toContain('"additionalContext"');
    expect(out).not.toContain("permissionDecision");
    JSON.parse(out);
  });

  it("коммит со слагом — тишина", () => {
    expect(run("commit-slug.sh", 'git commit -m "fix(auth): вход по ссылке (PROJ-42)"')).toBe("");
  });

  it("слаг в имени ветки — тишина", () => {
    expect(run("commit-slug.sh", 'git commit -m "поправил опечатку"', { STUB_BRANCH: "PROJ-42-typo" })).toBe("");
  });

  it("упоминание git commit в тексте другой команды — не коммит", () => {
    expect(run("commit-slug.sh", 'echo "потом git commit -m без слага"')).toBe("");
  });

  it("коммит внутри составной команды тоже ловится", () => {
    expect(run("commit-slug.sh", 'git add . && git commit -m "без слага"')).toContain('"additionalContext"');
  });

  it("не Bash — мимо", () => {
    const res = spawnSync("sh", [hook("commit-slug.sh")], {
      input: JSON.stringify({ tool_name: "Write", tool_input: { file_path: "a", content: 'git commit -m "x"' } }),
      encoding: "utf8",
    });
    expect(res.stdout.trim()).toBe("");
  });
});

describe("merge-gate.sh", () => {
  it("обязательные проверки красные — блок", () => {
    const out = run("merge-gate.sh", "gh pr merge 12 --squash", { STUB_REQUIRED: "pass lint\nfail e2e\n" });
    expect(denied(out)).toBe(true);
    expect(out).toContain("e2e");
    JSON.parse(out);
  });

  it("обязательные проверки зелёные — пропуск", () => {
    expect(run("merge-gate.sh", "gh pr merge 12 --squash", { STUB_REQUIRED: "pass lint\npass e2e\n" })).toBe("");
  });

  it("проверки ещё идут — блок", () => {
    expect(denied(run("merge-gate.sh", "gh pr merge 12", { STUB_REQUIRED: "pass lint\npending e2e\n" }))).toBe(true);
  });

  it("gh pr merge внутри составной команды — тоже ловится", () => {
    const out = run("merge-gate.sh", "cd repo && gh pr merge 12 --squash --delete-branch", { STUB_REQUIRED: "fail e2e\n" });
    expect(denied(out)).toBe(true);
  });

  it("на новой строке многострочной команды — тоже ловится", () => {
    expect(denied(run("merge-gate.sh", "cd repo\ngh pr merge 12", { STUB_REQUIRED: "fail e2e\n" }))).toBe(true);
  });

  it("прямой вызов merge-эндпоинта через gh api — ловится", () => {
    const out = run("merge-gate.sh", "gh api -X PUT repos/o/r/pulls/12/merge", { STUB_REQUIRED: "fail e2e\n" });
    expect(denied(out)).toBe(true);
  });

  it("упоминание gh pr merge в сообщении коммита — не мерж", () => {
    expect(run("merge-gate.sh", 'git commit -m "гейт на gh pr merge (PROJ-1)"', { STUB_REQUIRED: "fail e2e\n" })).toBe("");
  });

  it("обязательных проверок нет — смотрим все проверки PR", () => {
    const env = { STUB_REQUIRED: "no required checks reported on the 'x' branch", STUB_ALL: "pass build\npending tests\n" };
    const out = run("merge-gate.sh", "gh pr merge 12", env);
    expect(denied(out)).toBe(true);
    expect(out).toContain("tests");
  });

  // «no checks reported» — все проверки PR. Стаб отдаёт HEAD, прогоны, workflow и возраст
  // коммита из окружения: хук решает, ждать CI или пропускать.
  const HEAD_SHA = "0123456789abcdef0123456789abcdef01234567";
  const noChecks = {
    STUB_REQUIRED: "no required checks reported on the 'x' branch",
    STUB_ALL: "no checks reported on the 'x' branch",
    STUB_HEAD: `${HEAD_SHA} https://github.com/acme/widget/pull/12`,
  };

  it("проверок нет, на коммите есть прогон Actions — запрет", () => {
    const out = run("merge-gate.sh", "gh pr merge 12", { ...noChecks, STUB_RUNS: "1" });
    expect(denied(out)).toBe(true);
    expect(out).toContain("уже заведён");
    expect(out).toContain(HEAD_SHA.slice(0, 7));
    JSON.parse(out);
  });

  it("проверок нет, прогонов нет, workflow есть, коммиту 2 минуты — запрет", () => {
    const out = run("merge-gate.sh", "gh pr merge 12", {
      ...noChecks,
      STUB_RUNS: "0",
      STUB_WORKFLOWS: "3",
      STUB_AGE: "120",
    });
    expect(denied(out)).toBe(true);
    expect(out).toContain("Подожди пару минут");
    JSON.parse(out);
  });

  it("проверок нет, прогонов нет, workflow есть, коммиту 15 минут — пропуск", () => {
    const env = { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "3", STUB_AGE: "900" };
    expect(run("merge-gate.sh", "gh pr merge 12", env)).toBe("");
  });

  it("проверок нет, workflow в репозитории нет — пропуск", () => {
    const env = { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "0" };
    expect(run("merge-gate.sh", "gh pr merge 12", env)).toBe("");
  });

  it("ссылка на PR и -R чужого репозитория, прогон в своём есть — запрет", () => {
    // other/empty у стаба пустой. Хук должен спросить acme/widget из ссылки, не -R.
    const out = run("merge-gate.sh", "gh pr merge https://github.com/acme/widget/pull/12 -R other/empty", {
      ...noChecks,
      STUB_RUNS: "1",
    });
    expect(denied(out)).toBe(true);
    expect(out).toContain("уже заведён");
    JSON.parse(out);
  });

  it("gh пишет no checks reported уже на --required, прогон на коммите есть — запрет", () => {
    const out = run("merge-gate.sh", "gh pr merge 12", {
      STUB_REQUIRED: "no checks reported on the '@MCP-108' branch",
      STUB_HEAD: `${HEAD_SHA} https://github.com/acme/widget/pull/12`,
      STUB_RUNS: "1",
    });
    expect(denied(out)).toBe(true);
    expect(out).toContain("уже заведён");
    JSON.parse(out);
  });

  // Ответ на упавшем вызове такой, что без «|| deny» именно на нём хук пропустил бы мерж.
  it.each<[string, Record<string, string>, string]>([
    ["head", { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "0" }, "Не смог узнать HEAD PR"],
    ["runs", { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "0" }, "прогоны Actions"],
    ["workflows", { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "0" }, "workflow репозитория"],
    ["commits", { ...noChecks, STUB_RUNS: "0", STUB_WORKFLOWS: "3", STUB_AGE: "900" }, "возраст коммита"],
    ["review", { STUB_REQUIRED: "pass ci\n", STUB_REVIEW: "APPROVED" }, "Не смог прочитать решение ревью"],
  ])("gh упал на %s — запрет", (fail, env, text) => {
    const out = run("merge-gate.sh", "gh pr merge 12", { ...env, STUB_FAIL: fail });
    expect(denied(out)).toBe(true);
    expect(out).toContain(text);
    JSON.parse(out);
  });

  it("защита ветки требует ревью, а одобрения нет — блок", () => {
    const out = run("merge-gate.sh", "gh pr merge 12", { STUB_REQUIRED: "pass ci\n", STUB_REVIEW: "REVIEW_REQUIRED" });
    expect(denied(out)).toBe(true);
  });

  it("ревью одобрено — пропуск", () => {
    expect(run("merge-gate.sh", "gh pr merge 12", { STUB_REQUIRED: "pass ci\n", STUB_REVIEW: "APPROVED" })).toBe("");
  });

  it("gh не ответил по-человечески — запрет, а не пропуск", () => {
    const out = run("merge-gate.sh", "gh pr merge 12", { STUB_REQUIRED: "HTTP 401: Bad credentials" });
    expect(denied(out)).toBe(true);
  });

  it("человек снял гейт в окружении агента — пропуск", () => {
    expect(run("merge-gate.sh", "gh pr merge 12", { STUB_REQUIRED: "fail e2e\n", TASKLESS_MERGE_GATE: "off" })).toBe("");
  });

  it("не мерж — мимо", () => {
    expect(run("merge-gate.sh", "gh pr view 12", { STUB_REQUIRED: "fail e2e\n" })).toBe("");
  });
});

describe("session-start.sh", () => {
  const homes: string[] = [];
  const servers: import("node:http").Server[] = [];

  const home = () => {
    const dir = mkdtempSync(path.join(tmpdir(), "kit-session-home-"));
    homes.push(dir);
    return dir;
  };
  const withKey = (dir: string) => {
    const helper = path.join(dir, ".config", "taskless", "mcp-headers");
    mkdirSync(path.dirname(helper), { recursive: true });
    writeFileSync(helper, '#!/bin/sh\nprintf \'{"Authorization":"Bearer tldev_test"}\\n\'\n');
    chmodSync(helper, 0o700);
  };
  const withApiUrl = (dir: string, url: string) => {
    const file = path.join(dir, ".config", "taskless", "api-url");
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, `${url}\n`);
  };
  const cloud = async (body: string, delayMs = 0) => {
    const { createServer } = await import("node:http");
    let authorization: string | undefined;
    let requests = 0;
    const server = createServer((req, res) => {
      requests++;
      authorization = req.headers.authorization;
      setTimeout(() => {
        res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
        res.end(body);
      }, delayMs);
    });
    servers.push(server);
    server.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => server.once("listening", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("no test server port");
    return {
      url: `http://127.0.0.1:${address.port}/api`,
      authorization: () => authorization,
      requests: () => requests,
    };
  };
  const start = (homeDir: string, apiUrl?: string) => spawnSync("sh", [hook("session-start.sh")], {
    encoding: "utf8",
    timeout: 5000,
    env: { ...process.env, TASKLESS_SWARM_DRONE: "", SWARM_TASK_SLUG: "", HOME: homeDir, ...(apiUrl ? { TASKLESS_URL: apiUrl } : {}) },
  });
  const startAsync = (homeDir: string, apiUrl?: string, extraEnv: Record<string, string> = {}, shell = "sh") => new Promise<{
    status: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string;
  }>((resolve, reject) => {
    const child = spawn(shell, [hook("session-start.sh")], {
      env: { ...process.env, TASKLESS_SWARM_DRONE: "", SWARM_TASK_SLUG: "", HOME: homeDir, ...(apiUrl ? { TASKLESS_URL: apiUrl } : {}), ...extraEnv },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    const timer = setTimeout(() => child.kill(), 5000);
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      resolve({ status, signal, stdout, stderr });
    });
  });
  const context = (stdout: string) => {
    const parsed = JSON.parse(stdout) as { hookSpecificOutput: { additionalContext: string } };
    return parsed.hookSpecificOutput.additionalContext;
  };

  afterEach(async () => {
    for (const dir of homes.splice(0)) rmSync(dir, { recursive: true, force: true });
    for (const server of servers.splice(0)) {
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("без ключа — прежний короткий свод, не длиннее 1500 символов", () => {
    const res = start(home());
    expect(res.status).toBe(0);
    expect(res.stderr).toBe("");
    expect(res.stdout.length).toBeLessThanOrEqual(1500);
    expect(res.stdout).toContain("Правила проекта главнее этого набора");
  });

  it("api-url на тестовый сервер — выжимка в additionalContext, ключ идёт Bearer, JSON валиден", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud('## Личная память\n- "Сначала суть"\n- путь \\ и\nперевод строки');
    withApiUrl(dir, server.url);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(res.stderr).toBe("");
    expect(server.authorization()).toBe("Bearer tldev_test");
    const text = context(res.stdout);
    expect(text).toContain("Правила проекта главнее этого набора");
    expect(text).toContain("Сначала суть");
    expect(text).toContain("перевод строки");
  });

  it("api-url с CRLF сохраняет выжимку", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("## Личная память\n- прочитано после CRLF");
    writeFileSync(path.join(dir, ".config", "taskless", "api-url"), `${server.url}\r\n`);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(server.requests()).toBe(1);
    expect(context(res.stdout)).toContain("прочитано после CRLF");
  });

  it("TASKLESS_URL из env не получает ключ: чужой сервер видит ноль запросов", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("## Личная память\n- утечка");
    const res = await startAsync(dir, server.url);
    expect(res.status).toBe(0);
    expect(server.requests()).toBe(0);
    expect(res.stdout).not.toContain("утечка");
  });

  it("api-url с http не на петле — ноль запросов и прежний свод", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("## Личная память\n- не запрашивать");
    const unsafeUrl = server.url.replace("127.0.0.1", "0.0.0.0");
    withApiUrl(dir, unsafeUrl);
    const res = await startAsync(dir, unsafeUrl);
    expect(res.status).toBe(0);
    expect(server.requests()).toBe(0);
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    expect(res.stdout).not.toContain("не запрашивать");
  });

  it.each(["", "x"])("api-url с userinfo и суффиксом порта %q не отправляет ключ на чужой сервер", async (suffix) => {
    const dir = home();
    withKey(dir);
    const recipient = await cloud("## Личная память\n- адресат");
    const foreign = await cloud("## Личная память\n- утечка через userinfo");
    const recipientPort = new URL(recipient.url).port;
    const foreignPort = new URL(foreign.url).port;
    withApiUrl(dir, `http://127.0.0.1:${recipientPort}${suffix}@127.0.0.1:${foreignPort}/`);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(recipient.requests()).toBe(0);
    expect(foreign.requests()).toBe(0);
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    expect(res.stdout).not.toContain("утечка через userinfo");
  });

  it.each([
    ["TASKLESS_SWARM_DRONE", { TASKLESS_SWARM_DRONE: "1" }],
    ["SWARM_TASK_SLUG", { SWARM_TASK_SLUG: "PRJ2-999" }],
  ])("у процесса дрона %s отключает запрос личной памяти", async (_name, extraEnv) => {
    const dir = home();
    withKey(dir);
    const server = await cloud("## Личная память\n- не для дрона");
    withApiUrl(dir, server.url);
    const res = await startAsync(dir, undefined, extraEnv);
    expect(res.status).toBe(0);
    expect(server.requests()).toBe(0);
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    expect(res.stdout).not.toContain("не для дрона");
  });

  it("выжимка с ESC и BEL не ломает JSON стартового свода", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("## Личная память\n- цвет \u001b[31mкрасный\u001b[0m звонок \u0007");
    withApiUrl(dir, server.url);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(() => JSON.parse(res.stdout)).not.toThrow();
    expect(context(res.stdout)).toContain("цвет [31mкрасный[0m звонок");
  });

  it("медленный helper останавливается за 2 секунды, хук укладывается в 3", async () => {
    const dir = home();
    withKey(dir);
    writeFileSync(
      path.join(dir, ".config", "taskless", "mcp-headers"),
      '#!/bin/sh\nsleep 8\nprintf \'{"Authorization":"Bearer tldev_test"}\\n\'\n',
    );
    const server = await cloud("## Личная память\n- слишком поздно");
    withApiUrl(dir, server.url);
    const before = Date.now();
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(res.signal).toBeNull();
    expect(Date.now() - before).toBeLessThan(3000);
    expect(server.requests()).toBe(0);
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
  }, 10_000);

  it.each(["sh", "dash", "bash"])("таймаут helper гасит дочерние процессы в %s", async (shell) => {
    const dir = home();
    withKey(dir);
    const pidFile = path.join(dir, "helper-child.pid");
    writeFileSync(
      path.join(dir, ".config", "taskless", "mcp-headers"),
      '#!/bin/sh\nsleep 8 &\necho $! > "$HELPER_PID_FILE"\nwait\n',
    );
    const res = await startAsync(dir, undefined, { HELPER_PID_FILE: pidFile }, shell);
    expect(res.status).toBe(0);
    expect(res.stderr).toBe("");
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    const childPid = Number(readFileSync(pidFile, "utf8"));
    const isAlive = () => {
      try {
        process.kill(childPid, 0);
        return true;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
        throw error;
      }
    };
    try {
      await new Promise((resolve) => setTimeout(resolve, 3000));
      expect(isAlive()).toBe(false);
    } finally {
      if (isAlive()) process.kill(childPid, "SIGTERM");
    }
  }, 10_000);

  it("таймаут добивает внука helper, который игнорирует TERM", async () => {
    const dir = home();
    withKey(dir);
    const pidFile = path.join(dir, "helper-grandchild.pid");
    writeFileSync(
      path.join(dir, ".config", "taskless", "mcp-headers"),
      '#!/bin/sh\nsh -c \'trap "" TERM; sleep 8\' &\necho $! > "$HELPER_PID_FILE"\nwait\n',
    );
    const before = Date.now();
    const res = await startAsync(dir, undefined, { HELPER_PID_FILE: pidFile });
    expect(res.status).toBe(0);
    expect(res.stderr).toBe("");
    expect(Date.now() - before).toBeLessThan(3000);
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    const childPid = Number(readFileSync(pidFile, "utf8"));
    const isAlive = () => {
      try {
        process.kill(childPid, 0);
        return true;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
        throw error;
      }
    };
    try {
      await new Promise((resolve) => setTimeout(resolve, 3000));
      expect(isAlive()).toBe(false);
    } finally {
      if (isAlive()) process.kill(childPid, "SIGKILL");
    }
  }, 10_000);

  it("HTML вместо выжимки не попадает в контекст", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("<html><body>captive portal</body></html>");
    withApiUrl(dir, server.url);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(res.stdout).not.toContain("captive portal");
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
  });

  it("ответ в 1 МБ обрезается до 4000 байт выжимки", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud(`## Личная память\n- ${"x".repeat(1024 * 1024)}`);
    withApiUrl(dir, server.url);
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(context(res.stdout)).toContain("## Личная память");
    expect(res.stdout.length).toBeLessThan(6000);
  });

  it("облако не ответило за пару секунд — тихо прежний свод без зависания", async () => {
    const dir = home();
    withKey(dir);
    const server = await cloud("не должно попасть", 3500);
    withApiUrl(dir, server.url);
    const before = Date.now();
    const res = await startAsync(dir);
    expect(res.status).toBe(0);
    expect(res.signal).toBeNull();
    expect(Date.now() - before).toBeLessThan(3000);
    expect(res.stderr).toBe("");
    expect(context(res.stdout)).toContain("Правила проекта главнее этого набора");
    expect(res.stdout).not.toContain("не должно попасть");
  });

  // MCP-79: файл хуков Claude Code — hooks/claude.json (его же читает Codex);
  // hooks/hooks.json по умолчанию ищут Cursor и Gemini CLI со своим форматом.
  it("hooks/claude.json объявляет все три скрипта через CLAUDE_PLUGIN_ROOT", () => {
    const decl = readFileSync(path.join(kitDir, "hooks", "claude.json"), "utf8");
    for (const f of ["session-start.sh", "commit-slug.sh", "merge-gate.sh"]) {
      expect(decl).toContain(`\${CLAUDE_PLUGIN_ROOT}/hooks/${f}`);
    }
    JSON.parse(decl);
  });
});

describe("swarm-watch.sh (Stop-хук надзора роя)", () => {
  const runStop = (input: Record<string, unknown>, env: Record<string, string> = {}) => {
    const res = spawnSync("sh", [hook("swarm-watch.sh")], {
      input: JSON.stringify(input),
      encoding: "utf8",
      env: { ...process.env, ...env },
    });
    return { status: res.status ?? 0, stdout: res.stdout.trim() };
  };
  const transcript = (lines: string[]) => {
    const dir = mkdtempSync(path.join(tmpdir(), "kit-swarm-watch-"));
    const file = path.join(dir, "t.jsonl");
    writeFileSync(file, lines.join("\n"));
    return file;
  };
  // Сигнатура вызова тула — как в блоках tool_use Claude/ZCode; упоминание в тексте
  // (без "name":"...) не считается.
  const WAIT = '"name":"mcp__taskless__swarm_wait_event"';
  const OTHER = '"name":"mcp__7f3e__swarm_list_runs"';

  it("молчит без transcript_path и без CLAUDE_SESSION_ID (fail-open)", () => {
    const r = runStop({ stop_hook_active: false });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("молчит при stop_hook_active — повторный вызов не зацикливается", () => {
    const r = runStop({ stop_hook_active: true, transcript_path: transcript([WAIT]) });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("ход поднадзорен: wait_event в окне 250 — не блокирует", () => {
    const lines = Array.from({ length: 300 }, (_, i) => (i < 299 ? OTHER : WAIT));
    const r = runStop({ transcript_path: transcript(lines) });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("блокирует: swarm-туры были, wait_event в хвосте нет", () => {
    // 300 строк чужих swarm-туров + окно 250 без wait_event → блок с reason.
    const lines = Array.from({ length: 300 }, () => OTHER);
    const r = runStop({ transcript_path: transcript(lines) });
    expect(r.stdout).toContain("decision");
    expect(r.stdout).toContain("swarm_wait_event");
  });

  it("не блокирует чужую сессию: swarm-туров в окне 2000 нет", () => {
    const lines = Array.from({ length: 300 }, () => '"type":"text","text":"упоминание swarm_wait_event в тексте"');
    const r = runStop({ transcript_path: transcript(lines) });
    expect(r.status).toBe(0);
    expect(r.stdout).toBe("");
  });
});
