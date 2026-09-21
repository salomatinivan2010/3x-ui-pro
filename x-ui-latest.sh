#!/bin/bash
#################### x-ui-pro-refactor @ github.com/mozaroc #############################
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

# ─── Output helpers ──────────────────────────────────────────────────────────
msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

echo; msg_inf '           ___    _   _   _  '
msg_inf      ' \/ __ | |  | __ |_) |_) / \ '
msg_inf      ' /\    |_| _|_   |   | \ \_/ '; echo

# ─── Pre-flight checks ───────────────────────────────────────────────────────
check_os() {
    local os_id os_version
    os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
    os_version=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release 2>/dev/null)

    case "${os_id}" in
        ubuntu)
            [[ "$os_version" == "24.04" || "$os_version" == "26.04" ]] && return 0
            ;;
        debian)
            [[ "$os_version" == "12" || "$os_version" == "13" ]] && return 0
            ;;
    esac

    msg_err "Unsupported OS: ${os_id} ${os_version}"
    echo -e "\nThis script supports:\n  Ubuntu 24.04 / 26.04\n  Debian 12 / 13"
    echo -e "\nPlease reinstall your server with one of the supported OS versions and try again."
    exit 1
}

check_cpu() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)

    if echo "$cpu_model" | grep -qi 'QEMU'; then
        msg_err "QEMU virtual CPU detected!"
        echo -e "\nYour VPS is running with an emulated QEMU processor."
        echo -e "Please contact your hosting provider and ask them to switch the CPU type"
        echo -e "to \e[1;33mhost-passthrough\e[0m (expose real CPU model to the VM)."
        echo -e "\nThis is required for correct operation of the Xray core."
        exit 1
    fi
}

check_os
check_cpu

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main"
FAKE_SITE_COUNT=50

# ─── Default argument values ─────────────────────────────────────────────────
domain=""
reality_domain=""
UNINSTALL="x"
INSTALL="y"
AUTODOMAIN="n"
CFALLOW="n"

# ─── Stop & clean previous install (called from main, after domain validation) ─
# Transfer supports legacy settings.clients and modern clients/client_inbounds.
client_transfer() {
    python3 - "$@" <<'PYCLIENTS'
import json, sqlite3, sys, re
from pathlib import Path
mode, source = sys.argv[1:3]
def connect(path):
    db=sqlite3.connect(path); db.row_factory=sqlite3.Row; return db
def tables(db): return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
def rows(db,t): return [dict(r) for r in db.execute('SELECT * FROM "'+t+'"')] if t in tables(db) else []
def category(r):
    st=json.loads(r.get('stream_settings') or '{}'); n=st.get('network','tcp')
    if r['protocol']=='vless' and st.get('security')=='reality' and n in ('tcp','raw'): return 'reality'
    if r['protocol']=='vless' and n=='ws': return 'ws'
    if r['protocol']=='vless' and n=='xhttp': return 'xhttp'
    if r['protocol']=='trojan' and n=='grpc': return 'trojan'
    return None
src=connect(source)
assert src.execute('PRAGMA integrity_check').fetchone()[0]=='ok', 'Source database is damaged'
inbounds=rows(src,'inbounds'); clients=rows(src,'clients'); links=rows(src,'client_inbounds')
byid={r['id']:r for r in inbounds}; byclient={r['id']:r for r in clients}
legacy={r['id']:json.loads(r.get('settings') or '{}').get('clients',[]) for r in inbounds}
used={i for i,c in legacy.items() if c}
for l in links:
    if l['inbound_id'] not in byid or l['client_id'] not in byclient:
        raise SystemExit('Orphaned client_inbounds: repair old DB first; nothing was deleted')
    used.add(l['inbound_id'])
# Do not silently collapse several old inbounds into one new listener.
classes={}
for i in sorted(used):
    k=category(byid[i])
    if k is None: raise SystemExit('Unsupported client-bearing inbound id='+str(i)+' protocol='+byid[i]['protocol'])
    if k in classes: raise SystemExit('Several client-bearing inbounds for '+k+': automatic mapping is ambiguous')
    classes[k]=i
# Global client storage requires one identity per email. Fail before cleanup on conflicts.
seen={}
for cs in legacy.values():
    for c in cs:
        email=c.get('email','').lower()
        if not email: raise SystemExit('A legacy client has no email; assign one before migrating')
        identity={k:c[k] for k in ('id','password','subId') if c.get(k)}
        old=seen.setdefault(email,{})
        for k,v in identity.items():
            if k in old and old[k]!=v: raise SystemExit('Conflicting legacy credentials/subscription for email '+email)
            old[k]=v
# Validate all references before the original installation can be removed.
for table in ('client_traffics','client_external_links'):
    for r in rows(src,table):
        i=r.get('inbound_id')
        if i not in (0,None) and i not in used:
            raise SystemExit('Unmapped inbound reference in '+table+': '+str(i))
for c in clients:
    identity=seen.get(c['email'].lower(),{})
    for field,key in (('uuid','id'),('password','password'),('sub_id','subId')):
        if c.get(field) and identity.get(key) and c[field]!=identity[key]:
            raise SystemExit('Normalized/legacy client identity conflict for '+c['email'])
settings={r['key']:r['value'] for r in rows(src,'settings')}
paths={}
for k in ('subPath','subJsonPath'):
    v=settings.get(k,'').strip('/')
    if v and not re.fullmatch(r'[A-Za-z0-9_-]+',v):
        raise SystemExit('Nonstandard '+k+': needs manual nginx migration before reinstall')
    paths[k]=v
if mode=='check':
    print(json.dumps(dict(paths=paths,inbounds=len(used),clients=len(clients) or len(seen))))
    sys.exit(0)
if mode!='restore': raise SystemExit('Unknown mode')
dst=connect(sys.argv[3]); new=rows(dst,'inbounds'); mapping={}
for k,oldid in classes.items():
    matches=[r for r in new if category(r)==k]
    if len(matches)!=1: raise SystemExit('Missing/ambiguous target for '+k)
    mapping[oldid]=matches[0]['id']
# Mapped settings payloads remain the source of truth for per-inbound credentials/flow.
# If a source uses normalized storage only, materialize that representation as well.
alias={'uuid':'id','sub_id':'subId','limit_ip':'limitIp','total_gb':'totalGB',
       'expiry_time':'expiryTime','tg_id':'tgId','reset_day':'resetDay','reset_max':'resetMax',
       'group_name':'group','traffic_reset':'trafficReset','traffic_reset_day':'trafficResetDay'}
payloads={i:list(legacy[i]) for i in used}
for l in links:
    i=l['inbound_id']; c=byclient[l['client_id']]
    if any(x.get('email')==c['email'] for x in payloads[i]): continue
    obj={alias.get(k,k):v for k,v in c.items() if k in alias or k in
         ('email','password','auth','flow','security','enable','comment','reset','created_at','updated_at')}
    # An explicit empty override is meaningful on XHTTP/WS.
    obj['flow']=l.get('flow_override') if l.get('flow_override') is not None else c.get('flow','')
    payloads[i].append(obj)
def insert_table(t,transform=lambda r:r):
    data=rows(src,t)
    if not data: return
    if t not in tables(dst): raise RuntimeError('Missing target table '+t)
    if dst.execute('SELECT count(*) FROM "'+t+'"').fetchone()[0]:
        raise RuntimeError('Target '+t+' is not empty; refusing to overwrite clients')
    cols={r[1] for r in dst.execute('PRAGMA table_info("'+t+'")')}
    for row in data:
        row=transform(dict(row)); vals={k:v for k,v in row.items() if k in cols}
        lost=[k for k,v in row.items() if k not in cols and v not in (None,'',0)]
        if lost: raise RuntimeError('Unsupported columns in '+t+': '+','.join(lost))
        sql='INSERT INTO "'+t+'" ('+','.join('"'+k+'"' for k in vals)+') VALUES ('+','.join('?' for _ in vals)+')'
        dst.execute(sql,list(vals.values()))
def remap(r):
    i=r.get('inbound_id')
    if i in mapping: r['inbound_id']=mapping[i]
    elif i not in (0,None): raise RuntimeError('Unmapped inbound reference '+str(i))
    return r
with dst:
    for oldid,newid in mapping.items():
        target=next(r for r in new if r['id']==newid)
        st=json.loads(target['settings']);st['clients']=payloads[oldid]
        dst.execute('UPDATE inbounds SET settings=?,enable=? WHERE id=?',
                    (json.dumps(st,ensure_ascii=False),byid[oldid]['enable'],newid))
    for t in ('client_groups','clients','client_inbounds','client_traffics','client_hwids','client_external_links'):
        insert_table(t,remap)
    if clients and dst.execute('SELECT count(*) FROM clients').fetchone()[0]!=len(clients):
        raise RuntimeError('Client count mismatch')
    for oldid,newid in mapping.items():
        restored=json.loads(dst.execute('SELECT settings FROM inbounds WHERE id=?',(newid,)).fetchone()[0])['clients']
        if restored!=payloads[oldid]: raise RuntimeError('Client payload mismatch')
print('Transferred clients: '+str(len(clients) or len(seen))+', mapped inbounds: '+str(len(mapping)))
PYCLIENTS
}

