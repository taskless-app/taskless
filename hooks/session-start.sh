#!/bin/sh
# Свод процесса Taskless на старте сессии: какие skills есть и когда какой звать.
# Держим коротким (тест ограничивает 1500 символами): этот текст перечитывается на каждом
# шаге сессии, и длинный свод стоил бы больше, чем даёт. Вывод — JSON additionalContext:
# Claude Code и Codex кладут его в контекст, а ZCode принимает только строгий JSON
# и сырой stdout молча выбрасывает. Ничего не пишет, в сеть не ходит.
# Сам текст — CONTEXT.md в корне набора: его же Gemini CLI грузит файлом контекста
# (contextFileName в gemini-extension.json), источник у свода один.

# JSON-строка из текста: переводы строк и табы в пробелы, кавычки и слэши вычищены —
# так результат валиден на любом sed (тот же приём, что в commit-slug.sh и merge-gate.sh).
json_str() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed "s/\\\\/ /g; s/\"/'/g; s/^/\"/; s/\$/\"/"
}

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
  "$(json_str "$(cat "$(dirname "$0")/../CONTEXT.md")")"
