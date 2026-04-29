#!/bin/sh
# Copyright (c) Tailscale Inc & contributors
# SPDX-License-Identifier: BSD-3-Clause
# Адаптировано для деинсталляции на основе логики install.sh
#
# Этот скрипт определяет ОС и полностью удаляет Tailscale, 
# включая конфигурационные файлы, репозитории и ключи.
#
# Examples:
#   curl -fsSL https://tailscale.com/install.sh | sh -s -- --uninstall  # (если бы это поддерживалось официально)
#   sh uninstall_tailscale.sh

set -eu

main() {
    # Шаг 1: Детекция ОС (полностью скопирована логика из install.sh)
    OS=""
    VERSION=""
    PACKAGETYPE=""
    APT_KEY_TYPE="" # Нужна, чтобы знать, откуда удалять ключи

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        VERSION_MAJOR="${VERSION_ID:-}"
        VERSION_MAJOR="${VERSION_MAJOR%%.*}"
        
        case "$ID" in
            ubuntu|pop|neon|zorin|tuxedo|elementary)
                OS="ubuntu"
                VERSION="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
                PACKAGETYPE="apt"
                [ "$VERSION_MAJOR" -lt 20 ] && APT_KEY_TYPE="legacy" || APT_KEY_TYPE="keyring"
                ;;
            debian)
                OS="$ID"
                VERSION="$VERSION_CODENAME"
                PACKAGETYPE="apt"
                if [ "$NAME" = "Parrot Security" ]; then
                    APT_KEY_TYPE="keyring"; VERSION=bookworm
                elif [ -z "${VERSION_ID:-}" ] || [ "$VERSION_MAJOR" -ge 11 ]; then
                    APT_KEY_TYPE="keyring"
                else
                    APT_KEY_TYPE="legacy"
                fi
                ;;
            linuxmint)
                if [ "${UBUNTU_CODENAME:-}" != "" ]; then OS="ubuntu"; VERSION="$UBUNTU_CODENAME";
                elif [ "${DEBIAN_CODENAME:-}" != "" ]; then OS="debian"; VERSION="$DEBIAN_CODENAME";
                else OS="ubuntu"; VERSION="$VERSION_CODENAME"; fi
                PACKAGETYPE="apt"
                [ "$VERSION_MAJOR" -lt 5 ] && APT_KEY_TYPE="legacy" || APT_KEY_TYPE="keyring"
                ;;
            raspbian|kali)
                OS="debian"; PACKAGETYPE="apt"
                if [ "$ID" = "kali" ]; then
                    [ "$VERSION_MAJOR" -lt 2021 ] && { VERSION="buster"; APT_KEY_TYPE="legacy"; } || { VERSION="bullseye"; APT_KEY_TYPE="keyring"; }
                else
                    [ "$VERSION_MAJOR" -lt 11 ] && APT_KEY_TYPE="legacy" || APT_KEY_TYPE="keyring"
                    VERSION="$VERSION_CODENAME"
                fi
                ;;
            parrot|pureos|kaisen|osmc|pika|sparky|industrial-os|galliumos|mendel|deepin|Deepin)
                OS="debian"; PACKAGETYPE="apt"; APT_KEY_TYPE="keyring"
                case "$ID" in
                    galliumos) VERSION="bionic"; APT_KEY_TYPE="legacy" ;;
                    parrot|industrial-os|mendel) [ "$VERSION_MAJOR" -lt 5 ] && VERSION="buster" || VERSION="bullseye" ;;
                    *) VERSION="${DEBIAN_CODENAME:-bullseye}" ;;
                esac
                ;;
            centos|ol|rhel|miraclelinux)
                OS="${ID:-rhel}"; [ "$ID" = "miraclelinux" ] && OS="rhel"
                VERSION="$VERSION_MAJOR"; PACKAGETYPE="dnf"
                [ "$VERSION_MAJOR" = "7" ] && PACKAGETYPE="yum"
                ;;
            fedora|rocky|almalinux|nobara|openmandriva|sangoma|risios|cloudlinux|alinux|fedora-asahi-remix|ultramarine)
                OS="fedora"; VERSION=""; PACKAGETYPE="dnf"
                ;;
            amzn)
                OS="amazon-linux"; VERSION="$VERSION_ID"; PACKAGETYPE="yum"
                ;;
            xenenterprise)
                OS="centos"; VERSION="$VERSION_MAJOR"; PACKAGETYPE="yum"
                ;;
            opensuse-leap|sles)
                OS="opensuse"; VERSION="leap/$VERSION_ID"; PACKAGETYPE="zypper"
                ;;
            opensuse-tumbleweed)
                OS="opensuse"; VERSION="tumbleweed"; PACKAGETYPE="zypper"
                ;;
            sle-micro-rancher)
                OS="opensuse"; VERSION="leap/15.4"; PACKAGETYPE="zypper"
                ;;
            arch|archarm|endeavouros|blendos|garuda|archcraft|cachyos)
                OS="arch"; VERSION=""; PACKAGETYPE="pacman"
                ;;
            manjaro|manjaro-arm|biglinux)
                OS="manjaro"; VERSION=""; PACKAGETYPE="pacman"
                ;;
            alpine|postmarketos)
                OS="alpine"; VERSION="$VERSION_ID"; PACKAGETYPE="apk"
                ;;
            void)
                OS="void"; VERSION=""; PACKAGETYPE="xbps"
                ;;
            gentoo)
                OS="gentoo"; VERSION=""; PACKAGETYPE="emerge"
                ;;
            freebsd)
                OS="freebsd"; VERSION="$(freebsd-version | cut -f1 -d.)"; PACKAGETYPE="pkg"
                ;;
            photon)
                OS="photon"; VERSION="$VERSION_MAJOR"; PACKAGETYPE="tdnf"
                ;;
            nixos)
                echo "Для удаления Tailscale в NixOS удалите строку 'services.tailscale.enable = true;' из вашей конфигурации и пересоберите систему."; exit 0
                ;;
            bazzite)
                echo "Для отключения Tailscale в Bazzite запустите: ujust disable-tailscale"; exit 0
                ;;
            steamos)
                echo "Следуйте инструкциям по удалению из репозитория deck-tailscale."; exit 0
                ;;
        esac
    fi

    # Фоллбэк через uname
    if [ -z "$OS" ]; then
        if type uname >/dev/null 2>&1; then
            case "$(uname)" in
                Darwin) echo "Удалите Tailscale через Launchpad или папку Applications."; exit 0 ;;
                FreeBSD) OS="freebsd"; VERSION="$(freebsd-version | cut -f1 -d.)"; PACKAGETYPE="pkg" ;;
                Linux) echo "Не удалось определить дистрибутив Linux."; exit 1 ;;
            esac
        fi
    fi

    if [ -z "$PACKAGETYPE" ]; then
        echo "Не удалось определить пакетный менеджер. Удалите Tailscale вручную."
        exit 1
    fi

    # Шаг 2: Поиск прав суперпользователя
    CAN_ROOT=
    SUDO=""
    if [ "$(id -u)" = 0 ]; then
        CAN_ROOT=1
    elif type sudo >/dev/null; then
        CAN_ROOT=1; SUDO="sudo"
    elif type doas >/dev/null; then
        CAN_ROOT=1; SUDO="doas"
    fi
    if [ "$CAN_ROOT" != "1" ]; then
        echo "Этот скрипт требует прав root. Не найдены sudo или doas."
        exit 1
    fi

    # Шаг 3: Деинсталляция
    OSVERSION="$OS"
    [ "$VERSION" != "" ] && OSVERSION="$OSVERSION $VERSION"

    echo "Удаление Tailscale из $OSVERSION с помощью $PACKAGETYPE..."

    case "$PACKAGETYPE" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            set -x
            # Останавливаем сервис перед удалением
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            # Удаляем пакет (purge очищает конфиги)
            $SUDO apt-get purge -y tailscale
            $SUDO apt-get autoremove -y
            # Удаляем ключи и репозитории
            case "$APT_KEY_TYPE" in
                legacy)
                    $SUDO apt-key del "https://pkgs.tailscale.com/stable/$OS/$VERSION.asc" 2>/dev/null || true
                    $SUDO rm -f /etc/apt/sources.list.d/tailscale.list
                    ;;
                keyring)
                    $SUDO rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
                    $SUDO rm -f /etc/apt/sources.list.d/tailscale.list
                    ;;
            esac
            $SUDO apt-get update
            set +x
            ;;
        yum)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            $SUDO yum remove -y tailscale
            $SUDO yum autoremove -y
            $SUDO rm -f /etc/yum.repos.d/tailscale.repo
            $SUDO yum clean all
            set +x
            ;;
        dnf)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            $SUDO dnf remove -y tailscale
            $SUDO dnf autoremove -y
            $SUDO rm -f /etc/yum.repos.d/tailscale.repo
            $SUDO dnf clean all
            set +x
            ;;
        tdnf)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            $SUDO tdnf remove -y tailscale
            $SUDO rm -f /etc/yum.repos.d/tailscale.repo
            set +x
            ;;
        zypper)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            # zypper может ругнуться, если репозиторий уже удален, игнорируем ошибку
            $SUDO zypper --non-interactive remove tailscale || true
            $SUDO rm -f /etc/zypp/repos.d/tailscale.repo
            set +x
            ;;
        pacman)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            # -Rns: удалить пакет, зависимости (если они не нужны никому) и конфиги
            $SUDO pacman -Rns tailscale --noconfirm
            set +x
            ;;
        pkg)
            set -x
            $SUDO service tailscaled stop 2>/dev/null || true
            $SUDO service tailscaled disable 2>/dev/null || true
            $SUDO pkg delete --yes tailscale
            $SUDO pkg autoremove --yes
            set +x
            ;;
        apk)
            set -x
            $SUDO rc-service tailscaled stop 2>/dev/null || true
            $SUDO rc-update del tailscale 2>/dev/null || true
            $SUDO apk del tailscale
            set +x
            ;;
        xbps)
            set -x
            $SUDO xbps-remove tailscale -y
            $SUDO xbps-remove -O # Очистка кэша
            set +x
            ;;
        emerge)
            set -x
            $SUDO systemctl stop tailscaled 2>/dev/null || true
            $SUDO emerge --ask=n --depclean net-vpn/tailscale
            set +x
            ;;
        *)
            echo "Неподдерживаемый пакетный менеджер: $PACKAGETYPE"
            exit 1
            ;;
    esac

    echo
    echo "Tailscale был полностью удален из вашей системы."
}

main