restore_clients() {
    [[ -n "${client_source_db:-}" ]] || return 0
    systemctl stop x-ui || exit 1
    client_transfer restore "$client_source_db" "$XUIDB" || {
        msg_err "Client migration failed. Panel remains stopped. Backup: $backup_dir"
        exit 1
    }
    /usr/local/x-ui/x-ui migrate || exit 1
    msg_ok "Client migration completed. Refresh subscriptions after installation."
}

backup_before_lucx() {
    backup_dir="/root/lucx-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -m 700 "$backup_dir" || exit 1
    systemctl stop x-ui 2>/dev/null || true
    local item
    for item in /etc/x-ui /etc/nginx /etc/systemd/system/x-ui.service; do
        [[ ! -e "$item" ]] || cp -a --parents "$item" "$backup_dir/" || exit 1
    done
    if [[ -f "$XUIDB" ]]; then
        command -v python3 >/dev/null || {
            msg_err "Install python3 before migration. Original DB has not been deleted."
            systemctl start x-ui 2>/dev/null || true
            exit 1
        }
        client_source_db="$backup_dir/clients-source.db"
        # SQLite backup API includes committed WAL data; keep an immutable snapshot.
        python3 - "$XUIDB" "$client_source_db" <<'PYSNAPSHOT'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as source, sqlite3.connect(sys.argv[2]) as target:
    source.backup(target)
PYSNAPSHOT
        [[ $? == 0 ]] || exit 1
        chmod 600 "$client_source_db"
        local migration_info paths
        if ! migration_info=$(client_transfer check "$client_source_db"); then
            msg_err "Client preflight failed. Old installation was not deleted."
            systemctl start x-ui 2>/dev/null || true
            exit 1
        fi
        paths=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["paths"]["subPath"]); print(d["paths"]["subJsonPath"])' "$migration_info") || exit 1
        local -a saved_paths
        mapfile -t saved_paths <<< "$paths"
        [[ -z "${saved_paths[0]}" ]] || sub_path="${saved_paths[0]}"
        [[ -z "${saved_paths[1]:-}" ]] || json_path="${saved_paths[1]}"
    fi
    msg_inf "Pre-install backup: $backup_dir"
}

