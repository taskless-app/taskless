# Подключение клиентов: Claude Code и Codex

Форматы сверены с документацией клиентов при реализации MCP-105. Оба установщика делают одно и то же: `connect.sh` на macOS/Linux, `connect.ps1` на Windows.

Если конфиг клиента найден, но его CLI нет в `PATH`, сервер и ключ всё равно прописываются, а установщик печатает команды плагина для ручного запуска. Это не аварийный выход после частичной записи: отчёт явно отделяет готовый MCP от оставшегося шага.

## Claude Code

### Конфиг и сервер

- Пользовательский конфиг: `~/.claude.json`.
- Сервер записывается только в ключ `mcpServers.taskless`, остальные ключи, серверы и их порядок сохраняются:

```json
{
  "mcpServers": {
    "taskless": {
      "type": "http",
      "url": "https://taskless.ru/api/mcp",
      "headersHelper": "sh \"/home/user/.config/taskless/mcp-headers\""
    }
  }
}
```

В Windows `headersHelper` — `powershell -NoProfile -ExecutionPolicy Bypass -File "<домашний каталог>/.config/taskless/mcp-headers.ps1"`; при запуске `connect.ps1` в macOS/Linux используется `pwsh`.

Выбрана правка JSON встроенным помощником на `node`/`python3`, а не `claude mcp add`: она работает одинаково с `--dry-run`, делает копию `~/.claude.json.bak-taskless`, не портит соседние ключи и умеет вернуть исходный файл при `--uninstall`. Помощник меняет только `mcpServers.taskless`. Если такой сервер существовал до установки, uninstall восстанавливает его, не откатывая более поздние чужие изменения.

