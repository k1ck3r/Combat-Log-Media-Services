#!/bin/bash
# adding user and configure the systemd requirements

combatuser=$1

if test -z "${combatuser}" ; then
  printf "Combat Log username configuration\n"
  printf "Usage: $0 <user-name>\n"
  exit 1
fi

printf "Creating $combatuser user\n"
if command -v useradd >/dev/null 2>&1 ; then
  useradd -m -d /var/lib/$combatuser \
    -r -s /usr/sbin/nologin $combatuser || true
elif command -v adduser >/dev/null 2>&1 ; then
  adduser -h /var/lib/$combatuser \
    -s /sbin/nologin \
    -S -D $1 || true
else
  printf "Unable to add $combatuser user\n"
  exit 1
fi
