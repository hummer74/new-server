# new-server — bootstrap Debian-сервера

Оркестратор: `new-server.sh` (+ `config.env` рядом). Только Debian 11+.
Запуск: `bash startinstall.sh` (тянет `new-server.sh` с GitHub) или локально `./new-server.sh`.

Что делает: APT → full-upgrade → swap 512 → hostname → сеть (IPv6 всегда включён,
echo-проbing выключен) → SSH `22,24940` (ключи+пароль) → пакеты → локаль `ru_RU` →
fail2ban `30d/1440m/4` → unattended-upgrades (reboot в `00:01`) → пользователь `opossum` →
UFW (`deny incoming`, `limit` на SSH, IPv6 on) → reverse-туннель на OpenWrt →
опционально Tailscale Exit Node (вопрос `y/N`, SNAT на Outbound IP при split) → cron → reboot.

Split-сеть (`INBOUND/OUTBOUND`, без хардкода адресов): авто-детект → `/root/.network_config`.

## Проверка перед боевым прогоном

Выполни на любом Debian до запуска:
```bash
bash -n new-server.sh && bash -n config.env && echo SYNTAX-OK
shellcheck -S warning new-server.sh ssh2router.sh auto-update.sh 2>&1 | head -n 40
ip -4 -o addr show scope global   # сверить: список должен показать оба IP для split
```

## Остальные скрипты

- `head-tail/zai-tunnel-*.sh` — WireGuard HEAD↔TAIL.
- `tailscale-insall.sh`, `tailscale-exit-node.sh`, `tailscale-uninsall.sh` — Tailscale.
- `snikket-*.sh` — XMPP Snikket в Docker.
- `ssh2router.sh` — автономный reverse-туннель (дубль функции из `new-server.sh`).
- `ip-check.sh`, `ipregion.sh` — диагностика сети/гео IP.
- `add-crontab.sh`, `auto-update.sh`, `f2b-install.sh`, `create-swap512.sh`,
  `right.sh`, `set_locale.sh` — точечные утилиты.
- `domain.txt` — домены для TLS-маскировки.
- `setup.7z` — приватный архив (`~/.ssh`, пароли). Не коммитить изменения без нужды.