clean_previous_install() {
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    rm -rf /etc/nginx/sites-enabled/*
    rm -rf /etc/nginx/sites-available/*
    rm -rf /etc/nginx/stream-enabled/*
}

# ─── Port / path generators ──────────────────────────────────────────────────
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

# Matches the panel's host group_id format (16 lowercase alphanumerics)
gen_group_id() {
    head -c 4096 /dev/urandom | tr -dc 'a-z0-9' | head -c 16
    echo
}

check_free() {
    nc -z 127.0.0.1 "$1" &>/dev/null
    return $?
}

make_port() {
    while true; do
        local PORT
        PORT=$(get_port)
        if ! check_free "$PORT"; then
            echo "$PORT"
            break
        fi
    done
}

# ─── Generate ports & paths (done once at startup) ───────────────────────────
sub_port=$(make_port)
panel_port=$(make_port)
ws_port=$(make_port)
trojan_port=$(make_port)

sub_path=$(gen_random_string 10)
json_path=$(gen_random_string 10)
panel_path=$(gen_random_string 10)
ws_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)
diag_path="/net-$(gen_random_string 12)/"
diag_token=$(gen_random_string 16)
mtr_backend_port=$(make_port)

# ─── Argument parsing ────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        -install)          INSTALL="$2";           shift 2 ;;
        -subdomain)        domain="$2";            shift 2 ;;
        -reality_domain)   reality_domain="$2";    shift 2 ;;
        -ONLY_CF_IP_ALLOW) CFALLOW="$2";           shift 2 ;;
        -version)          PANEL_VERSION="$2";     shift 2 ;;
        -uninstall)        UNINSTALL="$2";         shift 2 ;;
        *)                 shift 1 ;;
    esac
done

# ─── Detect package manager ───────────────────────────────────────────────────
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
uninstall_xui() {
    printf 'y\n' | x-ui uninstall 2>/dev/null || true
    rm -rf /etc/x-ui/ /usr/local/x-ui/
    rm -f  /usr/bin/x-ui
    $Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y purge  nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y autoremove
    $Pak -y autoclean
    rm -rf /var/www/html/ /var/www/diagnostics/ /var/www/subpage/ /etc/nginx/ /usr/share/nginx/
    systemctl stop mtr-backend 2>/dev/null || true
    systemctl disable mtr-backend 2>/dev/null || true
    rm -f /etc/systemd/system/mtr-backend.service
    rm -rf /usr/local/lib/3x-ui-pro/
    systemctl daemon-reload 2>/dev/null || true
}

if [[ ${UNINSTALL} == *"y"* ]]; then
    uninstall_xui
    clear && msg_ok "Completely Uninstalled!" && exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# GET SERVER IP
# ─────────────────────────────────────────────────────────────────────────────
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"

get_server_ip() {
    IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
    IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
    [[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')
    [[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com | tr -d '[:space:]')
}

# Early IP fetch for auto-domain
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')


# ─────────────────────────────────────────────────────────────────────────────
# DOMAIN VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_domains() {
    while true; do
        [[ -n "$domain" ]] && break
        echo -en "Enter available subdomain (sub.domain.tld): " && read -r domain
    done
    domain=$(echo "$domain" | tr -d '[:space:]')
    SubDomain=$(echo "$domain"   | sed 's/^[^ ]* \|\..*//g')
    MainDomain=$(echo "$domain"  | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] && MainDomain=${domain}

    while true; do
        [[ -n "$reality_domain" ]] && break
        echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read -r reality_domain
    done
    reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')
    RealitySubDomain=$(echo "$reality_domain" | sed 's/^[^ ]* \|\..*//g')
    RealityMainDomain=$(echo "$reality_domain" | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] && RealityMainDomain=${reality_domain}

    if [[ "$domain" == "$reality_domain" ]]; then
        msg_err "Panel domain and REALITY domain must be different! Got: ${domain}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    ufw disable 2>/dev/null || true

    if [[ ${INSTALL} == *"y"* ]]; then
        local version
        version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
        [[ "$version" == "20" || "$version" == "22" ]] && echo "System: Ubuntu $version"

        $Pak -y update
        $Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin
        systemctl daemon-reload && systemctl enable --now nginx
    fi

    apt-get install -yqq --no-install-recommends ca-certificates
}

