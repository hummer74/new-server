# new-server — bootstrap Debian-сервера

Оркестратор: `new-server.sh` (+ `config.env` рядом). Только Debian 11+.
Запуск: `bash startinstall.sh` (тянет `new-server.sh` с GitHub) или локально `./new-server.sh`.

Что делает: APT → full-upgrade → swap 512 → hostname → сеть (IPv6 всегда включён,
echo-проbing выключен) → SSH `22,24940` (ключи+пароль) → пакеты → локаль `ru_RU` →
fail2ban `30d/1440m/4` → unattended-upgrades (reboot в `00:01`) → пользователь `opossum` →
UFW (`deny incoming`, `limit` на SSH, IPv6 on) → reverse-туннель на OpenWrt → cron → reboot.

Split-сеть (`INBOUND/OUTBOUND`, без хардкода адресов): авто-детект → `/root/.network_config`.

## Проверка перед боевым прогоном

Не выполнено: bash -n/shellcheck — на этой Windows-машине нет bash/WSL.
Перед боевым прогоном выполни на любом Debian:
```bash
bash -n new-server.sh && bash -n config.env
shellcheck -S warning new-server.sh
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
