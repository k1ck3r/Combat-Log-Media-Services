#!/usr/bin/env sh

####################### IMPORTANT #########################
#							  #
# Before starting the setup procedure, install PostgreSQL #
#     and configure SQL's db/pass/user on line 344	  #
#							  #
####################### IMPORTANT #########################

set -e

if test "$(id -u)" != "0" ; then
  printf "Run this script as root\n"
  exit 1
fi

domain=$1

if test -z "${domain}" ; then
  printf "Usage: $0 <domain-name>\n"
  exit 1
fi

#printf "WARNING: this script is meant for doing a from-scratch install\n"
#printf "of multistreamer to a brand-new server. If you want to just\n"
#printf "install Multistreamer without possibly breaking anything, run\n"
#printf "./install\n\n"
printf "This WILL disable apache, if running, and setup nginx to serve\n"
#printf "$domain\n"
printf "Please type Y to continue, anything else to quit\n"

read input

if [ "${input}" != "Y" ] && [ "${input}" != "y" ] ; then
  exit
fi

if test -f /etc/os-release ; then
  DISTRO=$(. /etc/os-release && printf "${ID}" )
  RELEASE=$(. /etc/os-release && printf "${VERSION_ID}" )
elif test -f /etc/fedora-release ; then
  DISTRO="fedora"
  RELEASE="Unknown"
elif test -f /etc/debian_version ; then
  DISTRO="debian"
  RELEASE="Unknown"
elif test -f /etc/redhat-release ; then
  DISTRO="centos"
  RELEASE="Unknown"
elif test -f /etc/alpine-release ; then
  DISTRO="alpine"
  RELEASE="Unknown"
fi

if test -z "${DISTRO}" ; then
  printf "Unable to determine distro\n"
  exit 1
fi

if test "${DISTRO}" != "ubuntu" ; then
  printf "This script only supports ubuntu\n"
  exit 1
fi

if ! test command -v pushd 1>/dev/null 2>&1 ; then
pushd() {
    if test -z "PUSHD_STACK" ; then
        PUSHD_STACK="$PWD"
    else
        PUSHD_STACK="$PUSHD_STACK;$PWD"
    fi
    cd "$1"
}
popd() {
    if test -n ${IFS+x} ; then
      OLDIFS="${IFS}"
    fi
    IFS=";"
    NEW_PUSHD_STACK=""
    NEW_DIR=""
    for dir in ${PUSHD_STACK} ; do
      if test -z "${NEW_DIR}" ; then
        NEW_DIR="${dir}"
      else
        if test -z "${NEW_PUSHD_STACK}" ; then
          NEW_PUSHD_STACK="${NEW_DIR}"
        else
          NEW_PUSHD_STACK="${NEW_PUSHD_STACK};${NEW_DIR}"
        fi
        NEW_DIR="${dir}"
      fi
    done
    if test -n ${OLDIFS+x} ; then
      IFS="${OLDIFS}"
    else
      unset IFS
    fi
    cd "${NEW_DIR}"
    PUSHD_STACK="${NEW_PUSHD_STACK}"
    unset NEW_PUSHD_STACK
    unset NEW_DIR
}
fi

if test "${DISTRO}" = "ubuntu" ; then
  UPDATE_CMD="apt-get update"
  INSTALL_CMD="apt-get install -y"
  PACKAGE_LIST="nginx-light postgresql redis-server git-core curl haproxy"

fi

if test -z "${INSTALL_CMD}" ; then
  printf "Unable to install packages on this distro\n"
  exit 1
fi

LOGFILE=$(mktemp)

printf "Logging most commands to $LOGFILE...\n"
printf "If this script doesn't print \"SUCCESS\", please inspect $LOGFILE for details\n"

if command -v systemctl >/dev/null 2>&1 ; then
  printf "## Stopping/disabling apache2...\n" | tee -a $LOGFILE
  systemctl disable apache2.service >/dev/null 2>&1 || true
  systemctl stop apache2.service >/dev/null 2>&1 || true
elif command -v rc-service >/dev/null 2>&1 ; then
  printf "## Stopping/disabling apache2...\n" | tee -a $LOGFILE
  rc-service apache2 stop || true
  rc-service apache stop || true
  rc-service httpd stop || true
  rc-update delete apache2 || true
  rc-update delete apache || true
  rc-update delete httpd || true
elif command -v service >/dev/null 2>&1 ; then
  printf "## Stopping/disabling apache2...\n" | tee -a $LOGFILE
  service apache2 stop || true
  service apache stop || true
  service httpd stop || true
  update-rc.d apache2 remove || true
  update-rc.d apache remove || true
  update-rc.d httpd remove || true
