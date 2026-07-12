#!/usr/bin/env bash

if [ "$EUID" == 0 ]
  then echo "Please run as a non-root user."
  exit
fi

if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "x86_64" ];then
  echo "BirdNET-Pi requires a 64-bit OS.
It looks like your operating system is using $(uname -m),
but would need to be aarch64."
  exit 1
fi

PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info[0]}{sys.version_info[1]}')")
if [ "${PY_VERSION}" == "39" ] ;then
  echo "### BirdNET-Pi requires a newer OS. Bullseye is deprecated, please use Bookworm. ###"
  [ -z "${FORCE_BULLSEYE}" ] && exit
fi

# we require passwordless sudo
sudo -K
if ! sudo -n true; then
    echo "Passwordless sudo is not working. Aborting"
    exit
fi

# --- Hostname selection ------------------------------------------------------
# The collage is reached at http://<hostname>.local/ over mDNS, so the hostname
# is how you tell several Pis apart on the same network. Pick it here instead of
# baking it into each SD card. Priority:
#   1. --hostname <name>  (curl ... | bash -s -- --hostname birdie)
#   2. AV_HOSTNAME=<name> environment variable
#   3. interactive prompt (when run from a terminal)
#   4. the default below
DEFAULT_HOSTNAME="birdie"
AV_HOSTNAME="${AV_HOSTNAME:-}"
# Admin password (protects the BirdNET web areas + Avian settings/tools/system/
# logs pages) and the low-RAM flag can also come from flags or the environment.
# Empty AV_ADMIN_PWD means "no protection", exactly like a stock install.
AV_ADMIN_PWD="${AV_ADMIN_PWD:-}"
AV_LOW_RAM="${AV_LOW_RAM:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname=*) AV_HOSTNAME="${1#*=}"; shift ;;
    --hostname|-H)
      [ $# -ge 2 ] || { echo "--hostname needs a value, e.g. --hostname birdie"; exit 1; }
      AV_HOSTNAME="$2"; shift 2 ;;
    --admin-password=*) AV_ADMIN_PWD="${1#*=}"; shift ;;
    --admin-password)
      [ $# -ge 2 ] || { echo "--admin-password needs a value"; exit 1; }
      AV_ADMIN_PWD="$2"; shift 2 ;;
    --low-ram)    AV_LOW_RAM=1; shift ;;
    --no-low-ram) AV_LOW_RAM=0; shift ;;
    *) shift ;;
  esac
done

# Prompt only if nothing was passed and a terminal is attached. Read from
# /dev/tty so it still works when the script is piped in from curl (stdin is
# the pipe, not the keyboard).
if [ -z "$AV_HOSTNAME" ] && [ -t 1 ] && [ -e /dev/tty ]; then
  printf 'Hostname for this Pi (reachable at http://<name>.local/) [%s]: ' "$DEFAULT_HOSTNAME" > /dev/tty
  read -r AV_HOSTNAME < /dev/tty || AV_HOSTNAME=""
fi
AV_HOSTNAME="$(echo "${AV_HOSTNAME:-$DEFAULT_HOSTNAME}" | tr '[:upper:]' '[:lower:]')"

# Validate as a single DNS label (RFC 1123): a-z, 0-9 and hyphens, no leading
# or trailing hyphen, 1-63 chars. A bad value would otherwise break mDNS and
# land in /etc/hosts verbatim.
if ! echo "$AV_HOSTNAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
  echo "Invalid hostname: '$AV_HOSTNAME'."
  echo "Use letters, digits and hyphens only (max 63 chars, no leading/trailing hyphen)."
  exit 1
fi
export AV_HOSTNAME
echo "This Pi will be set up as '${AV_HOSTNAME}', reachable at http://${AV_HOSTNAME}.local/"

# --- Admin password ----------------------------------------------------------
# One password guards the BirdNET web areas (live stream, /scripts, /terminal,
# processed files) and the Avian settings/tools/system/logs pages. Empty = off.
# The value is written verbatim into the shell-sourced birdnet.conf and passed
# unquoted to `caddy hash-password`, so restrict it to a shell-safe charset to
# avoid breaking either. Priority: --admin-password / AV_ADMIN_PWD / prompt.
_pw_ok() { echo "$1" | grep -Eq '^[A-Za-z0-9._@%+-]*$'; }
if [ -n "$AV_ADMIN_PWD" ] && ! _pw_ok "$AV_ADMIN_PWD"; then
  echo "Invalid admin password: use only letters, digits and . _ @ % + -"
  exit 1
fi
if [ -z "$AV_ADMIN_PWD" ] && [ -t 1 ] && [ -e /dev/tty ]; then
  while :; do
    printf 'Admin password for the web interface (empty = no password): ' > /dev/tty
    read -rs AV_ADMIN_PWD < /dev/tty; printf '\n' > /dev/tty
    [ -z "$AV_ADMIN_PWD" ] && break
    if ! _pw_ok "$AV_ADMIN_PWD"; then
      printf 'Use only letters, digits and . _ @ %% + - — try again.\n' > /dev/tty
      AV_ADMIN_PWD=""; continue
    fi
    printf 'Repeat password: ' > /dev/tty
    read -rs _pw2 < /dev/tty; printf '\n' > /dev/tty
    [ "$AV_ADMIN_PWD" = "$_pw2" ] && break
    printf 'Passwords did not match — try again.\n' > /dev/tty
    AV_ADMIN_PWD=""
  done
  unset _pw2
fi
export AV_ADMIN_PWD
if [ -n "$AV_ADMIN_PWD" ]; then
  echo "Web interface will be password protected (username 'birdnet')."
else
  echo "No admin password set — the web interface stays open."
fi

# --- Low-RAM option ----------------------------------------------------------
# The livestream + stats (streamlit) services are the biggest memory hogs; on a
# small Pi offer to disable them permanently after install. Priority: --low-ram
# / --no-low-ram / AV_LOW_RAM / prompt.
if [ -z "$AV_LOW_RAM" ] && [ -t 1 ] && [ -e /dev/tty ]; then
  printf 'Low-RAM Pi? Permanently disable livestream + stats services [y/N]: ' > /dev/tty
  read -r _lowram < /dev/tty || _lowram=""
  case "$_lowram" in [Yy]*) AV_LOW_RAM=1 ;; *) AV_LOW_RAM=0 ;; esac
  unset _lowram
fi
AV_LOW_RAM="${AV_LOW_RAM:-0}"
export AV_LOW_RAM
[ "$AV_LOW_RAM" = "1" ] && echo "Low-RAM mode: livestream + birdnet_stats will be disabled after install."

# Simple new installer
HOME=$HOME
USER=$USER

export HOME=$HOME
export USER=$USER

PACKAGES_MISSING=
for cmd in git jq ; do
  if ! which $cmd &> /dev/null;then
      PACKAGES_MISSING="${PACKAGES_MISSING} $cmd"
  fi
done
if [[ ! -z $PACKAGES_MISSING ]] ; then
  sudo apt update
  sudo apt -y install $PACKAGES_MISSING
fi

branch=avian-visitors
git clone -b $branch --depth=1 https://github.com/dtngx/AvianVisitors.git ${HOME}/BirdNET-Pi &&

$HOME/BirdNET-Pi/scripts/install_birdnet.sh
if [ ${PIPESTATUS[0]} -eq 0 ];then
  echo "Installation completed successfully"
  sudo reboot
else
  echo "The installation exited unsuccessfully."
  exit 1
fi
