#!/bin/bash
# Script to recreate swap file on Debian 11/12
# Removes all file-based swap devices and creates a new /swapfile
# Size is asked interactively (default 512 MB)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: script must be run as root (sudo).${NC}"
    exit 1
fi

# Function to show current swap devices
show_swap() {
    echo -e "${YELLOW}Current swap devices:${NC}"
    swapon --show
}

# Function to disable and remove all swap files
remove_file_swaps() {
    # Get list of swap devices that are files.
    # Use --show=NAME,TYPE to specify fields, then parse.
    local swaps=$(swapon --show=NAME,TYPE --noheadings --raw | awk '$2=="file" {print $1}')
    if [ -z "$swaps" ]; then
        echo -e "${GREEN}No file-based swap devices found.${NC}"
        return 0
    fi

    echo -e "${YELLOW}Found file-based swap devices:${NC}"
    echo "$swaps"
    read -p "Delete them? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Cancelled by user.${NC}"
        exit 0
    fi

    for file in $swaps; do
        echo "Disabling $file..."
        swapoff "$file" 2>/dev/null || true
        echo "Removing $file..."
        rm -f "$file"
    done
    echo -e "${GREEN}All file-based swap devices removed.${NC}"
}

# Ask for new swap file size
get_swap_size() {
    local default=512
    local size_input
    read -p "Enter swap file size in megabytes (default $default): " size_input
    size_input=${size_input:-$default}
    # Check that input is a positive integer
    if ! [[ "$size_input" =~ ^[0-9]+$ ]] || [ "$size_input" -le 0 ]; then
        echo -e "${RED}Error: size must be a positive integer.${NC}"
        exit 1
    fi
    SWAP_SIZE_MB=$size_input
    SWAP_FILE="/swapfile"
}

# Create swap file
create_swap_file() {
    echo -e "${YELLOW}Creating swap file of size ${SWAP_SIZE_MB} MB...${NC}"
    # Try fallocate, if not supported use dd
    if fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null; then
        echo "Using fallocate."
    else
        echo "fallocate not supported, using dd..."
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    echo -e "${GREEN}Swap file created and activated.${NC}"
}

# Update /etc/fstab: remove old entries for /swapfile, add new one
update_fstab() {
    local fstab_backup="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "$fstab_backup"
    echo "Created fstab backup: $fstab_backup"

    # Remove lines containing /swapfile (to avoid duplicates)
    sed -i "\#^$SWAP_FILE#d" /etc/fstab
    # Add new entry
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    echo "Entry in /etc/fstab updated."
}

# Main block
echo "=== Swap file recreation script ==="
show_swap
remove_file_swaps
get_swap_size
create_swap_file
update_fstab

echo -e "${GREEN}Done! New swap file of size ${SWAP_SIZE_MB} MB successfully configured.${NC}"
show_swap

exit 0