else
  printf "## Unable to stop/disable apache2, this may crap out...\n" | tee -a $LOGFILE
fi

printf "## Updating package lists...\n" | tee -a $LOGFILE
if test -n "${UPDATE_CMD}" ; then
  ${UPDATE_CMD} >> $LOGFILE 2>&1
fi

printf "## Installing packages: ${PACKAGE_LIST}...\n" | tee -a $LOGFILE
${INSTALL_CMD} ${PACKAGE_LIST} >> $LOGFILE 2>&1

printf "## Installing multistreamer, sockexec, and postgres-auth-server...\n" | tee -a $LOGFILE
#./install 2>&1 | tee -a $LOGFILE

printf "## Installing/updated dehydrated...\n" | tee -a $LOGFILE
if ! test -d /opt/dehydrated ; then
  git clone https://github.com/lukas2511/dehydrated.git /opt/dehydrated >>$LOGFILE 2>&1
else
  pushd /opt/dehydrated >/dev/null 2>&1
  git fetch --tags origin >>$LOGFILE 2>&1
  popd >/dev/null 2>&1
fi

pushd /opt/dehydrated >/dev/null 2>&1
git checkout $(git describe --tags --abbrev=0) >>$LOGFILE 2>&1
popd >/dev/null 2>&1

mkdir -p /var/www/wellknown
mkdir -p /etc/dehydrated

printf "WELLKNOWN=/var/www/wellknown\n" > /etc/dehydrated/config
printf "$domain\n" > /etc/dehydrated/domains.txt

chown -R www-data:www-data /var/www/wellknown
chown -R www-data:www-data /etc/dehydrated

printf "## Registering with Let's Encrypt\n" | tee -a $LOGFILE
if ! test -d /etc/dehydrated/accounts ; then
  sudo -u www-data /opt/dehydrated/dehydrated --register --accept-terms >>$LOGFILE 2>&1
fi

if ! test -d /etc/dehydrated/certs ; then
  sudo -u www-data mkdir /etc/dehydrated/certs
fi

if ! test -d /etc/dehydrated/certs/$domain ; then
  sudo -u www-data mkdir /etc/dehydrated/certs/$domain
fi

printf "## Generating temporary self-signed certificate\n" | tee -a $LOGFILE
if ! test -e /etc/dehydrated/certs/$domain/fullchain.pem ; then
  # generate a temporary self-signed cert so nginx doesn't complain
  sudo -u www-data openssl req -new \
    -subj "/CN=$domain" \
    -sha256 -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout /etc/dehydrated/certs/$domain/privkey.pem \
    -out /etc/dehydrated/certs/$domain/fullchain.pem >>$LOGFILE 2>&1
fi

cat /etc/dehydrated/certs/$domain/fullchain.pem \
    /etc/dehydrated/certs/$domain/privkey.pem > \
    /etc/dehydrated/certs/$domain/combined.pem

rm /etc/nginx/sites-available/default

printf "## Generating nginx configs...\n" | tee -a $LOGFILE
cat <<EOF >/etc/nginx/sites-available/default
server {
  listen [::]:80 default_server ipv6only=off;

  server_name _;
  return 444;
}

server {
  listen [::]:443 ssl default_server ipv6only=off;

  ssl_certificate     /etc/dehydrated/certs/$domain/fullchain.pem;
  ssl_certificate_key /etc/dehydrated/certs/$domain/privkey.pem;
  
  server_name _;
  return 444;
}
EOF

