#!/bin/bash
# adding user and configure the systemd requirements

combatuser=$1

if test -z "${combatuser}" ; then
  printf "Combat Log username and systemd configuration\n"
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


if test -d /etc/systemd/system ; then
  cat > /etc/systemd/system/multistreamer.service <<EOF
[Unit]
Description=multistreamer
After=network.target

[Service]
ExecStart=/usr/local/bin/multistreamer -e production run
User=$combatuser

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/sockexec.service <<EOF
[Unit]
Description=sockexec
After=network.target

[Service]
ExecStart=/usr/local/bin/sockexec -t0 /tmp/exec.sock
User=$combatuser

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/postgres-auth-server.service <<EOF
[Unit]
Description=postgres-auth-server
After=network.target

[Service]
ExecStart=/usr/local/bin/postgres-auth-server -c /etc/postgres-auth-server/config.yaml run
ExecStartPre=/usr/local/bin/postgres-auth-server -c /etc/postgres-auth-server/config.yaml check
User=$combatuser

[Install]
WantedBy=multi-user.target
EOF
else
  printf "systemd not installed, not making service files\n"
fi
