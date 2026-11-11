# new-server — bootstrap Debian-сервера

Оркестратор: `new-server.sh`. Только Debian 11+.
Запуск: `bash startinstall.sh` (тянет `new-server.sh` с GitHub) или локально `./new-server.sh`.

Одной командой на чистом сервере (скопировать в SSH):
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hummer74/new-server/main/startinstall.sh)"
```
Если нет `curl` (минимальный образ — есть только `wget`):
```bash
wget -qO /root/new-server.sh https://raw.githubusercontent.com/hummer74/new-server/main/new-server.sh && bash /root/new-server.sh
```

Что делает: APT → full-upgrade → swap 512 → hostname → сеть (IPv6 всегда включён,
echo-проbing выключен) → SSH `22,24940` (ключи+пароль) → пакеты → локаль `ru_RU` →
fail2ban `30d/1440m/4` → unattended-upgrades (reboot в `00:01`) → пользователь `opossum` →
UFW (`deny incoming`, `allow` на SSH, IPv6 on) → reverse-туннель на OpenWrt →
опционально Tailscale Exit Node (вопрос `y/N`, SNAT на Outbound IP при split) → cron → reboot.

Split-сеть (`INBOUND/OUTBOUND`, без хардкода адресов): авто-детект → `/root/.network_config`.

## Проверка перед боевым прогоном

Выполни на любом Debian до запуска:
```bash
bash -n new-server.sh && echo SYNTAX-OK
shellcheck -S warning new-server.sh auto-update.sh 2>&1 | head -n 40
ip -4 -o addr show scope global   # сверить: список должен показать оба IP для split
```

## Остальные скрипты

- `tailscale-insall.sh`, `tailscale-exit-node.sh`, `tailscale-uninsall.sh` — Tailscale.
- `ssh2router.sh` (в архиве) — автономный reverse-туннель (дубль функции из `new-server.sh`).
- `allow-fleet.sh`, `unban-fleet.sh` — операторские: allowlist подсети/хостов и разбан в fail2ban (гоняются с управляющей машины).
- `ip-check.sh`, `ipregion.sh` — диагностика сети/гео IP.
- `add-crontab.sh`, `auto-update.sh`, `create-swap512.sh`,
  `right.sh`, `set_locale.sh` — точечные утилиты.
- `f2b-install.sh` (в архиве) — автономный fail2ban.
- `domain.txt` — домены для TLS-маскировки.
- `setarc.7z` — приватный архив (`~/.ssh`, пароли). Не коммитить изменения без нужды.