cat <<EOF >/etc/nginx/sites-available/$domain
server {
  listen [::]:80;

  server_name $domain;

  location /.well-known/acme-challenge {
    alias /var/www/wellknown;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen [::]:443;

  ssl_certificate     /etc/dehydrated/certs/$domain/fullchain.pem;
  ssl_certificate_key /etc/dehydrated/certs/$domain/privkey.pem;

  server_name $domain;

  location /users {
    proxy_pass http://127.0.0.1:8080;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_redirect http:// \$scheme://;
  }

  location /ws {
    proxy_pass http://127.0.0.1:8081;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_redirect http:// \$scheme://;
  }

  location / {
    proxy_pass http://127.0.0.1:8081;
    proxy_request_buffering off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_redirect http:// \$scheme://;
  }
}
EOF

if ! test -e /etc/nginx/sites-enabled/$domain ; then
  printf "## Restarting nginx...\n" | tee -a $LOGFILE
  ln -s ../sites-available/$domain /etc/nginx/sites-enabled/$domain
  systemctl restart nginx.service >>$LOGFILE 2>&1
fi

printf "## Generating haproxy config...\n" | tee -a $LOGFILE
cat <<EOF >/etc/haproxy/haproxy.cfg
global
	maxconn 2048
	tune.ssl.default-dh-param 2048
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	stats socket /run/haproxy/admin.sock mode 660 level admin
	stats timeout 30s
	user haproxy
	group haproxy
	daemon

	# Default ciphers to use on SSL-enabled listening sockets.
	# For more information, see ciphers(1SSL). This list is from:
	#  https://hynek.me/articles/hardening-your-web-servers-ssl-ciphers/
	ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:ECDH+3DES:DH+3DES:RSA+AESGCM:RSA+AES:RSA+3DES:!aNULL:!MD5:!DSS
	ssl-default-bind-options no-sslv3

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
	errorfile 400 /etc/haproxy/errors/400.http
	errorfile 403 /etc/haproxy/errors/403.http
	errorfile 408 /etc/haproxy/errors/408.http
	errorfile 500 /etc/haproxy/errors/500.http
	errorfile 502 /etc/haproxy/errors/502.http
	errorfile 503 /etc/haproxy/errors/503.http
	errorfile 504 /etc/haproxy/errors/504.http

frontend multistreamer-irc-tls
	bind :::6697 v4v6 ssl crt /etc/dehydrated/certs/$domain/combined.pem
	mode tcp
        option tcplog
	default_backend multistreamer-irc

backend multistreamer-irc
	server primary 127.0.0.1:6667
EOF

systemctl restart haproxy.service >>$LOGFILE 2>&1

export SQLUSER=combatlog
export SQLPASS=
export SQLDB=combatlog

printf "## Creating $SQLUSER user and database...\n" | tee -a $LOGFILE
sudo -u postgres psql -c "create user $SQLUSER with password '$SQLPASS'" >/dev/null 2>&1 || true
sudo -u postgres psql -c "create database $SQLDB with owner $SQLUSER" >/dev/null 2>&1 || true

printf "## Generating multistreamer config file (/opt/multistreamer/config.lua) ...\n" | tee -a $LOGFILE

if ! test -e /opt/multistreamer/config.lua ; then

session_secret=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1)

cat <<EOF > /opt/multistreamer/config.lua
local config = require('lapis.config').config