Документация: [MCP в Claude Code](https://code.claude.com/docs/en/mcp), в том числе пользовательский scope и `headersHelper`.

### Плагин и хуки

```sh
claude plugin marketplace add taskless-app/taskless
claude plugin install taskless@taskless-app --scope user
```

Плагин сам подключает `hooks/claude.json`: `SessionStart`, `PreToolUse` и `Stop`. Отдельной записи хуков в пользовательском конфиге не нужно. После установки Claude Code надо перезапустить или выполнить `/reload-plugins`.

Документация: [команды плагинов](https://code.claude.com/docs/en/plugins/cli-reference), [загрузка плагинов](https://code.claude.com/docs/en/plugins/loading), [хуки](https://code.claude.com/docs/en/hooks).

### Почему нет второго OAuth

Плагин тоже содержит сервер `taskless` в `.mcp.json`. Claude Code не сливает его с пользовательским: плагинный сервер регистрируется как `plugin:taskless:taskless` и автоматически стартует вместе с плагином. Если оставить его без заголовка, он попросил бы отдельный OAuth-вход.

Поэтому плагинный сервер использует `headersHelper`:

```text
node "${CLAUDE_PLUGIN_ROOT}/connect/plugin-headers.mjs"
```

Диспетчер вызывает тот же постоянный `~/.config/taskless/mcp-headers[.ps1]`, что и пользовательский сервер. Оба определения получают один device key, поэтому после одного «Разрешить» `who_am_i` работает без второго входа. Если установщика не было и постоянного helper нет, диспетчер возвращает `{}`: ручная установка плагина сохраняет прежний OAuth-сценарий.

## Codex

### Конфиг и сервер

- Пользовательский конфиг: `~/.codex/config.toml`.
- Между метками `# >>> taskless:codex` и `# <<< taskless:codex` установщик пишет:

```toml
[mcp_servers.taskless]
url = "https://taskless.ru/api/mcp"
http_headers_helper = "sh \"/home/user/.config/taskless/mcp-headers\""

[plugins."taskless@taskless-app".mcp_servers.taskless]
enabled = false
```

В Windows в `http_headers_helper` записывается вызов `powershell -NoProfile -ExecutionPolicy Bypass -File` с `mcp-headers.ps1`.

Выбран `http_headers_helper`, а не `bearer_token_env_var` или статический `http_headers`: человеку не нужно экспортировать секрет в каждый процесс Codex, ключ не попадает в TOML, а Codex сам вызывает helper при подключении и повторяет его после отказа авторизации по правилам клиента. Это не `headersHelper` из Claude: имя поля у Codex именно `http_headers_helper`.

Блок добавляется атомарно с копией `config.toml.bak-taskless`; повтор заменяет только его. Если пользовательский или плагинный `taskless` уже задан без меток — таблицей (в том числе `[mcp_servers."taskless"]`, с пробелами или одинарными кавычками), inline-таблицей либо dotted-ключами — установщик удаляет старые определения и записывает один маркированный блок вместо невалидного дубля. Uninstall возвращает исходные определения из копии перед тем же следующим заголовком, а не по устаревшему байтовому смещению; если заголовок исчез, восстанавливает их в конец файла с предупреждением. При отсутствии более поздних правок возвращается исходный файл байт в байт. Чужие серверы и более поздние правки вне нашего блока сохраняются. Перед записью Python 3.11+ разбирает итоговый TOML через `tomllib`; на остальных рантаймах установщик проверяет единственность обоих определений `taskless` и при дубле не меняет файл.

Документация: [MCP в Codex](https://developers.openai.com/codex/mcp), [справочник конфигурации](https://developers.openai.com/codex/config-file/config-reference).

### Плагин и хуки

```sh
codex plugin marketplace add taskless-app/taskless
codex plugin add taskless@taskless-app
```

Маркетплейс — `.agents/plugins/marketplace.json`, манифест — корневой `plugin.json`. Хуки подключены через `extensions.com.openai.hooks = "./hooks/claude.json"`; формат событий совместим с Codex, а `${CLAUDE_PLUGIN_ROOT}` Codex выставляет для совместимости.

**Хуки надо одобрить в `/hooks`.** Codex не запускает непроверенные хуки и снова просит доверие после изменения их определения или кода. Плагин работает с новой сессии.

Плагинный MCP в Codex отключен настройкой `plugins."taskless@taskless-app".mcp_servers.taskless.enabled = false`: переносимый Agent Plugins `mcp.json` не имеет поля динамического helper, поэтому вместо второго OAuth остаётся только пользовательский `[mcp_servers.taskless]` с device key.

Документация: [команды Codex CLI](https://developers.openai.com/codex/developer-commands#codex-plugin), [сборка плагина](https://developers.openai.com/plugins/build/plugins), [хуки и их одобрение](https://developers.openai.com/codex/hooks).

## Память агентов на диске

`connect.sh` ищет только личные источники в домашнем каталоге и папки, явно переданные через `--memory-dir`. Файлы `CLAUDE.md` и `AGENTS.md` внутри репозиториев не забирает: это правила команды.

- **Claude Code:** личные инструкции — `~/.claude/CLAUDE.md`; автоматическая память каждого проекта — `~/.claude/projects/<project>/memory/`, включая индекс `MEMORY.md` и тематические Markdown-файлы. Источник: [Memory в Claude Code](https://code.claude.com/docs/en/memory), разделы «Choose where to put CLAUDE.md files» и «Storage location».
- **Codex:** глобальные инструкции — `~/.codex/AGENTS.md` (если человек создал `AGENTS.override.md`, Codex использует его вместо основного файла). Локальная память — `~/.codex/memories/` и `~/.codex/memories_v2/`: свежий Codex home по умолчанию использует v2, а существующий `memories/` сохраняет v1; при миграции могут быть оба каталога. Это сгенерированное состояние, а не файлы для ручного редактирования. Источники: [Custom instructions with AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md) и [Memories](https://developers.openai.com/codex/customization/memories), раздел «Local memory storage».

## Как хук берёт ключ

Единая команда для MCP и хука начала сессии (PRJ2-111):

- macOS/Linux: `sh "$HOME/.config/taskless/mcp-headers"`;
- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.config/taskless/mcp-headers.ps1"`.

Путь постоянный и не зависит от версии или каталога плагина. Адрес API хук читает из первой строки `~/.config/taskless/api-url` (без файла — `https://taskless.ru/api`, переменную `TASKLESS_URL` из окружения не использует); HTTPS обязателен, кроме HTTP на `localhost` или `127.0.0.1`. Скрипт возвращает ровно:

```json
{"Authorization":"Bearer tldev_…"}
```

Источник ключа тот же, что у установщика:

1. macOS Keychain: `security find-generic-password -a taskless -s taskless-device -w`;
2. Linux libsecret: `secret-tool lookup service taskless account device`;
3. Windows Credential Manager: target `taskless-device`, user `taskless`;
4. fallback: `~/.config/taskless/device-key` с правами `600`.

На Linux установщик сохраняет файловую копию с правами `600` и при успешной записи в libsecret: Codex запускает helper с очищенным окружением без `DBUS_SESSION_BUS_ADDRESS` и `XDG_RUNTIME_DIR`, поэтому после отказа `secret-tool` helper читает эту копию.

Ключ не передаётся в аргументах процессов и не записывается в конфиг клиента. Второго способа чтения связки нет: диспетчер плагина только вызывает этот же скрипт. Если ключа нет, пользовательский helper завершается с ошибкой. Если helper отсутствует или его shell не удалось запустить, диспетчер плагина возвращает `{}` с кодом 0. В этих случаях Claude Code может подключиться без `Authorization`; дальше доступ определяет ответ сервера, обычно 401.

Сведения об устройстве остаются в `~/.config/taskless/device.json`. Общий helper удаляется при uninstall только тогда, когда не осталось ни Claude Code, ни Codex, которые его используют.

## Известные ограничения

- На Node `JSON.parse`/`JSON.stringify` теряет точность целых чисел больше `2^53` в `~/.claude.json`; Python сохраняет такие числа без изменений.
