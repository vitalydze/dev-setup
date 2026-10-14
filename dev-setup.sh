#!/usr/bin/env bash
# dev-setup.sh — VPS для Claude Code Remote Control: Claude работает с проектами на сервере,
# а ты управляешь им с телефона или из claude.ai/code.
#
# Запуск на Ubuntu 22.04/24.04 (подробно — README.md):
#   curl -fsSLo dev-setup.sh https://raw.githubusercontent.com/vitalydze/dev-setup/main/dev-setup.sh
#   sudo bash dev-setup.sh
#
# Повторный запуск безопасен: сделанное пропускается. Подробный лог: /root/dev-setup.log
#
# Сначала установки (несколько минут, у каждой тикает таймер), потом действия с телефона,
# каждое на своём шаге: имена пользователей, вход в GitHub по коду, выбор проектов,
# вход в Claude по ссылке, SSH-ключ для IntelliJ. В конце — ключ для GitHub Actions.
#
# Что получится:
#   • пользователь для Claude (по умолчанию claude) — без пароля и SSH: Claude Code, gh,
#     Remote Control в tmux — окно на каждый проект, перезапуск при остановке и после перезагрузки
#   • пользователь для IntelliJ (по умолчанию work) — вход только по SSH-ключу, без sudo
#   • пользователь для GitHub Actions (по умолчанию github) — вход только по ключу, без sudo,
#     доступ к Docker для docker compose; ключ скрипт создаёт сам и печатает в конце
#   • claude и work в группах dev и docker; /srv/projects — их общая папка
#   • JDK 21, Maven, Docker; коммиты от владельца GitHub-аккаунта, подписи Claude нет

set -euo pipefail

CONF=/etc/dev-setup.conf   # имена пользователей, чтобы повторный запуск не спрашивал их снова
DEV_GROUP=dev
PROJECTS_DIR=/srv/projects
RC_START=/usr/local/bin/rc-start
LOG=/root/dev-setup.log
STEP=0 TOTAL=10 GH_LOGIN="" NEW_GITHUB_KEY=0
CLAUDE_USER="" WORK_USER="" GITHUB_USER="" CLAUDE_HOME="" CLAUDE_BIN=""

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT=(apt-get -y -q -o DPkg::Lock::Timeout=900)

