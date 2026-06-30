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

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname=*) AV_HOSTNAME="${1#*=}"; shift ;;
    --hostname|-H)
      [ $# -ge 2 ] || { echo "--hostname needs a value, e.g. --hostname birdie"; exit 1; }
      AV_HOSTNAME="$2"; shift 2 ;;
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
