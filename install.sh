#!/usr/bin/env bash
# Sudex: Ubuntu preparation for an existing, configured AdGuard Home.
set -Eeuo pipefail
export LC_ALL=C
VERSION=0.1.0
AGH=/opt/AdGuardHome/AdGuardHome
CONFIG=/opt/AdGuardHome/AdGuardHome.yaml
BASE=/var/lib/sudex
BACKUP=''
CLIENTS=''
SSH_PORT=''
CHANGING=0
WARNINGS=0
FILES=(etc/resolv.conf etc/systemd/resolved.conf.d/90-sudex.conf
       etc/systemd/system/AdGuardHome.service
       etc/systemd/system/AdGuardHome.service.d/90-sudex.conf
       etc/sysctl.d/90-sudex.conf etc/apt/apt.conf.d/90-sudex
       etc/ufw etc/default/ufw)
PACKAGES=(curl ca-certificates jq ufw ethtool dnsutils iproute2
          unattended-upgrades apt-listchanges)
log() { printf '\n[%s] %s\n' "$(date +%T)" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
usage() {
    cat <<EOF
Sudex $VERSION — Ubuntu / existing AdGuard Home
  sudo bash install.sh                       Interactive menu
  sudo bash install.sh --check                Read-only preflight
  sudo bash install.sh --install              Install all (local DNS only)
  sudo bash install.sh --install --clients IP_OR_CIDR,IP_OR_CIDR
  sudo bash install.sh --status               Service and DNS checks
  sudo bash install.sh --restore /var/lib/sudex/backups/ID
  bash install.sh --help | --version
Remote use: pass explicit client networks. No public DNS allow rule is added.
Packages are downloaded from your Ubuntu package sources. Internet required.
EOF
}
require_root() { [[ $EUID == 0 ]] || die 'Run with sudo or as root.'; }
platform() {
    [[ $(uname -s) == Linux ]] || die 'Ubuntu Linux is required.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} =~ ^(22\.04|24\.04)$ ]] || die 'Supported targets: Ubuntu 22.04 / 24.04.'
    [[ -d /run/systemd/system ]] || die 'A systemd host is required; containers are unsupported.'
    for cmd in ip ss systemctl python3 flock timeout; do
        command -v "$cmd" >/dev/null || die "Missing prerequisite: $cmd"
    done
}
validate_clients() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1]
if value:
    for item in value.split(','):
        net = ipaddress.ip_network(item, strict=False)
        if net.prefixlen == 0:
            raise SystemExit('Unrestricted /0 networks are not supported.')