config({'production'}, {
  -- name of the cookie used to store session data
  session_name = 'multistreamer',

  -- key for encrypting session data
  secret = '$session_secret',

  -- whether to log queries and requests
  logging = {
      queries = false,
      requests = false
  },

  -- if deploying somewhere other than the root of a domain,
  -- set this to your prefix (ie, '/multistreamer')
  http_prefix = '',

  -- set an rtmp prefix
  -- note: this can only be a single string,
  -- no slashes etc
  -- defaults to 'multistreamer' if unset
  rtmp_prefix = 'multistreamer',

  -- path to your nginx+lua+rtmp binary
  nginx = '/opt/openresty-rtmp/bin/openresty',

  -- path to psql
  psql = '/usr/bin/psql',

  -- path to ffmpeg
  ffmpeg = '/usr/bin/ffmpeg',

  -- set your logging level
  log_level = 'error',

  -- setup your external urls (without prefixes)
  public_http_url = 'https://$domain',
  public_rtmp_url = 'rtmp://$domain:1935',

  -- setup your private (loopback) urls (without prefixes)
  private_http_url = 'http://127.0.0.1:8081',
  private_rtmp_url = 'rtmp://127.0.0.1:1935',

  -- setup your public IRC hostname, for the web
  -- interface
  public_irc_hostname = '$domain',
  -- setup your public IRC port, to report in the
  -- web interface
  public_irc_port = '6697',
  -- set to true if you've setup an SSL terminator in front
  -- of multistreamer
  public_irc_ssl = true,

  -- configure streaming networks/services
  -- you'll need to register a new app with each
  -- service and insert keys/ids in here

  -- 'rtmp' just stores RTMP urls and has no config,
  networks = {
    -- mixer = {
    --   client_id = 'client_id',
    --   client_secret = 'client_secret',
    --   ingest_server = 'rtmp://somewhere',
    -- },
    -- twitch = {
    --   client_id = 'client_id',
    --   client_secret = 'client_secret',
    --   ingest_server = 'rtmp://somewhere', -- see https://bashtech.net/twitch/ingest.php
                                             -- for a list of endpoints
    -- },
    -- facebook = {
    --   app_id = 'app_id',
    --   app_secret = 'app_secret',
    -- },
    -- youtube = {
    --   client_id = 'client_id',
    --   client_secret = 'client_secret',
    --   country = 'us', -- 2-character country code, used for listing available categories
    -- },
    rtmp = true,
  },

  -- postgres connection settings
  postgres = {
    host = '127.0.0.1',
    user = '$SQLUSER',
    password = '$SQLPASS',
    database = '$SQLDB'
  },

  -- nginx http "listen" directive, see
  -- http://nginx.org/en/docs/http/ngx_http_core_module.html#listen
  http_listen = '127.0.0.1:8081',

  -- nginx rtmp "listen" directive, see
  -- https://github.com/arut/nginx-rtmp-module/wiki/Directives#listen
  -- default: listen on all ipv6+ipv4 addresses
  rtmp_listen = '[::]:1935 ipv6only=off',

  -- nginx irc "listen" directive, see
  -- https://nginx.org/en/docs/stream/ngx_stream_core_module.html#listen
  -- default: listen on all ipv6+ipv4 addresses
  irc_listen = '127.0.0.1:6667',

  -- set the IRC hostname reported by the server
  irc_hostname = '$domain',

  -- should users be automatically brought into chat rooms when
  -- their streams go live? (default false)
  -- this is handy for clients like Adium, Pidgin, etc that don't
  -- have a great IRC interface
  irc_force_join = true,

  -- number of worker processes
  worker_processes = 1,

  -- http auth endpoint
  -- multistreamer will make an HTTP request with the 'Authorization'
  -- header to this URL when a user logs in
  -- see http://nginx.org/en/docs/http/ngx_http_auth_request_module.html
  -- see https://github.com/jprjr/ldap-auth-server for an LDAP implementation
  auth_endpoint = 'http://127.0.0.1:8080/users/auth',

  -- redis host
  redis_host = '127.0.0.1:6379',

  -- prefix for redis keys
  redis_prefix = 'multistreamer/',

  -- path to trusted ssl certificate store
  ssl_trusted_certificate = '/etc/ssl/certs/ca-certificates.crt',

  -- dns resolver
  dns_resolver = '8.8.8.8 ipv6=off',

  -- maximum ssl verify depth
  ssl_verify_depth = 5,

  -- sizes for shared dictionaries (see https://github.com/openresty/lua-nginx-module#lua_shared_dict)
  lua_shared_dict_streams_size = '10m',
  lua_shared_dict_writers_size = '10m',

  -- specify the run directory to hold temp files etc,
  -- defaults to $HOME/.multistreamer if not set
  -- work_dir = '/path/to/some/folder',

  -- set the path to sockexec's socket
  -- see https://github.com/jprjr/sockexec for installation details
  sockexec_path = '/tmp/exec.sock',

  -- allow/disallow transcoding (default: true)
  allow_transcoding = false,

  -- allow/disallow creating pullers (default: true)
  allow_custom_puller = false,
})
EOF
fi

if ! test -e /etc/postgres-auth-server/config.yaml ; then
  secret_line=$(grep ' secret = ' /opt/multistreamer/config.lua)
  session_name_line=$(grep ' session_name = ' /opt/multistreamer/config.lua)
  session_secret=$(/opt/openresty-rtmp/bin/lua -e "tmp = { ${secret_line} }; print(tmp.secret)")
  session_name=$(/opt/openresty-rtmp/bin/lua -e "tmp = { ${session_name_line} }; print(tmp.session_name)")
  if ! test -d /etc/postgres-auth-server ; then
    mkdir -p /etc/postgres-auth-server
  fi
cat <<EOF >/etc/postgres-auth-server/config.yaml
### Postgres connection settings
### No default
postgres:
  host: 127.0.0.1
  user: psql_auth
  password: psql_auth
  database: psql_auth

### whether to log every SQL query and http request
### Default:
###   logging:
###     queries: true
###     requests: true
logging:
  queries: false
  requests: false

### what session name to store cookies in
### Default: session_name: 'lapis_session'
session_name: '${session_name}'

### secret used to encrypt session data
### Default: session_name: 'please-change-me'
secret: '${session_secret}'

### path to the nginx/openresty binary
### Default: nginx_path: '/opt/openresty/bin/openresty'
nginx_path: '/opt/openresty-rtmp/bin/openresty'

### log level
### Available methods:
###   debug
###   info
###   notice
###   warn
###   error
###   crit
###   alert
###   emerg
### Default: log_level: 'debug'
log_level: 'error'


### http_listen directive. Some examples:
###   http_listen: '127.0.0.1:8080'          # listen on loopback port 8080
###   http_listen: '8080'                    # listen on all ipv4 addresses, port 8080
###   http_listen: '*:8080'                  # listen on all ipv4 addresses, port 8080
###   http_listen: '[::]:8080'               # listen on all ipv6 addresses, port 8080
###   http_listen: '[::]:8080 ipv6only=off'  # listen on all ipv4+ipv6 addresses, port 8080
### This can also be an array if you need to listen on multiple port + address combos
### Example
###   http_listen:
###     - '127.0.0.1:8080'
###     - '192.168.5.1:8081'
###
### Default: http_listen: '[::]:8080 ipv6only=off'
http_listen: '127.0.0.1:8080'

### Uncomment http_prefix if you need this at some url other than '/'
### Examples:
###   http_prefix: '/users'
### Default: http_prefix:  # empty/blank
http_prefix: '/users'

### Uncomment encryption_method if you need to change the default encryption
### available methods, from best to worst:
###   sha512
###   sha256
###   ssha
###   sha
###   apr1
###   md5
### Default: encryption_method: 'sha512'
encryption_method: 'sha512'

### static_dir -- set location for static files (js, css, etc)
### Default: auto-detected
# static_dir:

### Set the DNS resolver
### Default: dns_resolver: '8.8.8.8 ipv6=off'
dns_resolver: '8.8.8.8 ipv6=off'

### Set the SSL certificate store
### default: ssl_trusted_certificate: '/etc/ssl/certs/ca-certificates.crt'
# ssl_trusted_certificate

### Work directory for temporary files, etc
### Default: $HOME/.postgres-auth-server
# work_dir:
EOF
fi

POSTGRES_AUTH_USERCOUNT=$(postgres-auth-server -c /etc/postgres-auth-server/config.yaml count 2>/dev/null || true)
if test -z ${POSTGRES_AUTH_USERCOUNT} ; then
  POSTGRES_AUTH_USERCOUNT=0
fi

if test ${POSTGRES_AUTH_USERCOUNT} -eq 0 ; then
  if test -e /opt/htpasswd-auth-server/etc/passwd ; then
    postgres-auth-server -c /etc/postgres-auth-server/config.yaml import /opt/htpasswd-auth-server/etc/passwd
  else
    postgres-auth-server -c /etc/postgres-auth-server/config.yaml add
  fi
fi

printf "## Generating script to auto-renew Let's Encrypt certs...\n" | tee -a $LOGFILE
cat <<EOF >/etc/cron.daily/update-letsencrypt-certs
#!/usr/bin/env bash
set -e

sudo -u www-data /opt/dehydrated/dehydrated -c >/dev/null 2>&1

if test /etc/dehydrated/certs/$domain/fullchain.pem -nt /etc/dehydrated/certs/$domain/combined.pem ; then
  cat /etc/dehydrated/certs/$domain/fullchain.pem \
      /etc/dehydrated/certs/$domain/privkey.pem > \
      /etc/dehydrated/certs/$domain/combined.pem
  systemctl reload nginx.service haproxy.service
fi
EOF

chmod +x /etc/cron.daily/update-letsencrypt-certs

printf "## Getting Let's Encrypt certificates...\n" | tee -a $LOGFILE
/etc/cron.daily/update-letsencrypt-certs >>$LOGFILE 2>&1

multistreamer -e production initdb >>$LOGFILE 2>&1 || true

printf "## Enabling and starting sockexec, postgres-auth-server, multistreamer...\n" | tee -a $LOGFILE

systemctl enable sockexec.service postgres-auth-server.service multistreamer.service >>$LOGFILE 2>&1
systemctl start sockexec.service postgres-auth-server.service multistreamer.service >>$LOGFILE 2>&1

if command -v systemctl >/dev/null 2>&1 ; then
  systemctl stop htpasswd-auth-server.service >/dev/null 2>&1 || true
  systemctl disable htpasswd-auth-server.service >/dev/null 2>&1 || true
  systemctl enable sockexec.service postgres-auth-server.service multistreamer.service >>$LOGFILE 2>&1
  systemctl start sockexec.service postgres-auth-server.service multistreamer.service >>$LOGFILE 2>&1
else
  printf "## Unable to enable/start services\n" | tee -a $LOGFILE
  exit 0
fi

printf "## SUCCESS\n" | tee -a $LOGFILE
