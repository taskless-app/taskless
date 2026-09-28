# Taskless для агента

Плагин [Taskless](https://taskless.ru) для агентов, которые пишут код. Подключил —
и агент работает по процессу Taskless: мелкую ясную задачу делает сразу, фичу
оформляет короткой спекой и деревом подзадач, начинает с теста и сдаёт работу с
доказательствами.

Что внутри:

- **MCP-сервер Taskless** — `https://taskless.ru/api/mcp`. Плагин шлёт заголовок
  `X-Taskless-Kit` с версией набора: по нему сервер понимает, что плагин стоит.
- **Skills** — процесс по шагам (`skills/`), один каталог для всех клиентов.
- **Хуки** — короткий свод процесса на старте сессии и подсказки по ходу работы
  (`hooks/`).
- **Свод процесса** — `CONTEXT.md`: его печатает хук на старте сессии, а Gemini CLI
  грузит как файл контекста.

Набор ставится в четыре клиента. Где что работает:

| Клиент | Манифест | MCP | Skills | Хуки |
| --- | --- | --- | --- | --- |
| Claude Code | `.claude-plugin/plugin.json`, `.mcp.json` | да | да | да |
| Cursor | `.cursor-plugin/plugin.json`, `mcp.json` | да | да | нет |
| Codex CLI | `plugin.json`, `mcp.json` (Agent Plugins 1.0.0) | да | да | да, после доверия |
| Gemini CLI | `gemini-extension.json` | да | да | нет |

## Skills

- `taskless-start` — вход в задачу: память, сырая постановка, мелкое сразу в работу.
- `taskless-shape` — короткая спека документом и дерево подзадач вместо плана-простыни.
- `taskless-build` — подзадача: сначала красный тест из критерия приёмки, потом код.
- `taskless-check` — проверка запуском, а не чтением, и доказательства в критериях.
- `taskless-review` — ревью диффа по классам дефектов, своего перед сдачей и чужого.
- `taskless-debug` — систематическая отладка: первопричина до фикса.
- `taskless-ship` — PR со ссылкой на задачу, обязательные проверки, закрытие задачи после мержа.
- `taskless-po-chelovecheski` — русские тексты для людей без канцелярита.

### Правила проекта главнее набора

Первая строка тела каждого skill — ровно эта фраза (её проверяет тест набора):

```
Правила проекта главнее этого набора: где его CLAUDE.md, AGENTS.md или собственные skills расходятся с текстом ниже, следуй проекту.
```

Плагин не пишет в `CLAUDE.md`, `AGENTS.md` и `.claude/` проекта.

## Установка

### Claude Code

```
/plugin marketplace add taskless-app/taskless
/plugin install taskless@taskless-app
```

Из локальной копии, чтобы править сам набор, — из корня этого репозитория:

```
claude --plugin-dir .
```

В монорепо Taskless набор лежит в `packages/agent-kit`, отсюда его копия.

Хуки Claude Code лежат в `hooks/claude.json`, путь к ним — поле `hooks` в
`.claude-plugin/plugin.json`. Файла `hooks/hooks.json` в наборе нет намеренно: по
этому пути хуки ищут и Cursor, и Codex, и Gemini CLI, а формат у каждого свой.

### Cursor

Customize → From GitHub Repository → `taskless-app/taskless`. Cursor берёт плагин
по `.cursor-plugin/marketplace.json`, запись в нём указывает на корень репозитория.
Документация: [плагины](https://cursor.com/docs/plugins),
[формат](https://cursor.com/docs/reference/plugins).

- Работает: MCP (`mcp.json`, адрес и заголовок), skills из `skills/`.
- Нет хуков. У Cursor свои события и поля ответа (`sessionStart` отдаёт
  `additional_context`, `beforeShellExecution` — `permission`), скрипты набора
  отвечают в формате Claude Code. Перевести их — отдельная задача.

### Codex CLI

```
codex plugin marketplace add taskless-app/taskless
```

Затем `/plugins` в Codex, плагин `taskless`; работает с новой сессии. Codex читает
корневой `plugin.json` по стандарту [Agent Plugins 1.0.0](https://agent-plugins.org/)
и маркетплейс `.agents/plugins/marketplace.json`. Документация:
[сборка плагина](https://developers.openai.com/plugins/build/plugins),
[установка](https://learn.chatgpt.com/docs/plugins),
[хуки](https://learn.chatgpt.com/docs/hooks).

- Работает: MCP (`mcp.json`, `streamable-http`), skills из `skills/`.
- Хуки — тот же `hooks/claude.json`, путь задан в `extensions.com.openai.hooks`.
  Схема событий у Codex та же (`SessionStart`, `PreToolUse` с `Bash`,
  `permissionDecision`), и `CLAUDE_PLUGIN_ROOT` он выставляет для совместимости.
  Хуки плагина Codex запускает, только когда пользователь их проверил и доверил.

### Gemini CLI

```
gemini extensions install https://github.com/taskless-app/taskless
```

Манифест — `gemini-extension.json`: MCP по `httpUrl` с заголовком, файл контекста
`CONTEXT.md`, skills из `skills/`. Документация:
[расширения](https://geminicli.com/docs/extensions/reference/),
[MCP](https://geminicli.com/docs/tools/mcp-server/),
[skills](https://geminicli.com/docs/cli/skills/).

- Нет хуков: события у Gemini CLI свои (`BeforeTool`, инструмент
  `run_shell_command`), а `hooks/hooks.json` расширение не задаёт.
- С 18.06.2026 бесплатным пользователям и Google One вместо Gemini CLI выдают
  Antigravity CLI. Расширение работает там, где Gemini CLI остался: Code Assist
  Standard и Enterprise, Google Cloud, платные ключи API.

### Что не проверено

Форматы взяты из официальной документации, но живьём в клиентах набор ещё не
ставили. Открытые вопросы:

- Cursor: примет ли маркетплейс запись `"source": "./"` (плагин в корне репозитория)
  и какой манифест возьмёт, если рядом лежат корневой `plugin.json` и
  `.cursor-plugin/plugin.json`. Оба описывают одно и то же, так что результат
  должен совпасть. Работает ли установка из GitHub на личных тарифах.
- Codex: примет ли маркетплейс `"source": "local"` с путём `./` (документация для
  плагина в корне советует `"source": "url"`, но примера не даёт), отправляет ли
  заголовки из `mcp.json`, берёт ли в контекст обычный вывод хука `SessionStart`.
- Gemini CLI: переносится ли расширение в Antigravity (`agy plugin import gemini`).

## Разработка

`pnpm test` проверяет набор:

- манифесты всех клиентов парсятся, имя и версия у них одни, а заголовок
  `X-Taskless-Kit` в каждом MCP-конфиге равен версии плагина;
- пути из манифестов ведут на существующие файлы, `hooks/hooks.json` нет, skills
  лежат в `skills/` у всех;
- у каждого skill есть frontmatter `name` (равен каталогу, начинается с `taskless-`)
  и `description`, тело начинается с фразы выше, SKILL.md не длиннее 6000
  символов, все вместе — не длиннее 40000, и в текстах нет путей монорепо Taskless;
- хуки — на стабах `gh` и `git`.

Меняешь версию — меняй её во всех манифестах и заголовках разом, тест это сверяет.

## Лицензия

MIT — см. [LICENSE](LICENSE). Часть текстов адаптирована из superpowers — см. [NOTICE](NOTICE).
