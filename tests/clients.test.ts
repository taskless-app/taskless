// MCP-79: тот же набор ставится в Cursor, Codex и Gemini CLI. Форматы — по
// официальной документации клиентов, ссылки на неё — в README. Тест сторожит
// то, что проверяется без самих клиентов: манифесты парсятся, имя, версия и
// заголовок X-Taskless-Kit совпадают с плагином Claude Code, пути ведут на
// существующие файлы, skills у всех клиентов — один каталог.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { readJson } from "./kit.js";

const root = path.resolve(import.meta.dirname, "..");
const MCP_URL = "https://taskless.ru/api/mcp";

type Json = Record<string, unknown>;
const read = (rel: string) => readJson(path.join(root, rel)) as Json;
const obj = (v: unknown) => (v ?? {}) as Json;

const claude = read(".claude-plugin/plugin.json");
const version = claude.version as string;

describe("Agent Plugins 1.0.0: корневой манифест для Cursor и Codex", () => {
  it("plugin.json: $schema стандарта, имя и версия плагина", () => {
    const manifest = read("plugin.json");
    expect(manifest.$schema).toBe("https://agent-plugins.org/schemas/1.0.0/plugin.schema.json");
    expect(manifest.name).toBe(claude.name);
    expect(manifest.version).toBe(version);
  });

  it("mcp.json: только $schema и mcpServers, taskless по streamable-http с версией набора", () => {
    const mcp = read("mcp.json");
    expect(Object.keys(mcp).sort()).toEqual(["$schema", "mcpServers"]);
    expect(mcp.$schema).toBe("https://agent-plugins.org/schemas/1.0.0/mcp.schema.json");
    expect(obj(mcp.mcpServers).taskless).toEqual({
      type: "streamable-http",
      url: MCP_URL,
      headers: { "X-Taskless-Kit": version },
    });
  });
});

describe("Cursor", () => {
  it(".cursor-plugin/plugin.json: имя и версия плагина", () => {
    const manifest = read(".cursor-plugin/plugin.json");
    expect(manifest.name).toBe(claude.name);
    expect(manifest.version).toBe(version);
  });

  it("marketplace.json: одна запись, её источник — корень с .cursor-plugin/plugin.json", () => {
    const plugins = read(".cursor-plugin/marketplace.json").plugins as Json[];
    expect(plugins).toHaveLength(1);
    expect(plugins[0]!.name).toBe(claude.name);
    expect(existsSync(path.join(root, plugins[0]!.source as string, ".cursor-plugin/plugin.json"))).toBe(true);
  });
});

describe("Codex", () => {
  it(".agents/plugins/marketplace.json: запись local из корня, в корне plugin.json", () => {
    const plugins = read(".agents/plugins/marketplace.json").plugins as Json[];
    expect(plugins).toHaveLength(1);
    expect(plugins[0]!.name).toBe(claude.name);
    expect(plugins[0]!.source).toEqual({ source: "local", path: "./" });
    expect(existsSync(path.join(root, "plugin.json"))).toBe(true);
  });

  it("хуки — явным путём в extensions.com.openai, тот же файл, что у Claude Code", () => {
    const hooks = obj(obj(read("plugin.json").extensions)["com.openai"]).hooks;
    expect(hooks).toBe(claude.hooks);
  });
});

describe("Gemini CLI", () => {
  it("gemini-extension.json: имя, версия, MCP по httpUrl с версией набора", () => {
    const ext = read("gemini-extension.json");
    expect(ext.name).toBe(claude.name);
    expect(ext.version).toBe(version);
    expect(obj(ext.mcpServers).taskless).toEqual({ httpUrl: MCP_URL, headers: { "X-Taskless-Kit": version } });
  });

  it("файл контекста — тот же текст, что свод на старте сессии", () => {
    const ext = read("gemini-extension.json");
    const file = path.join(root, ext.contextFileName as string);
    expect(existsSync(file)).toBe(true);
    const out = spawnSync("sh", [path.join(root, "hooks", "session-start.sh")], { encoding: "utf8" });
    // Свод — JSON additionalContext (ZCode принимает только строгий JSON и сырой stdout
    // выбрасывает), текст внутри вычищен как в json_str: переводы строк и табы — пробелы,
    // слэши и кавычки вырезаны, хвостовые переводы строк сняты подстановкой команд.
    const parsed = JSON.parse(out.stdout) as { hookSpecificOutput?: { hookEventName?: string; additionalContext?: string } };
    expect(parsed.hookSpecificOutput?.hookEventName).toBe("SessionStart");
    const norm = (s: string) => s.replace(/[\n\r\t]/g, " ").replace(/\\/g, " ").replace(/"/g, "'").trimEnd();
    expect(parsed.hookSpecificOutput?.additionalContext).toBe(norm(readFileSync(file, "utf8")));
  });
});

// hooks/hooks.json по умолчанию ищут Cursor, Codex и Gemini CLI, и формат хуков
// у каждого свой. Файл в формате Claude Code там прочитали бы неверно, поэтому
// его нет: Claude Code и Codex берут хуки явным путём.
describe("хуки не лежат там, где их ищут чужие клиенты", () => {
  it("hooks/hooks.json нет; путь из .claude-plugin/plugin.json ведёт на файл", () => {
    expect(existsSync(path.join(root, "hooks", "hooks.json"))).toBe(false);
    expect(typeof claude.hooks).toBe("string");
    expect(existsSync(path.join(root, claude.hooks as string))).toBe(true);
  });
});

describe("skills — один каталог на всех", () => {
  // ZCode не подхватывает skills по умолчанию — манифесту Claude Code нужно явное
  // "./skills". Остальным клиентам объявление не мешает, поэтому разрешаем ровно его.
  it("ни один манифест не уводит skills из skills/, и skills там есть", () => {
    for (const rel of [".claude-plugin/plugin.json", "plugin.json", ".cursor-plugin/plugin.json", "gemini-extension.json"]) {
      expect([undefined, "./skills"], rel).toContain(read(rel).skills);
    }
    const skills = readdirSync(path.join(root, "skills")).filter((d) => existsSync(path.join(root, "skills", d, "SKILL.md")));
    expect(skills.length).toBeGreaterThan(0);
  });
});
