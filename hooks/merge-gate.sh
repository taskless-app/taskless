#!/bin/sh
# Гейт мержа (PreToolUse на Bash): `gh pr merge` из-под агента не проходит, пока проверки
# PR не зелёные. Смотрим обязательные проверки; если у репозитория их нет (защита веток не
# настроена) — все проверки PR. Вердикт ревью требуем, только если его требует защита ветки
# проекта: тогда GitHub отдаёт reviewDecision, и без APPROVED мержить нельзя.
#
# Хук читает текст команды, поэтому ловит `gh pr merge` и прямой вызов merge-эндпоинта через
# `gh api` в позиции команды — в том числе внутри составной (`cd x && gh pr merge 12`), — но
# не упоминание этих слов в тексте (сообщение коммита про `gh pr merge` мерж не делает).
#
# Не ответил gh — запрет: гейт, который при своей поломке пропускает мерж, бесполезен.
# Снять гейт может только человек (см. ESCAPE). В сеть ходит только через gh, в файлы не пишет.

input="$(cat)"

json_str() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed "s/\\\\/ /g; s/\"/'/g; s/^/\"/; s/\$/\"/"
}
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_str "$1")"
  exit 0
}

# Переменную хук читает из окружения САМОГО агента, а не из перехваченной команды:
# префикс `TASKLESS_MERGE_GATE=off gh pr merge` гейт не снимает, и это намеренно.
ESCAPE="Снять гейт может человек: смержить из своего терминала или перезапустить агента с TASKLESS_MERGE_GATE=off в окружении."
[ "${TASKLESS_MERGE_GATE:-on}" = "off" ] && exit 0

tool="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -n1 |
  sed 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//')"
cmd="$(printf '%s' "$cmd" | sed 's/\\n/;/g; s/\\"/"/g; s/\\\\/\\/g')"
[ -n "$cmd" ] || exit 0

printf '%s' "$cmd" | grep -qE '(^|[;&|(){])[[:space:]]*(sudo[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+(pr[[:space:]]+merge([[:space:]]|$)|api[[:space:]].*/merge([^A-Za-z0-9_]|$))' || exit 0

# Какой PR: ссылка, …/pulls/N/merge, номер после `merge`; иначе PR текущей ветки.
ref="$(printf '%s' "$cmd" | sed -n 's#.*\(https://github\.com/[^ "'"'"';&|]*/pull/[0-9][0-9]*\).*#\1#p' | head -n1)"
[ -n "$ref" ] || ref="$(printf '%s' "$cmd" | sed -n 's#.*pulls/\([0-9][0-9]*\)/merge.*#\1#p' | head -n1)"
[ -n "$ref" ] || ref="$(printf '%s' "$cmd" | sed -n 's/.*gh[[:space:]][[:space:]]*pr[[:space:]][[:space:]]*merge[[:space:]][[:space:]]*#\{0,1\}\([0-9][0-9]*\).*/\1/p' | head -n1)"
[ -n "$ref" ] || ref="$(gh pr view --json url --jq .url 2>/dev/null)"
[ -n "$ref" ] || deny "Не понял, какой PR мержится. Укажи его явно — gh pr merge <номер или ссылка>. $ESCAPE"

# Чужой репозиторий в команде (-R owner/repo, --repo owner/repo) — спрашиваем про него же.
repo="$(printf '%s' "$cmd" | sed -n 's/.*[[:space:]]-R[[:space:]][[:space:]]*\([^[:space:];&|]*\).*/\1/p' | head -n1)"
[ -n "$repo" ] || repo="$(printf '%s' "$cmd" | sed -n 's/.*[[:space:]]--repo[[:space:]=][[:space:]]*\([^[:space:];&|]*\).*/\1/p' | head -n1)"

gh_pr() {
  if [ -n "$repo" ]; then gh pr "$@" -R "$repo"; else gh pr "$@"; fi
}

JQ='.[] | .bucket + " " + .name'
scope="обязательные проверки"
checks="$(gh_pr checks "$ref" --required --json name,bucket --jq "$JQ" 2>&1)"
if printf '%s' "$checks" | grep -qi 'no required checks'; then
  scope="проверки PR (обязательных у репозитория нет)"
  checks="$(gh_pr checks "$ref" --json name,bucket --jq "$JQ" 2>&1)"
fi
# У PR нет ни одной проверки — ждать нечего.
if printf '%s' "$checks" | grep -qi 'no checks reported'; then
  checks=""
fi

# Строка, которая не похожа на «состояние имя», — это ошибка gh, а не проверка.
broken="$(printf '%s\n' "$checks" | grep -vE '^(pass|fail|pending|skipping|cancel) ' | grep -v '^[[:space:]]*$' | head -n1)"
[ -z "$broken" ] || deny "Не смог узнать проверки PR $ref: $broken. $ESCAPE"

failed="$(printf '%s\n' "$checks" | grep -E '^(fail|cancel) ' | sed 's/^[a-z]* //' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
[ -z "$failed" ] || deny "Мерж $ref отложен: упали $scope — $failed. Почини и дождись зелёного. $ESCAPE"

pending="$(printf '%s\n' "$checks" | grep -E '^pending ' | sed 's/^[a-z]* //' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
[ -z "$pending" ] || deny "Мерж $ref отложен: ещё идут $scope — $pending. Дождись, пока они позеленеют. $ESCAPE"

decision="$(gh_pr view "$ref" --json reviewDecision --jq .reviewDecision 2>/dev/null)"
case "$decision" in
  CHANGES_REQUESTED) deny "Мерж $ref отложен: в ревью запрошены правки. Сначала закрой замечания. $ESCAPE" ;;
  REVIEW_REQUIRED) deny "Мерж $ref отложен: защита ветки требует одобренного ревью, а его нет. $ESCAPE" ;;
esac

exit 0
