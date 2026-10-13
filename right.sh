#!/bin/bash

# Fix directory permissions
chmod 700 ~/.ssh

# Fix all key permissions (missing globs are not errors on re-runs)
chmod 600 ~/.ssh/* 2>/dev/null || true
chmod 644 ~/.ssh/*.pub 2>/dev/null || true

# Fix special files permissions
chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
chmod 644 ~/.ssh/known_hosts 2>/dev/null || true
chmod 644 ~/.ssh/config 2>/dev/null || true