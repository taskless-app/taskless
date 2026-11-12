#!/bin/sh
# Свод процесса Taskless на старте сессии + главное из личной памяти человека.
# Прежний свод ограничен 1500 знаками, у выжимки — свой лимит на сервере. Вывод —
# строгий JSON additionalContext: ZCode сырой stdout молча выбрасывает. Без device
# key, curl или ответа облака за 2 секунды — тихо отдаём прежний свод.

# JSON-строка из текста: переводы строк и табы в пробелы, кавычки и слэши вычищены —
# так результат валиден на любом sed (тот же приём, что в commit-slug.sh и merge-gate.sh).
json_str() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' | sed "s/\\\\/ /g; s/\"/'/g; s/^/\"/; s/\$/\"/"
}

print_context() {
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
    "$(json_str "$1")"
}

context=$(cat "$(dirname "$0")/../CONTEXT.md")
[ -z "${TASKLESS_SWARM_DRONE:-}" ] && [ -z "${SWARM_TASK_SLUG:-}" ] || { print_context "$context"; exit 0; }
helper=${HOME:+$HOME/.config/taskless/mcp-headers}
[ -n "$helper" ] && [ -f "$helper" ] || { print_context "$context"; exit 0; }

# Тот же постоянный helper, который установщик прописал в headersHelper. Второго
# чтения связки ключей здесь нет. Ключ передаём curl через stdin config, не argv.
# Без perl не ждём возможный пароль связки ключей: остаёмся на прежнем своде.
# setpgrp не требует TTY (в отличие от job control у dash), а отрицательный PID
# в alarm гасит всю группу helper, включая его дочерние процессы.
command -v perl >/dev/null 2>&1 || { print_context "$context"; exit 0; }
helper_out=$(mktemp) || { print_context "$context"; exit 0; }
perl -e 'my $pgid=$$; setpgrp(0,0); $SIG{ALRM}=sub{$SIG{TERM}="IGNORE"; kill "TERM",-$pgid; my $pid=fork; if (defined($pid) && $pid==0) { select(undef,undef,undef,0.2); kill "KILL",-$pgid; exit 0 } exit 124}; alarm 2; system @ARGV; exit($?>>8)' sh "$helper" >"$helper_out" 2>/dev/null
helper_status=$?
headers=$(cat "$helper_out")
rm -f "$helper_out"
[ "$helper_status" = 0 ] || { print_context "$context"; exit 0; }
authorization=$(printf '%s' "$headers" | sed -n 's/.*"Authorization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
case $authorization in
  Bearer\ *) ;;
  *) { print_context "$context"; exit 0; } ;;
esac

api_url=https://taskless.ru/api
api_url_file=$HOME/.config/taskless/api-url
[ ! -f "$api_url_file" ] || api_url=$(sed -n '1p' "$api_url_file" | tr -d '\r')
valid_url=0
case $api_url in
  https://*) valid_url=1 ;;
  http://*)
    authority=${api_url#http://}
    authority=${authority%%/*}
    case $authority in
      127.0.0.1|localhost) valid_url=1 ;;
      127.0.0.1:*|localhost:*)
        case ${authority#*:} in
          ''|*[!0-9]*) ;;
          *) valid_url=1 ;;
        esac
        ;;
    esac
    ;;
esac
[ "$valid_url" = 1 ] || { print_context "$context"; exit 0; }

digest=$(printf 'header = "Authorization: %s"\n' "$authorization" | \
  curl -fs --connect-timeout 1 --max-time 2 --config - \
  "${api_url%/}/memory/personal/digest" 2>/dev/null | head -c 4000) || digest=""
case $digest in
  "## Личная память"*) ;;
  *) digest="" ;;
esac

if [ -n "$digest" ]; then
  context="$context

$digest"
fi
print_context "$context"
