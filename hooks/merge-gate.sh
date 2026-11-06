#!/bin/sh
# Гейт мержа (PreToolUse на Bash): `gh pr merge` из-под агента не проходит, пока проверки
# PR не зелёные. Смотрим обязательные проверки; если у репозитория их нет (защита веток не
# настроена) — все проверки PR. Вердикт ревью требуем, только если его требует защита ветки
# проекта: тогда GitHub отдаёт reviewDecision, и без APPROVED мержить нельзя.
#
# «Проверок нет» (gh отвечает no checks reported — это все проверки PR, не только
# обязательные) почти всегда значит «ещё не появились»: новый пуш отменяет старый прогон,
# и около минуты на коммите нет ни одного чека. Тогда смотрим Actions. Прогоны на этом
# коммите уже есть — ждём, пока проверки появятся. Прогонов нет и в репозитории нет ни
# одного workflow — CI нет, пропускаем. Прогонов нет, workflow есть: коммиту меньше
# 10 минут — ждём (тот же запас, что NO_CI_GRACE_MS у демона роя); старше — пропускаем,
# workflow с фильтром по путям мог законно не запуститься. Возраст коммита считает jq
# самого gh, без date: хук работает и на GNU, и на macOS.
#
# Хук читает текст команды, поэтому ловит `gh pr merge` и прямой вызов merge-эндпоинта через
# `gh api` в позиции команды — в том числе внутри составной (`cd x && gh pr merge 12`), — но
# не упоминание этих слов в тексте (сообщение коммита про `gh pr merge` мерж не делает).
#
# Не ответил gh — запрет, на любом вызове, включая решение ревью: гейт, который при
# своей поломке пропускает мерж, бесполезен. Пустое reviewDecision законно — обязательного
# ревью у ветки нет. Снять гейт может только человек (см. ESCAPE). В сеть ходит только
# через gh, в файлы не пишет.

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

# -R/--repo передаём в gh pr: для номера PR это репозиторий. Для ссылки gh сам -R
# не слушает, поэтому репозиторий для Actions ниже берём из ссылки gh pr view, не из -R.
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
# no checks reported — все проверки PR, не «нет обязательных». gh 2.88 пишет это
# уже на вызов с --required, если проверок нет совсем. Не пропускаем сразу:
# в репозитории с CI это ожидание. Прогоны Actions на HEAD уже есть — запрет.
# Прогонов нет и workflow нет — пропуск (CI у репозитория нет). Прогонов нет, workflow
# есть, коммит моложе 10 минут — запрет; старше — пропуск. Любой сбой gh здесь — запрет.
# Репозиторий — ссылка, которую вернул gh pr view: для номера он уже учёл -R,
# для ссылки gh сам -R не слушает. Повторно -R не читаем, иначе чужой --repo
# рядом со ссылкой смотрит не тот репозиторий и пропускает мерж.
if printf '%s' "$checks" | grep -qi 'no checks reported' && ! printf '%s' "$checks" | grep -qi 'no required checks'; then
  checks=""
  # 10 минут — NO_CI_GRACE_MS демона роя. Моложе этого CI мог ещё не завести джобы.
  GRACE_S=600
  headmeta="$(gh_pr view "$ref" --json headRefOid,url --jq '[.headRefOid, .url] | join(" ")' 2>&1)" || deny "Не смог узнать HEAD PR $ref: $headmeta. $ESCAPE"
  sha="${headmeta%% *}"
  prurl="${headmeta#* }"
  case "$sha" in
    *[!0-9a-fA-F]*) deny "Не смог узнать HEAD PR $ref: $headmeta. $ESCAPE" ;;
  esac
  [ "${#sha}" -ge 7 ] || deny "Не смог узнать HEAD PR $ref: $headmeta. $ESCAPE"
  sha7="$(printf '%.7s' "$sha")"

  src="$prurl"
  case "$src" in
    *github.com/*)
      nwo="$(printf '%s' "$src" | sed -n 's#.*github\.com/\([^/][^/]*/[^/][^/]*\).*#\1#p')"
      nwo="${nwo%.git}"
      ;;
    *)
      nwo="${src%/}"
      nwo="${nwo%.git}"
      ;;
  esac
  case "$nwo" in
    [A-Za-z0-9._-][A-Za-z0-9._-]*/[A-Za-z0-9._-][A-Za-z0-9._-]*) ;;
    *) deny "Не смог узнать репозиторий PR $ref: ${src}. $ESCAPE" ;;
  esac

  runs="$(gh api "repos/${nwo}/actions/runs?head_sha=${sha}&per_page=1" --jq .total_count 2>&1)" || deny "Не смог узнать прогоны Actions на коммите ${sha7}: $runs. $ESCAPE"
  case "$runs" in
    ""|*[!0-9]*) deny "Не смог узнать прогоны Actions на коммите ${sha7}: $runs. $ESCAPE" ;;
  esac
  [ "$runs" -gt 0 ] && deny "CI на коммите ${sha7} уже заведён, проверки ещё не появились. Подожди. $ESCAPE"

  flows="$(gh api "repos/${nwo}/actions/workflows" --jq .total_count 2>&1)" || deny "Не смог узнать workflow репозитория ${nwo}: $flows. $ESCAPE"
  case "$flows" in
    ""|*[!0-9]*) deny "Не смог узнать workflow репозитория ${nwo}: $flows. $ESCAPE" ;;
  esac
  if [ "$flows" -gt 0 ]; then
    age="$(gh api "repos/${nwo}/commits/${sha}" --jq '(now - (.commit.committer.date | fromdateiso8601)) | floor' 2>&1)" || deny "Не смог узнать возраст коммита ${sha7}: $age. $ESCAPE"
    case "$age" in
      ""|*[!0-9]*) deny "Не смог узнать возраст коммита ${sha7}: $age. $ESCAPE" ;;
    esac
    [ "$age" -lt "$GRACE_S" ] && deny "Проверок на коммите пока нет: CI мог ещё не завестись (новый пуш отменяет старый прогон). Подожди пару минут. $ESCAPE"
  fi
fi

# Строка, которая не похожа на «состояние имя», — это ошибка gh, а не проверка.
broken="$(printf '%s\n' "$checks" | grep -vE '^(pass|fail|pending|skipping|cancel) ' | grep -v '^[[:space:]]*$' | head -n1)"
[ -z "$broken" ] || deny "Не смог узнать проверки PR $ref: $broken. $ESCAPE"

failed="$(printf '%s\n' "$checks" | grep -E '^(fail|cancel) ' | sed 's/^[a-z]* //' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
[ -z "$failed" ] || deny "Мерж $ref отложен: упали $scope — $failed. Почини и дождись зелёного. $ESCAPE"

pending="$(printf '%s\n' "$checks" | grep -E '^pending ' | sed 's/^[a-z]* //' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
[ -z "$pending" ] || deny "Мерж $ref отложен: ещё идут $scope — $pending. Дождись, пока они позеленеют. $ESCAPE"

# Пустой ответ законен: защита ветки ревью не требует. Ненулевой код gh — запрет.
decision="$(gh_pr view "$ref" --json reviewDecision --jq .reviewDecision 2>/dev/null)" || deny "Не смог прочитать решение ревью PR $ref — повтори позже. $ESCAPE"
case "$decision" in
  CHANGES_REQUESTED) deny "Мерж $ref отложен: в ревью запрошены правки. Сначала закрой замечания. $ESCAPE" ;;
  REVIEW_REQUIRED) deny "Мерж $ref отложен: защита ветки требует одобренного ревью, а его нет. $ESCAPE" ;;
esac

exit 0