# ─────────────────────────────────────────────────────────────────────────────
# SSL CERTIFICATES
# ─────────────────────────────────────────────────────────────────────────────
get_ssl_certs() {
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true

    if [[ ${AUTODOMAIN} == *"y"* ]]; then
        local resolve_ok=true
        for d in "$domain" "$reality_domain"; do
            local a
            a=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
            if [[ "$a" != "$IP4" ]]; then
                msg_err "Auto-domain $d does not resolve to $IP4. Fix DNS and retry."
                resolve_ok=false
            fi
        done
        [[ $resolve_ok == false ]] && exit 1
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain"
    if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$reality_domain"
    if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
        systemctl start nginx >/dev/null 2>&1
        msg_err "$reality_domain SSL could not be generated! Check Domain/IP." && exit 1
    fi

    mkdir -p /root/cert/${domain}
    chmod 755 /root/cert/*
    ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
    ln -sf /etc/letsencrypt/live/${domain}/privkey.pem   /root/cert/${domain}/privkey.pem
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE NGINX
# ─────────────────────────────────────────────────────────────────────────────
configure_nginx() {
    mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets

    # nginx >= 1.25.1 deprecates "listen ... http2" in favor of "http2 on;";
    # older versions (Debian 12 / Ubuntu 24.04) don't know the new directive
    local ngx_ver http2_listen="" http2_on=""
    ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
        http2_on="http2 on;"
    else
        http2_listen=" http2"
    fi

    # SNI-based stream: reality → 8443, domain → 7443
    cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}    xray;
    ${domain}            www;
    default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF

    grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
        || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
    grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* \
        || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
    grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* \
        || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
    sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

    # HTTP → HTTPS redirect
    cat > /etc/nginx/sites-available/80.conf <<EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF

    # Shared proxy locations for xray inbounds (included by both vhosts)
    cat > /etc/nginx/snippets/includes.conf <<EOF
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    location /${sub_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffer_size 64k;
        proxy_buffers 4 64k;
        proxy_busy_buffers_size 128k;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffer_size 64k;
        proxy_buffers 4 64k;
        proxy_busy_buffers_size 128k;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    # Regex takes priority over prefix: catches subscription IDs (one-level deep)
    # and routes Clash/Mihomo clients to dynamic clash.yaml generator
    location ~ ^/${sub_path}/(?<clash_sub_id>[^/]+)$ {
        if (\$hack = 1) { return 404; }
        if (\$serve_clash_yaml = 1) { rewrite ^ /__clash_api?sub_id=\$clash_sub_id last; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffer_size 64k;
        proxy_buffers 4 64k;
        proxy_busy_buffers_size 128k;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

    #Subscription (json)
    location /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffer_size 64k;
        proxy_buffers 4 64k;
        proxy_busy_buffers_size 128k;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffer_size 64k;
        proxy_buffers 4 64k;
        proxy_busy_buffers_size 128k;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size      16k;
        grpc_socket_keepalive on;
        grpc_read_timeout     1h;
        grpc_send_timeout     1h;
        grpc_set_header Connection        "";
        grpc_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port  \$server_port;
        grpc_set_header Host              \$host;
        grpc_set_header X-Forwarded-Host  \$host;
    }

    #Xray generic proxy (WS / gRPC by port+path)
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }

    # Root location is defined separately in each vhost.
EOF

    # HTTP-level maps. The clash maps are consumed by the shared includes.conf
    # snippet, which is included by BOTH vhosts, so they live in their own
    # always-loaded file — never inside a single vhost, or the other vhost's
    # include would reference an undefined var ("unknown ... variable").
    cat > /etc/nginx/sites-available/00-maps.conf <<EOF
# Detect Clash/Mihomo clients by User-Agent
map \$http_user_agent \$is_clash_ua {
    ~*(clash|clashx|clashn|mihomo|stash|surfboard)  1;
    default                                          0;
}
# Serve clash.yaml only when: Clash UA AND no ?provider=1 query param
# (proxy-provider refresh requests add ?provider=1 and must get the real sub)
map "\$is_clash_ua:\$arg_provider" \$serve_clash_yaml {
    "1:"    1;
    default 0;
}
EOF

    # Main domain vhost (TLS termination at 7443, proxy_protocol)
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
# Rate limiting zones (http context)
limit_req_zone  \$binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  \$binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone \$binary_remote_addr zone=per_ip:10m;

# Diagnostics access: cookie issued by the SSO bridge after panel login
map \$cookie_diag_key \$diag_auth {
    "${diag_token}" 1;
    default          0;
}

server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl${http2_listen} proxy_protocol;
    listen [::]:7443 ssl${http2_listen} proxy_protocol;
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    # This vhost listens on 7443 behind the SNI stream (public port 443). Without
    # this, nginx bakes :7443 into redirect Location headers (return/error_page),
    # so browsers get sent to an unreachable port. Keep redirects relative.
    absolute_redirect off;
    # Larger h2 preread window improves single-stream upload throughput
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${domain}\$)            { return 444; }
    if (\$scheme ~* https)                          { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    # ── Diagnostics SSO bridge ───────────────────────────────────────────────
    # Lives under the panel path so the browser attaches the 3x-ui session
    # cookie (its Path is scoped to the panel base path). Valid panel session
    # → issue the diag cookie and redirect; otherwise → panel login page.
    # NOTE: auth_request runs in the access phase; a plain "return" here would
    # skip it (rewrite phase), hence the try_files → named-location hop.
    location = /${panel_path}/diag {
        auth_request /__diag_auth;
        # Named location (not "=302 /uri") so the deny path emits a real Location
        # header; an internal-redirect error_page returns a 302 with no Location.
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 /${panel_path}/;
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
        return 302 ${diag_path};
    }
    location = /__diag_auth {
        internal;
        proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # 3x-ui answers AJAX requests with 401 instead of a login redirect
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # auth_request emits a raw 500 to the browser if the subrequest returns
        # anything other than 2xx / 401 / 403 (a login 302, or a 502 when the
        # panel's HTTPS cert is missing). Coerce every such status to a 401 deny
        # so the main location redirects to the panel login instead of 500ing.
        # 401/403 must be listed too, else the server-level "error_page 401 =404"
        # hijacks a genuine deny into a 404 (which auth_request then 500s on).
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # ── Network diagnostics page ─────────────────────────────────────────────
    # No diag cookie yet → bounce through the SSO bridge, which checks the panel
    # session and mints the cookie, so a bookmarked diag link "just works" once
    # you're logged into the panel. (Only the HTML page redirects; the API/asset
    # sub-locations below stay 404 without the cookie.)
    location ^~ ${diag_path} {
        if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
        limit_req  zone=diag_page burst=10 nodelay;
        limit_conn per_ip 5;
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }

    # ── Diagnostics MTR API ──────────────────────────────────────────────────
    location ^~ ${diag_path}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        limit_req  zone=diag_api burst=2 nodelay;
        limit_conn per_ip 2;
        proxy_pass         http://127.0.0.1:${mtr_backend_port}/api/mtr;
        proxy_http_version 1.1;
        proxy_set_header   X-Real-IP       \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        # Let the backend's JSON error bodies through; the server-level
        # "proxy_intercept_errors on" would otherwise rewrite a 500 into an HTML
        # 404 and break the frontend's response.json() parse.
        proxy_intercept_errors off;
    }

    # ── LibreSpeed upload sink ───────────────────────────────────────────────
    # No limit_req: librespeed fires many short POSTs (parallel streams).
    # proxy_request_buffering off = client sees true network backpressure.
    location ^~ ${diag_path}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        access_log              off;
        limit_conn              per_ip 8;
        proxy_pass              http://127.0.0.1:${mtr_backend_port}/api/st/up;
        proxy_http_version      1.1;
        proxy_set_header        X-Real-IP       \$remote_addr;
        proxy_request_buffering off;
        client_max_body_size    64m;
        proxy_read_timeout      60s;
        proxy_send_timeout      60s;
        add_header              Cache-Control "no-store" always;
    }

    # ── LibreSpeed ping endpoint (answered by nginx, no backend hop) ─────────
    location = ${diag_path}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        access_log off;
        limit_conn per_ip 8;
        add_header Cache-Control "no-store" always;
        default_type text/plain;
        return 200 "";
    }

    # ── LibreSpeed client IP ─────────────────────────────────────────────────
    location = ${diag_path}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/st/getip;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
        add_header          Cache-Control "no-store" always;
    }

    # ── Download test files ──────────────────────────────────────────────────
    location ^~ ${diag_path}testfiles/ {
        if (\$diag_auth = 0) { return 404; }
        alias      /var/www/diagnostics/testfiles/;
        access_log off;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Content-Disposition "attachment" always;
    }

    # ── Clash YAML generator — internal, proxied here by rewrite from sub_path ────
    location = /__clash_api {
        internal;
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/clash\$is_args\$args;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
    }

    # Telegram WEB proxy: all unmatched paths reach the managed HTTP relay.
    location / {
        proxy_pass http://127.0.0.1:${telegram_relay_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_intercept_errors off;
        client_max_body_size 2m;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Reality domain vhost (plain TLS at 9443, no proxy_protocol)
    cat > "/etc/nginx/sites-available/${reality_domain}" <<EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl${http2_listen};
    listen [::]:9443 ssl${http2_listen};
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${reality_domain}\$)            { return 444; }
    if (\$scheme ~* https)                                  { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                        { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }

    location / { try_files \$uri \$uri/ =404; }
    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Activate configs
    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
        ln -sf "/etc/nginx/sites-available/00-maps.conf"       /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${domain}"          /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/${reality_domain}"  /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/80.conf"            /etc/nginx/sites-enabled/
    else
        msg_err "${domain} nginx config not found!" && exit 1
    fi

    if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
        msg_err "nginx config check failed!" && exit 1
    fi

    systemctl start nginx
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PANEL (3x-ui)
# ─────────────────────────────────────────────────────────────────────────────
_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)          echo 'amd64'  ;;
        i*86|x86)                  echo '386'    ;;
        armv8*|armv8|arm64|aarch64) echo 'arm64' ;;
        armv7*|armv7|arm)          echo 'armv7'  ;;
        armv6*|armv6)              echo 'armv6'  ;;
        armv5*|armv5)              echo 'armv5'  ;;
        s390x)                     echo 's390x'  ;;
        *) echo "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

_panel_initial_config() {
    /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
    /usr/local/x-ui/x-ui migrate
}

# Pin the inspected release: tproxy BehindCover and loopback allocation are
# integration contracts with nginx. Change only after checking these contracts.
prepare_lucx_installer() {
    [[ "$(_arch)" == amd64 ]] || {
        msg_err "Telegram WEB proxy requires amd64 (official MTProxy engine)."
        exit 1
    }
    local tag="${PANEL_VERSION:-v3.8.5-lucx.261}"
    [[ "$tag" == v3.8.5-lucx.261 ]] || {
        msg_err "This integration is verified against v3.8.5-lucx.261; omit -version or use that tag."
        exit 1
    }
    command -v curl >/dev/null || { msg_err "Install curl first."; exit 1; }
    lucx_installer=$(mktemp /tmp/lucx-install.XXXXXX) || exit 1
    curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://raw.githubusercontent.com/AlexeyLCP/lucx-ui/${tag}/install.sh" \
        -o "$lucx_installer" || exit 1
    bash -n "$lucx_installer" || exit 1
}

install_panel() {
    # The upstream installer also installs geodata and sidecar dependencies.
    XUI_NONINTERACTIVE=1 bash "$lucx_installer" v3.8.5-lucx.261 || {
        msg_err "LucX-UI installation failed."; exit 1;
    }
    rm -f "$lucx_installer"
    local binary
    for binary in xray-linux-amd64 tproxy-linux-amd64 mtproxy-linux-amd64; do
        [[ -x "/usr/local/x-ui/bin/$binary" ]] || {
            msg_err "Missing required binary: $binary"; exit 1;
        }
    done
    _panel_initial_config || exit 1
    msg_ok "LucX-UI v3.8.5-lucx.261 installed."
}

configure_telegram_web() {
    # BehindCover keeps TLS under nginx and disables the sidecar Caddy listener.
    # externalTLS must stay false: true disables the entire managed stack.
    systemctl stop x-ui || exit 1
    mkdir -p /var/www/telegram-web
    cat > /var/www/telegram-web/index.html <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><title>Welcome</title>
<body><h1>Welcome</h1><p>This website is online.</p></body></html>
HTML
    chmod 755 /var/www/telegram-web
    chmod 644 /var/www/telegram-web/index.html
    telegram_secret=$(openssl rand -hex 16) || exit 1
    local settings
    settings=$(jq -cn --arg host "$domain" --arg secret "$telegram_secret" \
        '{hostname:$host,secret:$secret,port:443,siteSource:"dir",
          siteDir:"/var/www/telegram-web",carrierMode:"https",behindCover:true,
          externalTLS:false,routeThroughXray:false}') || exit 1
    # Parameterized writes: no interpolation of the secret/domain into SQL.
    telegram_id=$(python3 - "$XUIDB" "$settings" <<'PYDB'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    row=db.execute("SELECT id FROM inbounds WHERE tag=?", ("telegram-web",)).fetchone()
    if row:
        raise SystemExit("telegram-web already exists; refusing to rotate its secret")
    cur=db.execute("""INSERT INTO inbounds
        (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,
         settings,stream_settings,tag,sniffing)
        VALUES (1,0,0,0,?,1,0,'127.0.0.1',443,'tproxy',?,'{}',?,'{}')""",
        ("Telegram WEB proxy",sys.argv[2],"telegram-web"))
    print(cur.lastrowid)
PYDB
    ) || exit 1
    [[ "$telegram_id" =~ ^[0-9]+$ ]] || exit 1
    # LucX-UI v3.8.5-lucx.261: tproxyLoopback(id, offset) = 24000 + id*4 + offset.
    telegram_relay_port=$((24000 + telegram_id * 4 + 2))
    (( telegram_relay_port + 1 <= 65535 )) || exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE X-UI DATABASE
# ─────────────────────────────────────────────────────────────────────────────
configure_xui_db() {
    if [[ ! -f $XUIDB ]]; then
        msg_err "x-ui.db not found — panel may not be installed." && exit 1
    fi

    x-ui stop 2>/dev/null || true

    local output private_key public_key trojan_pass emoji_flag xray_bin
    # install_panel renames armv5/6/7 binaries to xray-linux-arm
    xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm"
    output=$("$xray_bin" x25519)
    private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    public_key=$(awk '/^(Password|PublicKey|Public key):/ {print $NF; exit}' <<< "$output")
    [[ -n "$private_key" && -n "$public_key" ]] || { msg_err "X25519 key generation failed."; exit 1; }
    trojan_pass=$(gen_random_string 10)
    # Per-host group_id: without it the panel cannot edit or delete the host.
    # The column only exists since 3x-ui v3.5.0 (pinnable via -version), so
    # probe the migrated schema and skip it on older releases.
    local gid_col="" gid_reality="" gid_ws="" gid_xhttp="" gid_trojan=""
    if sqlite3 "$XUIDB" "PRAGMA table_info(hosts);" | grep -qw "group_id"; then
        gid_col='"group_id",'
        gid_reality="'$(gen_group_id)',"
        gid_ws="'$(gen_group_id)',"
        gid_xhttp="'$(gen_group_id)',"
        gid_trojan="'$(gen_group_id)',"
    fi
    emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s --max-time 10 https://ipwho.is/ | jq -r '.flag.emoji' 2>/dev/null)
    [[ -z "$emoji_flag" || "$emoji_flag" == "null" ]] && emoji_flag="🌐"

    local sub_uri="https://${domain}/${sub_path}/"
    local json_uri="https://${domain}/${json_path}?name="

    # Prepare short IDs for REALITY
    local shor
    shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) \
           $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

    sqlite3 -bail "$XUIDB" <<EOF || exit 1
BEGIN IMMEDIATE;
DELETE FROM settings WHERE key IN ('subPort','subURI','subJsonURI','subClashEnable','subEnableRouting','subEnable','webListen','webDomain','webCertFile','webKeyFile','sessionMaxAge','pageSize','expireDiff','trafficDiff','remarkModel','tgBotEnable','tgBotToken','tgBotProxy','tgBotAPIServer','tgBotChatId','tgRunTime','tgBotBackup','tgBotLoginNotify','tgCpu','tgLang','timeLocation','secretEnable','subDomain','subCertFile','subKeyFile','subUpdates','subEncrypt','subShowInfo','subJsonFragment','subJsonNoises','subJsonMux','subJsonRules','datepicker');
DELETE FROM "settings" WHERE "key" IN ("webCertFile","webKeyFile");

INSERT INTO "settings" ("key","value") VALUES ("subPort",             '${sub_port}');
DELETE FROM settings WHERE key='subPath';
INSERT INTO settings(key,value) VALUES ('subPath','/${sub_path}/');
INSERT INTO "settings" ("key","value") VALUES ("subURI",              '${sub_uri}');
DELETE FROM settings WHERE key='subJsonPath';
INSERT INTO settings(key,value) VALUES ('subJsonPath','/${json_path}/');
INSERT INTO "settings" ("key","value") VALUES ("subJsonURI",          '${json_uri}');
INSERT INTO "settings" ("key","value") VALUES ("subClashEnable",      'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnableRouting",    'false');
INSERT INTO "settings" ("key","value") VALUES ("subEnable",           'true');
INSERT INTO "settings" ("key","value") VALUES ("webListen",           '');
INSERT INTO "settings" ("key","value") VALUES ("webDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("webCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("webKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("sessionMaxAge",       '60');
INSERT INTO "settings" ("key","value") VALUES ("pageSize",            '50');
INSERT INTO "settings" ("key","value") VALUES ("expireDiff",          '0');
INSERT INTO "settings" ("key","value") VALUES ("trafficDiff",         '0');
INSERT INTO "settings" ("key","value") VALUES ("remarkModel",         '-ieo');
INSERT INTO "settings" ("key","value") VALUES ("tgBotEnable",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotToken",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotProxy",          '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotAPIServer",      '');
INSERT INTO "settings" ("key","value") VALUES ("tgBotChatId",         '');
INSERT INTO "settings" ("key","value") VALUES ("tgRunTime",           '@daily');
INSERT INTO "settings" ("key","value") VALUES ("tgBotBackup",         'false');
INSERT INTO "settings" ("key","value") VALUES ("tgBotLoginNotify",    'true');
INSERT INTO "settings" ("key","value") VALUES ("tgCpu",               '80');
INSERT INTO "settings" ("key","value") VALUES ("tgLang",              'en-US');
INSERT INTO "settings" ("key","value") VALUES ("timeLocation",        'Europe/Moscow');
INSERT INTO "settings" ("key","value") VALUES ("secretEnable",        'false');
INSERT INTO "settings" ("key","value") VALUES ("subDomain",           '');
INSERT INTO "settings" ("key","value") VALUES ("subCertFile",         '');
INSERT INTO "settings" ("key","value") VALUES ("subKeyFile",          '');
INSERT INTO "settings" ("key","value") VALUES ("subUpdates",          '12');
INSERT INTO "settings" ("key","value") VALUES ("subEncrypt",          'true');
INSERT INTO "settings" ("key","value") VALUES ("subShowInfo",         'true');
INSERT INTO "settings" ("key","value") VALUES ("subJsonFragment",     '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonNoises",       '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonMux",          '');
INSERT INTO "settings" ("key","value") VALUES ("subJsonRules",        '');
INSERT INTO "settings" ("key","value") VALUES ("datepicker",          'gregorian');

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} reality','1','0','','8443','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": ["${reality_domain}"],
    "privateKey": "${private_key}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}","${shor[1]}","${shor[2]}","${shor[3]}",
      "${shor[4]}","${shor[5]}","${shor[6]}","${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "firefox",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {"type":"none"}
  }
}',
    'inbound-8443',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} ws','1','0','','${ws_port}','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "ws",
  "security": "none",
  "wsSettings": {
    "acceptProxyProtocol": false,
    "path": "/${ws_port}/${ws_path}",
    "host": "${domain}",
    "headers": {}
  }
}',
    'inbound-${ws_port}',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} xhttp','0','0','/dev/shm/uds2023.sock,0666','0','vless',
    '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
    '{
  "network": "xhttp",
  "security": "none",
  "xhttpSettings": {
    "path": "/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}',
    'inbound-/dev/shm/uds2023.sock,0666:0|',
    '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO "inbounds"
    ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
    '1','0','0','0','${emoji_flag} trojan-grpc','1','0','','${trojan_port}','trojan',
    '{
  "clients": [],
  "fallbacks": []
}',
    '{
  "network": "grpc",
  "security": "none",
  "grpcSettings": {
    "serviceName": "/${trojan_port}/${trojan_path}",
    "authority": "${domain}",
    "multiMode": false
  }
}',
    'inbound-${trojan_port}',
    '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

-- Hosts supersede the legacy externalProxy arrays: one host per inbound,
-- rendered as the share-link endpoint at subscription time.
-- REALITY keeps its own TLS params (security=same); the rest front through
-- nginx at :443 with TLS.
INSERT INTO "hosts" ("inbound_id",${gid_col}"sort_order","remark","address","port","security","fingerprint","alpn")
VALUES
    ((SELECT id FROM inbounds WHERE tag='inbound-8443'), ${gid_reality} 0, 'reality', '${domain}', 443, 'same', '', '[]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-${ws_port}'), ${gid_ws} 0, 'ws', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-/dev/shm/uds2023.sock,0666:0|'), ${gid_xhttp} 0, 'xhttp', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]'),
    ((SELECT id FROM inbounds WHERE tag='inbound-${trojan_port}'), ${gid_trojan} 0, 'trojan', '${domain}', 443, 'tls', 'firefox', '["h2","http/1.1"]');

-- Set the main domain as SNI for the XHTTP client profile.
UPDATE "hosts"
SET "sni" = '${domain}',
    "override_sni_from_address" = 0,
    "keep_sni_blank" = 0
WHERE "inbound_id" = (
    SELECT "id"
    FROM "inbounds"
    WHERE "tag" = 'inbound-/dev/shm/uds2023.sock,0666:0|'
);
COMMIT;
EOF

    /usr/local/x-ui/x-ui setting \
        -username  "${config_username}" \
        -password  "${config_password}" \
        -port      "${panel_port}"      \
        -webBasePath "${panel_path}"

    /usr/local/x-ui/x-ui cert \
        -webCert    "/root/cert/${domain}/fullchain.pem" \
        -webCertKey "/root/cert/${domain}/privkey.pem"

    # Started by main only after restoring clients and configuring nginx.
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL FAKE SITE
# ─────────────────────────────────────────────────────────────────────────────
install_clash_sub() {
    local clash_dir="/var/www/subpage"
    mkdir -p "${clash_dir}"
    if curl -fsSL "${GITHUB_RAW}/assets/clash/clash.yaml" -o "${clash_dir}/clash.yaml.tpl"; then
        # Substitute domain and sub_path; leave ${EMAIL} for mtr-backend to fill per-request
        sed -i "s|\${DOMAIN}|${domain}|g"     "${clash_dir}/clash.yaml.tpl"
        sed -i "s|\${SUB_PATH}|${sub_path}|g" "${clash_dir}/clash.yaml.tpl"
        chown -R www-data:www-data "${clash_dir}" 2>/dev/null || true
        chmod 644 "${clash_dir}/clash.yaml.tpl"
        msg_ok "Clash subscription template installed."
    else
        msg_err "Failed to download clash.yaml from GitHub."
    fi
}

install_fake_site() {
    local idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
    local site_id
    site_id=$(printf "site-%02d" "$idx")
    local url="${GITHUB_RAW}/assets/fake-sites/${site_id}/index.html"

    mkdir -p /var/www/html
    if curl -fsSL "$url" -o /var/www/html/index.html; then
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        chmod 644 /var/www/html/index.html
        msg_ok "Fake cover site '${site_id}' installed."
    else
        msg_err "Failed to download fake site ${site_id} from GitHub."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL NETWORK DIAGNOSTICS PAGE
# ─────────────────────────────────────────────────────────────────────────────
install_diagnostics() {
    local diag_webroot="/var/www/diagnostics"
    local backend_script="/usr/local/lib/3x-ui-pro/mtr-backend.py"

    # Diagnostics HTML page
    mkdir -p "${diag_webroot}"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/index.html" -o "${diag_webroot}/index.html"
    sed -i \
        -e "s|__DIAG_PATH__|${diag_path}|g" \
        -e "s|__SERVER_DOMAIN__|${domain}|g" \
        -e "s|__SERVER_IP__|${IP4}|g" \
        "${diag_webroot}/index.html"

    # LibreSpeed engine (speed test frontend, LGPL — github.com/librespeed/speedtest)
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest.js" \
        -o "${diag_webroot}/speedtest.js"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest_worker.js" \
        -o "${diag_webroot}/speedtest_worker.js"

    # Test download files
    local testfiles="${diag_webroot}/testfiles"
    mkdir -p "${testfiles}"
    [[ -f "${testfiles}/test-15k.bin"  ]] || dd if=/dev/zero bs=1024    count=15   of="${testfiles}/test-15k.bin"  status=none
    [[ -f "${testfiles}/test-17k.bin"  ]] || dd if=/dev/zero bs=1024    count=17   of="${testfiles}/test-17k.bin"  status=none
    [[ -f "${testfiles}/test-100m.bin" ]] || dd if=/dev/zero bs=1048576 count=100  of="${testfiles}/test-100m.bin" status=none
    [[ -f "${testfiles}/test-1g.bin"   ]] || dd if=/dev/zero bs=1048576 count=1024 of="${testfiles}/test-1g.bin"   status=none
    rm -f "${testfiles}/test-512m.bin"   # only used by the old single-stream speed test
    chown -R www-data:www-data "${diag_webroot}" 2>/dev/null || true

    # MTR backend Python script
    mkdir -p "$(dirname "${backend_script}")"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/mtr-backend.py" -o "${backend_script}"
    chmod 755 "${backend_script}"

    # Grant mtr raw socket capability (runs as restricted user, no root needed)
    # mtr-packet is the helper that actually opens the raw socket
    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr)"        2>/dev/null || true
    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr-packet)" 2>/dev/null || true

    # Dedicated system user for mtr-backend
    id mtr-backend &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    # Systemd service for mtr-backend
    cat > /etc/systemd/system/mtr-backend.service <<EOF
[Unit]
Description=3x-ui-pro MTR diagnostics backend
After=network.target

[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${backend_script} --port ${mtr_backend_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RemoveIPC=yes
# mtr-packet opens raw ICMP sockets. NoNewPrivileges=yes strips the file
# capability off the mtr binary, so grant CAP_NET_RAW the systemd-native way
# (ambient caps survive NoNewPrivileges). Empty here = mtr fails with
# "Failure to open IPv4 sockets: Permission denied".
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtr-backend

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtr-backend
    systemctl restart mtr-backend

    msg_ok "Network diagnostics installed at https://${domain}/${panel_path}/diag (panel login required)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM TUNING (BBR + kernel params)
# ─────────────────────────────────────────────────────────────────────────────
tune_system() {
    local params=(
        "net.core.default_qdisc=fq"
        "net.ipv4.tcp_congestion_control=bbr"
        "fs.file-max=2097152"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.ipv4.tcp_rmem=4096 87380 16777216"
        "net.ipv4.tcp_wmem=4096 65536 16777216"
    )
    for p in "${params[@]}"; do
        grep -qxF "$p" /etc/sysctl.conf || echo "$p" >> /etc/sysctl.conf
    done
    sysctl -p
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON JOBS
# ─────────────────────────────────────────────────────────────────────────────
setup_cron() {
    crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|cloudflareips" | crontab -
    (crontab -l 2>/dev/null; echo '@daily   x-ui restart > /dev/null 2>&1 && nginx -s reload')    | crontab -
    # Certs were issued with --standalone: renewal needs port 80 free,
    # so stop nginx for the few seconds certbot runs
    (crontab -l 2>/dev/null; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
    ufw disable

    local ssh_port ssh_config ssh_socket
    local -a ssh_ports=(22)
    local -A ssh_seen=()

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_ports+=("${SSH_CONNECTION##* }")
    fi

    if ssh_config=$(/usr/sbin/sshd -T 2>/dev/null); then
        while read -r ssh_port; do
            ssh_ports+=("$ssh_port")
        done < <(
            awk '$1 == "port" {print $2}' <<< "$ssh_config"
        )
    else
        msg_inf "Не удалось прочитать конфигурацию sshd."
    fi

    for ssh_socket in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$ssh_socket"; then
            while read -r ssh_port; do
                ssh_ports+=("$ssh_port")
            done < <(
                systemctl show "$ssh_socket" \
                    --property=Listen --value 2>/dev/null |
                awk '{
                    for (i = 2; i <= NF; i++) {
                        if ($i == "(Stream)") {
                            p = $(i-1)
                            sub(/^.*:/, "", p)
                            if (p ~ /^[0-9]+$/) print p
                        }
                    }
                }'
            )
        fi
    done

    for ssh_port in "${ssh_ports[@]}"; do
        [[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] || continue
        ssh_port=$((10#$ssh_port))
        (( ssh_port >= 1 && ssh_port <= 65535 )) || continue

        [[ -n "${ssh_seen[$ssh_port]:-}" ]] && continue
        ufw allow "${ssh_port}/tcp" || return 1
        ssh_seen[$ssh_port]=1
        msg_inf "SSH: разрешён TCP-порт ${ssh_port}"
    done
    ufw allow 80/tcp || return 1
    ufw allow 443/tcp || return 1
    ufw allow 443/udp || return 1

    ufw allow "${panel_port}/tcp" || return 1
    ufw allow "${sub_port}/tcp" || return 1
    ufw allow "${ws_port}/tcp" || return 1
    ufw allow "${trojan_port}/tcp" || return 1

    local internal_port
    for internal_port in 7443 8443 9443 "$mtr_backend_port"; do
        ufw allow in on lo proto tcp to any port "$internal_port" \
            || return 1
    done
    
    ufw --force enable || return 1
    ufw status numbered
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW RESULTS
# ─────────────────────────────────────────────────────────────────────────────
show_results() {
    clear
    if systemctl is-active --quiet x-ui; then
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
        echo -e "Username:  ${config_username}\n"
        echo -e "Password:  ${config_password}\n"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Network Diagnostics (panel login required): https://${domain}/${panel_path}/diag\n"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Telegram WEB proxy (shared secret):"
        printf 'https://t.me/webproxy?server=%s&secret=%s\n' "$domain" "$telegram_secret"
        msg_inf "Please save this screen!"
    else
        nginx -t
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_err "x-ui or nginx check failed. Try on a clean Linux install."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    validate_domains
    prepare_lucx_installer
    backup_before_lucx
    clean_previous_install
    install_packages
    get_server_ip
    get_ssl_certs

    if systemctl is-active --quiet x-ui; then
        x-ui restart
    else
        install_panel
    fi

    configure_xui_db
    configure_telegram_web
    restore_clients
    configure_nginx
    install_clash_sub
    install_fake_site
    install_diagnostics
    tune_system
    setup_cron
    setup_firewall || {
        msg_err "Не удалось настроить UFW. Проверьте правила файервола."
        exit 1
    }

    if ! systemctl is-enabled --quiet x-ui; then
        systemctl daemon-reload && systemctl enable x-ui.service
    fi
    x-ui restart

    # Confirm the managed relay started; do not claim success for a dead inbound.
    local ready=0 attempt
    for attempt in {1..30}; do
        if curl -fsS --max-time 2 -H "Host: ${domain}" \
            "http://127.0.0.1:${telegram_relay_port}/" >/dev/null; then
            ready=1; break
        fi
        sleep 2
    done
    if (( ready == 0 )); then
        msg_err "Telegram WEB relay failed to start. Check journalctl -u x-ui and panel tunnel logs."
        exit 1
    fi
    show_results
}
main
