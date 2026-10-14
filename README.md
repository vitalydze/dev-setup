# dev-setup

Сервер для Claude Code Remote Control: Claude работает с твоими проектами на VPS (виртуальном сервере), а ты управляешь им с телефона или из claude.ai/code.

```
телефон, claude.ai/code --Remote Control--> Claude на сервере --> проекты в /srv/projects
IntelliJ на компьютере  --SSH-------------> те же проекты
GitHub Actions          --SSH-------------> docker compose в /srv/deploy
```

## Что получится

- **Пользователь для Claude** (по умолчанию `claude`): без пароля, вход по SSH закрыт. Здесь Claude Code, GitHub CLI и Remote Control: по окну tmux на каждый проект, перезапуск при сбое и после перезагрузки сервера.
- **Пользователь для IntelliJ** (по умолчанию `work`): вход только по SSH-ключу, без sudo.
- **Пользователь для GitHub Actions** (по умолчанию `github`): вход только по ключу, без sudo, есть доступ к Docker для `docker compose up` и `down`. Ключ скрипт создаёт сам и печатает в конце.
- Общая папка проектов `/srv/projects`: пользователи Claude и IntelliJ правят файлы друг друга.
- Папка деплоя `/srv/deploy`: GitHub Actions выкладывает сюда проекты, в workflow укажи путь `/srv/deploy/<проект>`. Пишет только пользователь GitHub Actions, остальные читают.
- JDK 21, Maven, Docker.
- Коммиты от имени владельца GitHub-аккаунта, без подписи Claude.

## Что нужно

- VPS с Ubuntu 22.04 или 24.04, доступ root или sudo. Процессор должен отдавать AVX, иначе Claude Code не запустится: если скрипт об этом скажет, попроси хостера сменить тип CPU на host.
- SSH-клиент, например Termius на телефоне.
- Аккаунт GitHub.
- Подписка Claude Pro, Max, Team или Enterprise: с API-ключом Remote Control не работает.

## Перед запуском с iPhone

- **Автоблокировка → Никогда** (Настройки → Экран и яркость) на время установки. В фоне iOS останавливает Termius через 20–30 секунд, и скрипт обрывается. В режиме энергосбережения пункт недоступен — выключи его.
- **Войди в GitHub и claude.ai в браузере телефона.** Тогда вход по коду займёт секунды, и Termius не успеет уснуть.

## Установка

Зайди на сервер по SSH (в Termius — тап по хосту) и выполни по очереди:

```
curl -fsSLo dev-setup.sh https://raw.githubusercontent.com/vitalydze/dev-setup/main/dev-setup.sh
```

```
sudo bash dev-setup.sh
```

Первые 5–10 минут идут установки, у каждой тикает таймер. Потом скрипт сам позовёт (▶ Твоё действие):

1. **Имена пользователей.** Enter оставляет `claude`, `work` и `github`.
2. **Вход в GitHub.** Скрипт покажет код: открой github.com/login/device, введи код и нажми Authorize.
3. **Проекты.** Скрипт покажет твои репозитории — введи номера через пробел.
4. **Вход в Claude.** Открой ссылку, войди, скопируй код, вставь его в Termius и нажми Enter.
5. **SSH-ключ для IntelliJ.** Вставь строку `ssh-ed25519 AAAA…` с рабочего компьютера или пропусти Enter.
6. **Ключ для GitHub Actions.** В конце скрипт напечатает приватный ключ. Скопируй его целиком, со строками BEGIN и END, в секрет репозитория: Settings → Secrets and variables → Actions → New repository secret. Именно в секрет, а не в переменную: секреты GitHub шифрует и скрывает в логах.

## Проверка

Приложение Claude → Code → сессия `<проект>-…` с зелёной точкой. Напиши в ней: «выполни pwd, git branch --show-current, docker ps и mvn -v».

## Если оборвалось или не работает

- **Сессия оборвалась** — зайди снова и запусти `sudo bash dev-setup.sh`. Сделанное пропускается, имена пользователей запомнены.
- **Ошибка на шаге** — скрипт показывает хвост лога. Весь лог: `/root/dev-setup.log`.
- **Вход в GitHub по коду не проходит** — Enter повторяет попытку. Запасной путь — вставить classic-токен: github.com/settings/tokens, права `repo`, `read:org`, `project`, `workflow`. Fine-grained токен не подойдёт: он не работает с личными GitHub Projects.
- **Remote Control не поднялся** — открой его экран: `sudo -iu claude tmux attach -t rc`. Если там вопрос, ответь `y`. Выйти из tmux: `Ctrl+B`, затем `d`.
- **Claude пишет `permission denied … docker.sock`** — запусти `sudo bash dev-setup.sh` ещё раз: он перезапустит Remote Control с доступом к Docker.

## Команды

Вместо `claude` и `github` подставь свои имена, если менял их.

| Команда | Что делает |
|---|---|
| `sudo bash dev-setup.sh` | установка, повторный запуск, скачать ещё проекты |
| `sudo -iu claude` | зайти под пользователем Claude (выйти: `exit`) |
| `sudo -iu claude tmux attach -t rc` | экран Remote Control: окно на каждый проект, переключение `Ctrl+B`, затем `n` |
| `sudo cat /home/github/.ssh/deploy_key` | показать ключ для GitHub Actions ещё раз |
| первая команда из «Установки» | скачать новую версию скрипта |

## IntelliJ

Ключ можно добавить позже. На рабочем компьютере возьми строку из `cat ~/.ssh/id_ed25519.pub` (нет файла — создай ключ: `ssh-keygen -t ed25519`). На сервере выполни команду ниже (вместо `work` — своё имя, если менял), вставь строку, нажми Enter, затем `Ctrl+D`:

```
sudo -u work -H sh -c 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'
```

- **Gateway (Remote Development):** IntelliJ работает на сервере под `work`, Docker подключается как «Unix socket».
- **Локальная IntelliJ Ultimate:** Settings → Build, Execution, Deployment → Docker → + → SSH → `work@<сервер>`.

## Где что лежит

- `/etc/dev-setup.conf` — имена пользователей
- `/root/dev-setup.log` — лог установки
- `/srv/projects` — проекты
- `/srv/deploy` — проекты, выложенные GitHub Actions
- `/home/github/.ssh/deploy_key` — приватный ключ для GitHub Actions, его публичная часть — в `authorized_keys` рядом
- `/usr/local/bin/rc-start` — сторож Remote Control: запускается при загрузке и каждые 5 минут, лог — `~/rc-start.log` пользователя Claude

## Безопасность

- Пользователи Claude, IntelliJ и GitHub Actions в группе docker, а это фактически права root на сервере. Так задумано: Claude управляет контейнерами, IntelliJ их видит, GitHub Actions запускает `docker compose`.
- Поэтому ключ в секретах GitHub тоже даёт права root на сервере — любому, кто может менять workflow в этом репозитории.
- Пользователь Claude не может войти по SSH и не имеет sudo.
- Вход в GitHub по коду: права `repo`, `read:org`, `gist`, `project`, `workflow`, без удаления репозиториев. Отозвать: github.com/settings/applications → GitHub CLI (отзывается сразу на всех устройствах).
- Подписи Claude в коммитах и запросах на слияние отключены.
