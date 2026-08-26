#!/bin/bash
# File Name: iostat.sh
# Purpose: Wrapper to run iostat extended stats
# Created: 20260517  by  huangtingzhong

command -v iostat >/dev/null 2>&1 || {
  echo "ERROR: iostat not found — install sysstat (yum/dnf/apt install sysstat)" >&2
  exit 1
}

iostat -x 1 2
