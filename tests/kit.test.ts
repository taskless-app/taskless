import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { checkSkills, PROJECT_RULES_FIRST, readJson, SKILL_MAX_CHARS } from "./kit.js";

const root = path.resolve(import.meta.dirname, "..");

interface PluginManifest {
  name?: string;
  version?: string;
  description?: string;
  author?: { name?: string };
  license?: string;
}

interface Marketplace {
  name?: string;
  owner?: { name?: string };
  plugins?: { name?: string; source?: unknown; description?: string }[];
}

interface McpConfig {
  mcpServers?: Record<string, { type?: string; url?: string; headers?: Record<string, string> }>;
}

const plugin = readJson(path.join(root, ".claude-plugin/plugin.json")) as PluginManifest;
const marketplace = readJson(path.join(root, ".claude-plugin/marketplace.json")) as Marketplace;
const mcp = readJson(path.join(root, ".mcp.json")) as McpConfig;

describe("манифесты", () => {
  it("plugin.json: обязательные поля на месте", () => {
    expect(plugin.name).toBe("taskless");
    expect(plugin.version).toMatch(/^\d+\.\d+\.\d+/);
    expect(plugin.description).toBeTruthy();
    expect(plugin.author?.name).toBeTruthy();
    expect(plugin.license).toBe("MIT");
  });

  it("marketplace.json: обязательные поля, запись плагина из корня", () => {
    expect(marketplace.name).toBe("taskless-app");
    expect(marketplace.owner?.name).toBeTruthy();
    expect(marketplace.plugins).toHaveLength(1);
    const entry = marketplace.plugins![0]!;
    expect(entry.source).toBe("./");
    expect(entry.description).toBeTruthy();
  });

  it("имя записи маркетплейса равно имени плагина — иначе install по имени падает", () => {
    expect(marketplace.plugins![0]!.name).toBe(plugin.name);
  });

  it(".mcp.json: сервер taskless по http с версией набора в X-Taskless-Kit", () => {
    const server = mcp.mcpServers?.taskless;
    expect(server?.type).toBe("http");
    expect(server?.url).toBe("https://taskless.ru/api/mcp");
    expect(server?.headers?.["X-Taskless-Kit"]).toBe(plugin.version);
  });
});

describe("skills набора", () => {
  it("все skills проходят проверки (пустой skills/ — тоже)", () => {
    expect(checkSkills(path.join(root, "skills"))).toEqual([]);
  });

  it("README содержит фразу, которой начинается каждый skill", () => {
    expect(readFileSync(path.join(root, "README.md"), "utf8")).toContain(PROJECT_RULES_FIRST);
  });
});

// Проверки на заведомо сломанных skills: пока skills/ пуст, только они и
// показывают, что проверка вообще что-то ловит.
describe("checkSkills ловит нарушения", () => {
  let dir = "";
  afterEach(() => {
    if (dir) rmSync(dir, { recursive: true, force: true });
    dir = "";
  });

  function skill(name: string, text: string, extra: Record<string, string> = {}): string {
    dir ||= mkdtempSync(path.join(tmpdir(), "agent-kit-"));
    mkdirSync(path.join(dir, name), { recursive: true });
    writeFileSync(path.join(dir, name, "SKILL.md"), text);
    for (const [f, c] of Object.entries(extra)) writeFileSync(path.join(dir, name, f), c);
    return dir;
  }
  const good = (name: string, body = "Текст.") =>
    `---\nname: ${name}\ndescription: Когда звать\n---\n\n${PROJECT_RULES_FIRST}\n\n${body}\n`;

  it("корректный skill проходит", () => {
    expect(checkSkills(skill("taskless-start", good("taskless-start")))).toEqual([]);
  });

  it("без frontmatter", () => {
    expect(checkSkills(skill("taskless-start", `${PROJECT_RULES_FIRST}\n`))).toEqual([
      "skills/taskless-start/SKILL.md: нет frontmatter (--- name/description ---)",
    ]);
  });

  it("name не совпадает с каталогом и без префикса", () => {
    const errs = checkSkills(skill("taskless-start", good("start")));
    expect(errs).toContain("skills/taskless-start/SKILL.md: name «start» не совпадает с каталогом «taskless-start»");
    expect(errs).toContain("skills/taskless-start/SKILL.md: name «start» не начинается с «taskless-»");
  });

  it("без description", () => {
    const text = `---\nname: taskless-start\n---\n\n${PROJECT_RULES_FIRST}\n`;
    expect(checkSkills(skill("taskless-start", text))).toEqual([
      "skills/taskless-start/SKILL.md: во frontmatter нет description",
    ]);
  });

  it("первая строка тела — не фраза о правилах проекта", () => {
    const text = "---\nname: taskless-start\ndescription: x\n---\n\n# Заголовок\n";
    expect(checkSkills(skill("taskless-start", text))).toHaveLength(1);
  });

  it("каталог без SKILL.md", () => {
    dir = mkdtempSync(path.join(tmpdir(), "agent-kit-"));
    mkdirSync(path.join(dir, "taskless-start"));
    expect(checkSkills(dir)).toEqual(["skills/taskless-start: нет SKILL.md"]);
  });

  it("SKILL.md длиннее предела и сумма больше общего предела", () => {
    const long = "а".repeat(SKILL_MAX_CHARS);
    for (const n of ["one", "two", "three", "four", "five", "six", "seven"]) {
      skill(`taskless-${n}`, good(`taskless-${n}`, long));
    }
    const errs = checkSkills(dir);
    expect(errs.filter((e) => e.includes("предел 6000"))).toHaveLength(7);
    expect(errs.some((e) => e.startsWith("skills: суммарно"))).toBe(true);
  });

  it("пути монорепо Taskless — и в SKILL.md, и в справочных файлах", () => {
    const errs = checkSkills(
      skill("taskless-start", good("taskless-start", "см. packages/api"), { "ref.md": "z-index: var(--z-popover)" }),
    );
    expect(errs.sort()).toEqual([
      "taskless-start/SKILL.md: путь монорепо Taskless «packages/» — набор для чужих проектов",
      "taskless-start/ref.md: путь монорепо Taskless «--z-» — набор для чужих проектов",
    ]);
  });
});