PY
}
detect_ssh() {
    local remote rport localip lport rest
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r remote rport localip lport rest <<< "$SSH_CONNECTION"
        [[ $lport =~ ^[0-9]+$ && $lport -gt 0 && $lport -le 65535 ]] || die 'Cannot identify current SSH port.'
        SSH_PORT=$lport
    elif command -v sshd >/dev/null; then
        SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u | paste -sd, -)
    elif [[ -x /usr/sbin/sshd ]]; then
        SSH_PORT=$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u | paste -sd, -)
    fi
    [[ $SSH_PORT =~ ^[0-9]+$ ]] || die 'Cannot identify one SSH port. Run through your actual SSH connection.'
    ss -H -lnt | awk '{print $4}' | grep -Eq ":${SSH_PORT}$" || die "SSH port $SSH_PORT is not listening."
}
preflight() {
    require_root; platform
    [[ -x $AGH && -s $CONFIG ]] || die 'Install and configure AdGuard Home in /opt/AdGuardHome first. This installer prepares its host; it does not download AdGuard.'
    command -v dpkg-query >/dev/null || die 'dpkg is required.'
    validate_clients "$CLIENTS"
    detect_ssh
    "$AGH" --check-config -c "$CONFIG" -w /opt/AdGuardHome
    # Reject customized units instead of overwriting their command or working dir.
    if systemctl cat AdGuardHome.service >/dev/null 2>&1; then
        local execstart
        execstart=$(systemctl show AdGuardHome.service -p ExecStart --value)
        [[ $execstart == *"/opt/AdGuardHome/AdGuardHome"* && $execstart == *"/opt/AdGuardHome/AdGuardHome.yaml"* ]] || die 'Existing AdGuardHome unit uses custom paths. Refusing to replace it.'
    fi
    local collisions
    collisions=$(ss -H -lntup '( sport = :53 )' | grep -vE 'AdGuardHome|systemd-resolve' || true)
    [[ -z $collisions ]] || die "Another process owns port 53: $collisions"
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        die 'UFW is already active. This version only provisions hosts with inactive UFW; existing rules need manual review.'
    fi
    # Existing firewall frameworks can conflict with UFW, particularly Docker.
    for svc in docker firewalld nftables; do
        if systemctl is-active --quiet "$svc"; then
            die "Active $svc detected. This version requires a dedicated host without another firewall manager."
        fi
    done
    log "Ubuntu $VERSION_ID; SSH TCP/$SSH_PORT; DNS clients: ${CLIENTS:-local host only}"
    ip -br address
    ip -4 route show default
    ip -6 route show default
    log 'Plan: packages, AdGuard service, DNS, BBR/FQ/TFO if supported, UFW, security updates, NTP.'
    log 'UFW will block unsolicited incoming traffic except SSH and specified DNS clients. Preserve any other services before installing.'
}
snapshot() {
    umask 077
    mkdir -p "$BASE/backups"
    BACKUP=$(mktemp -d "$BASE/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    mkdir "$BACKUP/files"
    local rel
    for rel in "${FILES[@]}"; do
        if [[ -e /$rel || -L /$rel ]]; then
            mkdir -p "$BACKUP/files/$(dirname "$rel")"
            cp -a "/$rel" "$BACKUP/files/$rel"
        else
            printf '%s\n' "$rel" >> "$BACKUP/absent"
        fi
    done
    systemctl is-active --quiet AdGuardHome.service && touch "$BACKUP/agh-active"
    systemctl is-enabled --quiet AdGuardHome.service && touch "$BACKUP/agh-enabled"
    systemctl is-active --quiet systemd-resolved.service && touch "$BACKUP/resolved-active"
    systemctl is-enabled --quiet unattended-upgrades.service && touch "$BACKUP/updates-enabled"
    systemctl is-active --quiet unattended-upgrades.service && touch "$BACKUP/updates-active"
    timedatectl show -p NTP --value > "$BACKUP/ntp"
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen; do
        printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$BACKUP/sysctl-runtime"
    done
    touch "$BACKUP/complete"
    log "Backup: $BACKUP"
}
restore() {
    local dir=$1 rel failed=0
    [[ $dir == "$BASE/backups/"* && -f $dir/complete && -d $dir/files ]] || { printf 'Invalid Sudex backup\n' >&2; return 1; }
    log "Restoring configuration from $dir"
    systemctl stop AdGuardHome.service || failed=1
    if command -v ufw >/dev/null; then ufw --force disable || failed=1; fi
    for rel in "${FILES[@]}"; do
        if [[ -e $dir/files/$rel || -L $dir/files/$rel ]]; then
            rm -rf -- "/$rel"
            mkdir -p "/$(dirname "$rel")"
            cp -a "$dir/files/$rel" "/$rel" || failed=1
        elif [[ -f $dir/absent ]] && grep -Fxq "$rel" "$dir/absent"; then
            rm -rf -- "/$rel" || failed=1
        fi
    done
    systemctl daemon-reload || failed=1
    while IFS= read -r rel; do sysctl -w "$rel" || failed=1; done < "$dir/sysctl-runtime"
    if [[ -f $dir/agh-enabled ]]; then systemctl enable AdGuardHome.service || failed=1
    else systemctl disable AdGuardHome.service 2>/dev/null || true; fi
    if [[ -f $dir/resolved-active ]]; then systemctl restart systemd-resolved.service || failed=1; fi
    if [[ -f $dir/agh-active ]]; then systemctl start AdGuardHome.service || failed=1; fi
    if [[ -f $dir/updates-enabled ]]; then systemctl enable unattended-upgrades.service || failed=1
    else systemctl disable unattended-upgrades.service || failed=1; fi
    if [[ -f $dir/updates-active ]]; then systemctl start unattended-upgrades.service || failed=1
    else systemctl stop unattended-upgrades.service || failed=1; fi
    timedatectl set-ntp "$(cat "$dir/ntp")" || failed=1
    log 'Restore finished. Installed packages remain installed.'
    return "$failed"
}
on_failure() {
    local code=$? line=$1
    trap - ERR INT TERM
    printf '\nInstallation failed at line %s (exit %s).\n' "$line" "$code" >&2
    if [[ $CHANGING == 1 ]]; then
        if ! restore "$BACKUP"; then printf '\nRESTORE INCOMPLETE. Use the provider console and backup: %s\n' "$BACKUP" >&2; fi
    fi
    exit 1
}
packages() {
    log '1/7 Installing Ubuntu packages'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"
}
service_dns() {
    log '2/7 Preparing service and releasing the DNS stub port'
    # AdGuard must already be configured for local resolution before we switch the host.
    if ! systemctl cat AdGuardHome.service >/dev/null 2>&1; then
        cat > /etc/systemd/system/AdGuardHome.service <<'UNIT'
[Unit]
Description=AdGuard Home
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    fi
    mkdir -p /etc/systemd/system/AdGuardHome.service.d
    printf '[Service]\nRestart=on-failure\nRestartSec=5\n' > /etc/systemd/system/AdGuardHome.service.d/90-sudex.conf
    if systemctl is-active --quiet systemd-resolved.service; then
        # Keep the host resolver usable while the stub is disabled. Use the
        # upstreams already discovered by resolved; never invent an address.
        if [[ $(readlink -f /etc/resolv.conf) == /run/systemd/resolve/stub-resolv.conf ]]; then
            [[ -s /run/systemd/resolve/resolv.conf ]] || { log 'No upstream resolver file from systemd-resolved.'; return 1; }
            grep -Eq '^nameserver[[:space:]]+' /run/systemd/resolve/resolv.conf || return 1
            local temporary_resolver
            temporary_resolver=$(mktemp /etc/.sudex-resolver.XXXXXX)
            cat /run/systemd/resolve/resolv.conf > "$temporary_resolver"
            chmod 644 "$temporary_resolver"
            mv -fT "$temporary_resolver" /etc/resolv.conf
        fi
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/90-sudex.conf
        systemctl restart systemd-resolved.service
    fi
    systemctl daemon-reload
    systemctl enable AdGuardHome.service
    systemctl restart AdGuardHome.service
    local attempt ready=0
    for attempt in {1..15}; do
        if systemctl is-active --quiet AdGuardHome.service && dns_ok 127.0.0.1; then ready=1; break; fi
        sleep 1
    done
    [[ $ready == 1 ]] || { log 'AdGuard did not resolve DNS on 127.0.0.1; aborting.'; return 1; }
    # Atomic replacement, after DNS succeeds. Original symlink is in the backup.
    local resolver
    resolver=$(mktemp /etc/.sudex-resolver.XXXXXX)
    printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:3\n' > "$resolver"
    chmod 644 "$resolver"
    mv -fT "$resolver" /etc/resolv.conf
}
dns_ok() {
    local reply
    reply=$(dig @"$1" example.com A +time=2 +tries=1 2>/dev/null) || return 1
    [[ $reply == *'status: NOERROR,'* && $reply =~ ANSWER:\ [1-9][0-9]* ]]
}
network() {
    log '3/7 Applying supported network settings'
    local key value
    : > /etc/sysctl.d/90-sudex.conf
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen; do
        case $key in
            net.core.default_qdisc) value=fq ;;
            net.ipv4.tcp_congestion_control) value=bbr ;;
            *) value=3 ;;
        esac
        if sysctl -w "$key=$value"; then
            [[ $(sysctl -n "$key") == "$value" ]]
            printf '%s=%s\n' "$key" "$value" >> /etc/sysctl.d/90-sudex.conf
        else warn "Unsupported $key; skipped."; fi
    done
}
firewall() {
    log '4/7 Configuring UFW'
    # Ensure UFW enforces both IPv4 and IPv6, even if it was disabled in its config.
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    # Insert DNS denials first, ahead of any inactive legacy broad allow rules.
    ufw insert 1 deny in proto tcp to any port 53
    ufw insert 1 deny in proto udp to any port 53
    local client
    local -a networks
    if [[ -n $CLIENTS ]]; then
        IFS=',' read -ra networks <<< "$CLIENTS"
        for client in "${networks[@]}"; do
            ufw insert 1 allow in proto tcp from "$client" to any port 53
            ufw insert 1 allow in proto udp from "$client" to any port 53
        done
    fi
    ufw insert 1 allow in proto tcp to any port "$SSH_PORT"
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    ufw status | grep -q '^Status: active'
}
updates_time() {
    log '5/7 Enabling security updates'
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/90-sudex
    systemctl enable --now unattended-upgrades.service
    log '6/7 Enabling time synchronization'
    if ! timedatectl set-ntp true; then warn 'NTP could not be enabled; check your time service.'; fi
}
status() {
    local failed=0 ip cidr
    systemctl is-active AdGuardHome.service || failed=1
    systemctl is-enabled AdGuardHome.service || failed=1
    if dns_ok 127.0.0.1; then log 'Local DNS: PASS'; else log 'Local DNS: FAIL'; failed=1; fi
    ss -lntup '( sport = :53 )'
    ufw status verbose
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen
    timedatectl status
    while read -r ip; do
        [[ -n $ip ]] || continue
        cidr=${ip%/*}
        if dns_ok "$cidr"; then log "DNS on $cidr: PASS"; else warn "DNS on $cidr did not answer. Check AdGuard listen addresses and access settings."; fi
    done < <(ip -o addr show scope global | awk '$3 == "inet" || $3 == "inet6" {print $4}')
    return "$failed"
}
install_all() {
    preflight
    mkdir -p /run/lock
    exec 9>/run/lock/sudex.lock
    flock -n 9 || die 'Another Sudex process is running.'
    umask 077
    mkdir -p /var/log/sudex
    exec > >(tee -a "/var/log/sudex/install-$(date +%Y%m%d-%H%M%S).log") 2>&1
    snapshot
    trap 'on_failure $LINENO' ERR
    trap 'false' INT TERM
    CHANGING=1
    packages
    service_dns
    network
    firewall
    updates_time
    log '7/7 Verifying installation'
    status
    CHANGING=0
    trap - ERR INT TERM
    log "Installation complete; warnings: $WARNINGS. Backup: $BACKUP"
    log 'AdGuard YAML, upstreams and admin credentials were preserved.'
    log 'External DNS reachability and provider firewall must be checked from a client.'
}
main() {
    local mode='' restore_dir='' choice
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) usage; return ;;
            --version) printf '%s\n' "$VERSION"; return ;;
            --check|--install|--status) [[ -z $mode ]] || die 'Choose one mode.'; mode=$1 ;;
            --clients) [[ $# -ge 2 ]] || die 'Missing clients.'; CLIENTS=$2; shift ;;
            --restore) [[ $# -ge 2 && -z $mode ]] || die 'Missing backup or conflicting mode.'; mode=$1; restore_dir=$2; shift ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done
    if [[ -z $mode ]]; then
        [[ -t 0 ]] || die 'Download this file first and run it in a terminal, or use --install.'
        printf '\n  Sudex %s\n\n  1) Install all\n  2) Check server (read-only)\n  3) Status\n  0) Exit\n\n' "$VERSION"
        read -r -p 'Select [0]: ' choice
        case ${choice:-0} in
            1) mode=--install
               printf '\nAllowed DNS client IPs/CIDRs, comma-separated. Empty = local host only.\n'
               read -r -p 'DNS clients: ' CLIENTS ;;
            2) mode=--check ;;
            3) mode=--status ;;
            0) return ;;
            *) die 'Invalid selection.' ;;
        esac
    fi
    case $mode in
        --install) install_all ;;
        --check) preflight ;;
        --status) require_root; platform; status ;;
        --restore) require_root; platform
                   exec 9>/run/lock/sudex.lock
                   flock -n 9 || die 'Another Sudex process is running.'
                   restore "$restore_dir" ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