# ── Вывод ──────────────────────────────────────────────────────────────────
G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' D=$'\033[2m' N=$'\033[0m'
say()  { printf '    %s\n' "$*"; }
warn() { printf '%s!!  %s%s\n' "$Y" "$*" "$N"; }
die()  { printf '%sXX  %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$G" "$STEP" "$TOTAL" "$1" "$N"; }
ask()  { printf '\a%s    ▶ Твоё действие: %s%s\n' "$Y" "$1" "$N"; }
dur()  { if (($1 >= 60)); then printf '%d мин %d с' $(($1 / 60)) $(($1 % 60)); else printf '%d с' "$1"; fi; }

# Долгая команда: в строке тикает таймер, вывод уходит в лог, при ошибке — хвост лога.
# run -k … — не выходить при ошибке, а вернуть 1.
run() {
  local keep=0; [[ $1 == -k ]] && { keep=1; shift; }
  local msg=$1 t0=$SECONDS pid hint="" from; shift
  echo "=== $(date '+%T') $msg" >>"$LOG"
  from=$(wc -l <"$LOG")
  ("$@") </dev/null >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS - t0 > 30)) && tail -n 2 "$LOG" | grep -qiE 'lock|блокировк'; then
      hint=" — ждёт автообновления Ubuntu"
    fi
    printf '\r    %s… %s%s\033[K' "$msg" "$(dur $((SECONDS - t0)))" "$hint"
    sleep 1
  done
  if wait "$pid"; then
    printf '\r    %s %s✓%s %s%s%s\033[K\n' "$msg" "$G" "$N" "$D" "$(dur $((SECONDS - t0)))" "$N"
    return 0
  fi
  printf '\r    %s %s✗%s\033[K\n' "$msg" "$R" "$N"
  tail -n +$((from + 1)) "$LOG" | tail -n 15 | sed 's/^/      /'
  ((keep)) && return 1
  die "Шаг не прошёл. Подробности: $LOG. Исправь причину и запусти скрипт снова."
}

# Команда от имени пользователя, с его HOME и login-окружением (PATH с ~/.local/bin).
as_user()      { local u=$1; shift; sudo -u "$u" -H bash -lc "cd ~ && $*"; }
as_claude()    { as_user "$CLAUDE_USER" "$@"; }
gh_as_claude() { sudo -u "$CLAUDE_USER" -H gh "$@"; }

# Правка JSON-файла claude через jq: jq_edit файл фильтр [аргументы jq]. Нет файла — создаётся.
jq_edit() {
  local f=$1 filter=$2; shift 2
  [[ -s $f ]] || echo '{}' >"$f"
  jq "$@" "$filter" "$f" >"$f.new" || { rm -f "$f.new"; die "$f — битый JSON, поправь руками"; }
  install -m 600 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$f.new" "$f"
  rm -f "$f.new"
}

# ── Установки ──────────────────────────────────────────────────────────────
preflight() {
  [[ $EUID -eq 0 ]] || die "Запусти через sudo: sudo bash dev-setup.sh"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || warn "Скрипт проверялся на Ubuntu, а тут ${PRETTY_NAME:-неизвестная ОС}"
  grep -qw avx /proc/cpuinfo \
    || die "Процессор не отдаёт AVX — Claude Code упадёт с 'Illegal instruction'. Попроси хостера сменить тип CPU на host (passthrough)."
  [[ -t 0 ]] || die "Нужен терминал: запускай sudo bash dev-setup.sh, не через curl | bash"
  echo "##### $(date '+%F %T') запуск" >>"$LOG"
  printf '%sСначала установки (несколько минут), потом действия с телефона — скрипт позовёт сам.%s\n' "$G" "$N"
}

install_packages() {
  "${APT[@]}" update
  "${APT[@]}" install curl ca-certificates git tmux acl jq cron openssh-client
  if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      >/etc/apt/sources.list.d/github-cli.list
    "${APT[@]}" update
  fi
  "${APT[@]}" install gh
  systemctl enable --now cron || true
}

install_java() {
  # сначала JDK: тогда maven не потянет default-jre (на 22.04 это OpenJDK 11)
  "${APT[@]}" install openjdk-21-jdk-headless
  "${APT[@]}" install maven
}

install_docker() {
  command -v docker >/dev/null && return 0   # уже установленный Docker не трогаем
  # по официальной инструкции docs.docker.com/engine/install/ubuntu
  local -a old
  mapfile -t old < <(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc \
    docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1)
  ((${#old[@]} == 0)) || "${APT[@]}" remove "${old[@]}"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  "${APT[@]}" update
  "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker || true
}

# ── Пользователи ───────────────────────────────────────────────────────────
setup_users() {
  local u
  # имена: при первом запуске спрашиваем, потом берём из $CONF
  if [[ -f $CONF ]]; then
    # shellcheck disable=SC1090
    . "$CONF"
  else
    ask "имена пользователей (Enter — оставить имя в скобках)"
    read -r -p "    Пользователь для Claude [claude]: " CLAUDE_USER || true
    read -r -p "    Пользователь для IntelliJ [work]: " WORK_USER || true
    read -r -p "    Пользователь для GitHub Actions [github]: " GITHUB_USER || true
  fi
  CLAUDE_USER=${CLAUDE_USER:-claude} WORK_USER=${WORK_USER:-work} GITHUB_USER=${GITHUB_USER:-github}
  CLAUDE_HOME=/home/$CLAUDE_USER
  CLAUDE_BIN=$CLAUDE_HOME/.local/bin/claude

  getent group "$DEV_GROUP" >/dev/null || groupadd "$DEV_GROUP"
  getent group docker >/dev/null || groupadd docker
  for u in "$CLAUDE_USER" "$WORK_USER" "$GITHUB_USER"; do
    if id "$u" &>/dev/null; then say "$u — уже есть"; else useradd -m -s /bin/bash "$u"; say "$u — создан"; fi
    chmod 750 "/home/$u"
  done
  # группа docker = права root на хосте: Claude управляет контейнерами, IntelliJ их видит,
  # GitHub Actions запускает docker compose
  usermod -aG "$DEV_GROUP,docker" "$CLAUDE_USER"
  usermod -aG "$DEV_GROUP,docker" "$WORK_USER"
  usermod -aG docker "$GITHUB_USER"
  # пароля нет, но вход по ключу разрешён ('*' вместо блокирующего '!')
  usermod -p '*' "$WORK_USER"
  usermod -p '*' "$GITHUB_USER"
  printf 'CLAUDE_USER=%s\nWORK_USER=%s\nGITHUB_USER=%s\n' "$CLAUDE_USER" "$WORK_USER" "$GITHUB_USER" >"$CONF"
  make_github_key

  # общая папка: всё новое внутри получает группу dev и права rw для неё
  mkdir -p "$PROJECTS_DIR"
  chown "root:$DEV_GROUP" "$PROJECTS_DIR"
  chmod 2775 "$PROJECTS_DIR"
  setfacl -d -m "g:$DEV_GROUP:rwX" "$PROJECTS_DIR"
  say "$PROJECTS_DIR — общая папка $CLAUDE_USER и $WORK_USER"

  # пользователя Claude по SSH не пускаем
  local conf=/etc/ssh/sshd_config.d/10-deny-$CLAUDE_USER.conf
  if [[ -d /etc/ssh/sshd_config.d && ! -f $conf ]]; then
    echo "DenyUsers $CLAUDE_USER" >"$conf"
    install -d -m 755 /run/sshd
    if sshd -t 2>>"$LOG"; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    else
      rm -f "$conf"
      warn "sshd -t ругается — запрет SSH для $CLAUDE_USER не поставил, SSH не тронут"
    fi
  fi
}

# Ключ для GitHub Actions создаётся один раз: публичная часть — в authorized_keys,
# приватную скрипт печатает в конце, чтобы положить её в секреты репозитория.
make_github_key() {
  local dir=/home/$GITHUB_USER/.ssh
  [[ -f $dir/deploy_key ]] && return 0
  install -d -m 700 -o "$GITHUB_USER" -g "$GITHUB_USER" "$dir"
  ssh-keygen -q -t ed25519 -N "" -C "github-actions@$(hostname)" -f "$dir/deploy_key"
  cat "$dir/deploy_key.pub" >>"$dir/authorized_keys"
  chown "$GITHUB_USER:$GITHUB_USER" "$dir/deploy_key" "$dir/deploy_key.pub" "$dir/authorized_keys"
  chmod 600 "$dir/authorized_keys"
  NEW_GITHUB_KEY=1
}

install_claude() {
  [[ -x $CLAUDE_BIN ]] && return 0
  # ~/.local/bin заранее — тогда login-shell сразу видит его в PATH и инсталлер не ругается
  as_claude "mkdir -p ~/.local/bin && curl -fsSL https://claude.ai/install.sh | bash"
}

# ── Действия с телефона ────────────────────────────────────────────────────
login_github() {
  if gh_as_claude auth status </dev/null &>/dev/null; then
    say "Уже вошёл"
  else
    ask "вход в GitHub"
    say "Открой https://github.com/login/device, введи код из строки ниже и нажми Authorize."
    say "Скрипт ждёт подтверждения и сам пойдёт дальше."
    local t
    until gh_as_claude auth login -h github.com -p https --web -s project,workflow </dev/null; do
      read -r -s -p "    Вход не прошёл. Enter — ещё раз по коду; или вставь classic-токен (ввод скрыт): " t \
        || die "Ввод оборвался — запусти скрипт снова"
      echo
      [[ -n $t ]] || continue
      printf '%s\n' "$t" | gh_as_claude auth login -h github.com -p https --with-token && break
      warn "Токен не принят: нужен classic с правами repo, read:org, project, workflow"
    done
  fi
  gh_as_claude auth setup-git </dev/null

  local scopes s
  scopes=$(gh_as_claude api -i user </dev/null 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
  for s in repo read:org project workflow; do
    [[ ", $scopes," == *", $s,"* ]] || warn "У входа в GitHub нет права $s — запусти: sudo -u $CLAUDE_USER -H gh auth refresh -s $s"
  done
  [[ ", $scopes," != *", delete_repo,"* ]] \
    || warn "У входа в GitHub есть право удалять репозитории. Выйди: sudo -u $CLAUDE_USER -H gh auth logout — и запусти скрипт снова"

  # коммиты — от владельца GitHub-аккаунта с noreply-адресом GitHub; уже заданный email не трогаем
  local name id email u
  GH_LOGIN=$(gh_as_claude api user --jq .login </dev/null)
  name=$(gh_as_claude api user --jq '.name // .login' </dev/null)
  id=$(gh_as_claude api user --jq .id </dev/null)
  [[ -n $GH_LOGIN && -n $id ]] || die "Не смог получить профиль GitHub"
  email="$id+$GH_LOGIN@users.noreply.github.com"
  for u in "$CLAUDE_USER" "$WORK_USER"; do
    if [[ -z $(sudo -u "$u" -H git config --global user.email || true) ]]; then
      sudo -u "$u" -H git config --global user.name "$name"
      sudo -u "$u" -H git config --global user.email "$email"
    fi
    sudo -u "$u" -H git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*' \
      || sudo -u "$u" -H git config --global --add safe.directory '*'
  done
  say "GitHub: $GH_LOGIN, коммиты от $(sudo -u "$CLAUDE_USER" -H git config --global user.name) <$(sudo -u "$CLAUDE_USER" -H git config --global user.email)>"
}

# Показывает 30 недавних репозиториев аккаунта; выбранные номерами скачивает в /srv/projects.
choose_projects() {
  local -a repos nums
  local n name dir
  mapfile -t repos < <(gh_as_claude api 'user/repos?sort=pushed&per_page=30&affiliation=owner,collaborator,organization_member' \
    --jq '.[].full_name' </dev/null 2>>"$LOG" || true)
  ask "какие проекты скачать"
  ((${#repos[@]})) || warn "Список репозиториев не получил. Подробности: $LOG"
  for n in "${!repos[@]}"; do
    name=${repos[n]}
    [[ ! -d $PROJECTS_DIR/${name##*/}/.git ]] || name="$name  ✓ скачан"
    printf '    %2d) %s\n' $((n + 1)) "$name"
  done
  read -r -a nums -p "    Номера через пробел (Enter — пропустить): " || true
  for n in "${nums[@]}"; do
    if ! [[ $n =~ ^[0-9]+$ ]] || ((10#$n < 1 || 10#$n > ${#repos[@]})); then
      warn "Нет номера $n — пропускаю"
      continue
    fi
    name=${repos[10#$n - 1]}
    dir=$PROJECTS_DIR/${name##*/}
    if [[ -d $dir/.git ]]; then say "$name — уже скачан"; continue; fi
    run -k "скачиваю $name" gh_as_claude repo clone "$name" "$dir" || warn "$name не скачался"
  done
}

login_claude() {
  # подписи Claude в коммитах и PR нет — Claude нигде не фигурирует в репозиториях
  install -d -m 700 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$CLAUDE_HOME/.claude"
  jq_edit "$CLAUDE_HOME/.claude/settings.json" '.attribution = {"commit": "", "pr": "", "sessionUrl": false}'

  if as_claude "$CLAUDE_BIN auth status" &>/dev/null; then say "Уже вошёл"; return 0; fi
  ask "вход в Claude"
  say "Ниже появится ссылка: открой её на телефоне и войди. Скопируй код, вставь сюда и нажми Enter."
  until as_claude "$CLAUDE_BIN auth login"; as_claude "$CLAUDE_BIN auth status" &>/dev/null; do
    read -r -p "    Вход не прошёл. Enter — ещё раз: " || die "Ввод оборвался — запусти скрипт снова"
  done
  say "Ок"
}

add_work_key() {
  local f=/home/$WORK_USER/.ssh/authorized_keys key=""
  if [[ -s $f ]]; then say "Уже есть"; return 0; fi
  ask "ключ для IntelliJ (Enter — пропустить)"
  say "На рабочем компьютере выполни: cat ~/.ssh/id_ed25519.pub"
  say "Нет файла — сначала ssh-keygen -t ed25519 (на Overwrite отвечай n)."
  say "Строку ssh-ed25519 AAAA… перекинь на телефон и вставь сюда."
  while true; do
    read -r -p "    Ключ: " key || true
    [[ -z $key ]] && break
    ssh-keygen -l -f - <<<"$key" &>/dev/null && break
    warn "Это не публичный SSH-ключ (ожидается строка ssh-ed25519 AAAA…) — ещё раз"
  done
  if [[ -z $key ]]; then
    say "Пропущено. Добавить потом — выполни, вставь строку, Enter, затем Ctrl+D:"
    say "sudo -u $WORK_USER -H sh -c 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'"
    return 0
  fi
  install -d -m 700 -o "$WORK_USER" -g "$WORK_USER" "/home/$WORK_USER/.ssh"
  printf '%s\n' "$key" >>"$f"
  chown "$WORK_USER:$WORK_USER" "$f"
  chmod 600 "$f"
  say "Добавлен. Вход с рабочего компьютера: ssh $WORK_USER@<сервер>"
}

# ── Remote Control ─────────────────────────────────────────────────────────
write_rc_start() {
  cat >"$RC_START" <<'EOF'
#!/usr/bin/env bash
# rc-start — держит Claude Code Remote Control запущенным. Вызывается из crontab пользователя Claude:
# при загрузке сервера и каждые 5 минут. tmux-сессия rc, окно на каждый git-репо в /srv/projects:
# недостающее создаётся, работающее не трогается. В окне remote-control крутится в цикле:
# остановился (Ctrl+C, обрыв сети, сбой) — через 15 с запускается снова.
# Сессию rc, запущенную вручную, не трогает: два remote-control в одной папке нельзя.
set -euo pipefail
RC_USER=__RC_USER__
[[ $(id -un) == "$RC_USER" ]] || exec sudo -iu "$RC_USER" "$0" "$@"
# у cron окружение минимальное — задаём сами
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="${LANG:-C.UTF-8}"
exec 9>"/tmp/rc-start-$(id -u).lock"
flock -n 9 || exit 0

if tmux has-session -t rc 2>/dev/null && [[ $(tmux show-options -t rc -qv @rc_managed) != 1 ]]; then
  echo "$(date '+%F %T') сессия rc запущена вручную — не трогаю"
  exit 0
fi

for dir in /srv/projects/*/; do
  [[ -d ${dir}.git ]] || continue
  name=$(basename "$dir")
  cmd="while true; do \$HOME/.local/bin/claude remote-control --spawn worktree --remote-control-session-name-prefix $name; echo; echo 'Remote Control остановлен, перезапуск через 15 с'; sleep 15; done"
  if ! tmux has-session -t rc 2>/dev/null; then
    # 9>&- — иначе запущенный здесь tmux-сервер унаследует блокировку и будет держать её вечно
    tmux new-session -d -s rc -n "$name" -c "$dir" "$cmd" 9>&-
    tmux set-option -t rc @rc_managed 1
  elif grep -qxF "$name" <<<"$(tmux list-windows -t rc -F '#{window_name}')"; then
    continue
  else
    tmux new-window -d -t rc -n "$name" -c "$dir" "$cmd"
  fi
  echo "$(date '+%F %T') запущен Remote Control: $name"
done
EOF
  sed -i "s/__RC_USER__/$CLAUDE_USER/" "$RC_START"
  chmod 755 "$RC_START"
  local cron
  cron=$(crontab -u "$CLAUDE_USER" -l 2>/dev/null || true)
  grep -qF "$RC_START" <<<"$cron" || {
    [[ -n $cron ]] && printf '%s\n' "$cron"
    echo "@reboot $RC_START >> \$HOME/rc-start.log 2>&1"
    echo "*/5 * * * * $RC_START >> \$HOME/rc-start.log 2>&1"
  } | crontab -u "$CLAUDE_USER" -
}

# Доверие к папкам проектов и согласие на Remote Control записываем сразу,
# чтобы claude remote-control не задавал эти вопросы в tmux.
trust_projects() {
  local dir
  for dir in "$PROJECTS_DIR"/*/; do
    [[ -d ${dir}.git ]] || continue
    # shellcheck disable=SC2016
    jq_edit "$CLAUDE_HOME/.claude.json" '.remoteDialogSeen = true | .projects[$p].hasTrustDialogAccepted = true' --arg p "${dir%/}"
  done
}

rc_running() { as_claude "tmux has-session -t rc" &>/dev/null; }
rc_managed() { [[ $(as_claude "tmux show-options -t rc -qv @rc_managed" 2>/dev/null) == 1 ]]; }

# Видит ли запущенный tmux Docker? Группы процесс получает при старте: tmux, запущенный
# до добавления пользователя в группу docker, Docker не видит.
rc_has_docker() {
  local gid pid
  gid=$(getent group docker | cut -d: -f3) && [[ -n $gid ]] || return 1
  pid=$(as_claude "tmux display-message -p -t rc '#{pid}'" 2>/dev/null) && [[ -r /proc/$pid/status ]] || return 1
  [[ " $(awk '/^Groups:/{$1=""; print}' "/proc/$pid/status") " == *" $gid "* ]]
}

# Остановить как руками: Ctrl+C в каждом окне, дождаться выхода remote-control, закрыть tmux.
rc_stop() {
  local w pid busy
  for w in $(as_claude "tmux list-windows -t rc -F '#{window_id}'"); do as_claude "tmux send-keys -t '$w' C-c"; done
  for _ in $(seq 20); do
    busy=0
    for pid in $(as_claude "tmux list-panes -s -t rc -F '#{pane_pid}'" 2>/dev/null); do
      [[ -z $(pgrep -l -P "$pid" | awk '$2 != "sleep"') ]] || busy=1
    done
    ((busy)) || break
    sleep 1
  done
  as_claude "tmux kill-server" &>/dev/null || true
}

# 20 с наблюдаем за окнами: вопрос, ошибка или остановка — провал, иначе Remote Control работает.
rc_wait() {
  local out
  for _ in $(seq 20); do
    sleep 1
    out=$(as_claude "for w in \$(tmux list-windows -t rc -F '#{window_id}'); do tmux capture-pane -p -t \$w; done" 2>/dev/null || true)
    if grep -qE 'остановлен|did not start|Error|error:|\(y/n\)|\[y/N\]' <<<"$out"; then
      grep -v '^$' <<<"$out" | tail -n 12
      return 1
    fi
  done
  rc_running
}

start_rc() {
  write_rc_start
  if ! compgen -G "$PROJECTS_DIR/*/.git" >/dev/null; then
    say "Проектов нет — Remote Control запустится сам, когда в $PROJECTS_DIR появится репозиторий"
    return 0
  fi
  trust_projects
  if rc_running && ! { rc_managed && rc_has_docker; }; then
    say "Remote Control был запущен вручную или без доступа к Docker — перезапускаю"
    rc_stop
  fi
  "$RC_START" >>"$LOG" 2>&1 || true
  if run -k "запускаю Remote Control" rc_wait; then
    say "Работает. Перезапуск при остановке и после перезагрузки — автоматически."
  else
    warn "Remote Control не поднялся. Его экран: sudo -iu $CLAUDE_USER tmux attach -t rc — если там вопрос, ответь y (выйти: Ctrl+B, затем d)"
  fi
}

remove_root_claude() {
  [[ -e /root/.local/bin/claude || -e /root/.local/share/claude || -e /root/.claude || -e /root/.claude.json ]] || return 0
  local a=""
  ask "старый Claude под root"
  read -r -p "    Найден Claude под root. Удалить вместе с его логином и настройками? [y/N] " a || true
  [[ $a == [yYдД]* ]] || { say "Оставляю"; return 0; }
  [[ -x /root/.local/bin/claude ]] && { /root/.local/bin/claude auth logout &>/dev/null || true; }
  rm -rf /root/.local/bin/claude /root/.local/share/claude /root/.local/state/claude \
    /root/.cache/claude /root/.claude /root/.claude.json
  say "Удалён. Хвосты PATH от прошлых установок: grep -n claude /root/.bashrc"
}

summary() {
  printf '\n%s━━ Готово ━━%s\n' "$G" "$N"
  say "Телефон: Claude → Code → сессия <проект>-… с зелёной точкой"
  say "$CLAUDE_USER: без пароля и SSH. Зайти: sudo -iu $CLAUDE_USER (выйти: exit)"
  say "$WORK_USER: без пароля и sudo, вход по ключу: ssh $WORK_USER@<сервер>. Отсюда: sudo -iu $WORK_USER"
  say "$GITHUB_USER: без пароля и sudo, вход по ключу, доступ к Docker — для GitHub Actions"
  say "Экран Remote Control: sudo -iu $CLAUDE_USER tmux attach -t rc (выйти: Ctrl+B, затем d)"
  say "Ещё проекты: запусти скрипт снова. Лог установки: $LOG"
}

# Приватный ключ для GitHub Actions — последним, чтобы его было удобно скопировать.
show_github_key() {
  local key=/home/$GITHUB_USER/.ssh/deploy_key
  if ((NEW_GITHUB_KEY == 0)); then
    say "Ключ для GitHub Actions создан раньше. Показать снова: sudo cat $key"
    return 0
  fi
  ask "ключ для GitHub Actions"
  say "Скопируй всё между линиями, вместе со строками BEGIN и END, в секрет репозитория:"
  say "репозиторий на GitHub → Settings → Secrets and variables → Actions → New repository secret."
  say "Пользователь для подключения: $GITHUB_USER. Показать ключ снова: sudo cat $key"
  echo "────────────────────────────────────────────────────────"
  cat "$key"
  echo "────────────────────────────────────────────────────────"
}

main() {
  cd /
  preflight
  step "Пакеты: git, tmux, gh";         run "ставлю" install_packages
  step "JDK 21 и Maven";                run "ставлю" install_java
  [[ $(readlink -f "$(command -v java)") == *java-21* ]] \
    || warn "java по умолчанию не 21 — выбери: update-alternatives --config java"
  step "Docker";                        run "ставлю" install_docker
  step "Пользователи и папка проектов"; setup_users
  step "Claude Code";                   run "ставлю" install_claude
  [[ -x $CLAUDE_BIN ]] || die "Claude Code не установился. Подробности: $LOG"
  step "Вход в GitHub";                 login_github
  step "Проекты";                       choose_projects
  step "Вход в Claude";                 login_claude
  step "SSH-ключ для $WORK_USER";       add_work_key
  step "Remote Control";                start_rc
  remove_root_claude
  summary
  show_github_key
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
