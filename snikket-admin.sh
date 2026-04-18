#!/bin/bash
set -euo pipefail

cd /etc/snikket || { echo "Error: /etc/snikket not found. Is Snikket installed?"; exit 1; }

echo "# Generating administrator invite..."
# Detect the service name dynamically as in install script
XMPP_SERVICE=$(docker compose config --services | grep -E '^(snikket|snikket_server)$' | head -1) || true

if [ -z "$XMPP_SERVICE" ]; then
    echo "Error: Could not detect Snikket service name. Check docker-compose.yml"
    exit 1
fi

INVITE=$(docker compose exec -T "$XMPP_SERVICE" create-invite --admin --group default 2>&1 | grep -Eo 'https?://[^ ]+' | head -1) || true

if [ -n "$INVITE" ]; then
    echo "✅ Administrator invite link received:"
    echo "$INVITE"
    echo "$INVITE" > /root/snikket_url.txt
    echo "Link saved to /root/snikket_url.txt"
else
    echo "⚠️ Failed to generate invite automatically. Check if $XMPP_SERVICE is running."
    echo "Try manually: docker compose exec $XMPT_SERVICE create-invite --admin --group default"
fi
