// Проверки набора: чистые функции над каталогом плагина. Возвращают список
// нарушений (пустой = набор в порядке), чтобы тест мог прогнать их и на
// настоящем skills/, и на фикстурах с заведомо сломанными skills.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

// Первая строка тела каждого SKILL.md. Её же копируют задачи skills — см. README.
export const PROJECT_RULES_FIRST =
  "Правила проекта главнее этого набора: где его CLAUDE.md, AGENTS.md или собственные skills расходятся с текстом ниже, следуй проекту.";

export const SKILL_MAX_CHARS = 6000;
export const SKILLS_TOTAL_MAX_CHARS = 40000;
export const SKILL_NAME_PREFIX = "taskless-";

// Набор ставится в чужие проекты: пути и токены монорепо Taskless там ложны.
export const MONOREPO_MARKERS = ["packages/", "--z-"];

export function readJson(file: string): unknown {
  return JSON.parse(readFileSync(file, "utf8"));
}

interface Frontmatter {
  fields: Record<string, string>;
  body: string;
}

// Минимальный разбор frontmatter: плоские `ключ: значение` между `---`.
// YAML-библиотека ради двух полей не нужна; вложенное skills не используют.
export function parseFrontmatter(text: string): Frontmatter | null {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(text);
  if (!m) return null;
  const fields: Record<string, string> = {};
  for (const line of m[1]!.split(/\r?\n/)) {
    const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
    if (!kv) continue;
    fields[kv[1]!] = kv[2]!.trim().replace(/^(["'])(.*)\1$/, "$2");
  }
  return { fields, body: m[2]! };
}

export function checkSkills(skillsDir: string): string[] {
  const errors: string[] = [];
  const dirs = existsSync(skillsDir)
    ? readdirSync(skillsDir).filter((d) => statSync(path.join(skillsDir, d)).isDirectory())
    : [];
  let total = 0;

  for (const dir of dirs) {
    const where = `skills/${dir}`;
    const file = path.join(skillsDir, dir, "SKILL.md");
    if (!existsSync(file)) {
      errors.push(`${where}: нет SKILL.md`);
      continue;
    }
    const text = readFileSync(file, "utf8");
    total += text.length;
    if (text.length > SKILL_MAX_CHARS) {
      errors.push(`${where}/SKILL.md: ${text.length} символов, предел ${SKILL_MAX_CHARS}`);
    }

    const fm = parseFrontmatter(text);
    if (!fm) {
      errors.push(`${where}/SKILL.md: нет frontmatter (--- name/description ---)`);
    } else {
      const { name, description } = fm.fields;
      if (!name) errors.push(`${where}/SKILL.md: во frontmatter нет name`);
      else {
        if (name !== dir) errors.push(`${where}/SKILL.md: name «${name}» не совпадает с каталогом «${dir}»`);
        if (!name.startsWith(SKILL_NAME_PREFIX)) {
          errors.push(`${where}/SKILL.md: name «${name}» не начинается с «${SKILL_NAME_PREFIX}»`);
        }
      }
      if (!description) errors.push(`${where}/SKILL.md: во frontmatter нет description`);
      const firstLine = fm.body.split(/\r?\n/).find((l) => l.trim() !== "")?.trim();
      if (firstLine !== PROJECT_RULES_FIRST) {
        errors.push(`${where}/SKILL.md: первая строка тела — не фраза о главенстве правил проекта (см. README)`);
      }
    }

    // Не только SKILL.md: справочные файлы skill'а тоже уезжают в чужие проекты.
    for (const f of listFiles(path.join(skillsDir, dir))) {
      const content = readFileSync(f, "utf8");
      for (const marker of MONOREPO_MARKERS) {
        if (content.includes(marker)) {
          errors.push(`${path.relative(skillsDir, f)}: путь монорепо Taskless «${marker}» — набор для чужих проектов`);
        }
      }
    }
  }

  if (total > SKILLS_TOTAL_MAX_CHARS) {
    errors.push(`skills: суммарно ${total} символов в SKILL.md, предел ${SKILLS_TOTAL_MAX_CHARS}`);
  }
  return errors;
}

function listFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    return e.isDirectory() ? listFiles(p) : [p];
  });
}
