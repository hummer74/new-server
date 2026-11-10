# AGENTS.md — правила работы агента в проекте

Bash-скрипты bootstrap Debian 11+. Ядро: new-server.sh (set -euo pipefail,
оркестратор), config.env, вход через startinstall.sh (curl|bash, однострочник в README).
Из install_packages удалён iptables-persistent: ufw на Debian 12/13 содержит
Breaks: iptables-persistent (на bullseye ставится, там ufw без Breaks).
