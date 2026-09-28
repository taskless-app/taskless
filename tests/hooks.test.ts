// Хуки плагина: скрипты гоняются как есть, через sh, а gh и git подменены стабами в PATH.
// Стаб отвечает тем, что лежит в переменных окружения теста, — так проверяется решение
// хука, а не поведение настоящего GitHub.
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { beforeAll, describe, expect, it } from "vitest";

const kitDir = fileURLToPath(new URL("..", import.meta.url));
const hook = (name: string) => path.join(kitDir, "hooks", name);

let stubDir = "";

beforeAll(() => {
  stubDir = mkdtempSync(path.join(tmpdir(), "kit-hooks-"));
  writeFileSync(
    path.join(stubDir, "gh"),
    `#!/bin/sh
case "$*" in
  *"pr checks"*"--required"*) printf '%s' "$STUB_REQUIRED"; exit 0 ;;
  *"pr checks"*) printf '%s' "$STUB_ALL"; exit 0 ;;
  *"pr view"*reviewDecision*) printf '%s\\n' "$STUB_REVIEW"; exit 0 ;;
  *"pr view"*url*) printf '%s\\n' "$STUB_URL"; exit 0 ;;
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

  it("проверок у PR нет совсем — пропуск", () => {
    const env = {
      STUB_REQUIRED: "no required checks reported on the 'x' branch",
      STUB_ALL: "no checks reported on the 'x' branch",
    };
    expect(run("merge-gate.sh", "gh pr merge 12", env)).toBe("");
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
  it("короткий свод: не длиннее 1500 символов и с правилом о главенстве проекта", () => {
    const res = spawnSync("sh", [hook("session-start.sh")], { encoding: "utf8" });
    expect(res.status).toBe(0);
    expect(res.stdout.length).toBeLessThanOrEqual(1500);
    expect(res.stdout).toContain("Правила проекта главнее этого набора");
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
