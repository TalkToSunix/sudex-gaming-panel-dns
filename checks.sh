#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
bash -n install.sh
bash install.sh --help >/dev/null
[[ $(bash install.sh --version) == 0.1.0 ]]
if bash install.sh --unknown >/dev/null 2>&1; then echo 'Unknown flag accepted'; exit 1; fi
if bash install.sh --status --install >/dev/null 2>&1; then echo 'Conflicting modes accepted'; exit 1; fi
source ./install.sh
validate_clients ''
validate_clients '192.0.2.1,2001:db8::/64,10.0.0.0/8'
for value in '0.0.0.0/0' '::/0' 'bad-ip' '192.0.2.1,,10.0.0.1' '$(touch /tmp/sudex-unsafe)' '-1'; do
    if validate_clients "$value" >/dev/null 2>&1; then echo "Invalid client accepted: $value"; exit 1; fi
done
# dig can exit successfully for SERVFAIL/NXDOMAIN. These must not pass DNS checks.
dig() { printf '%s\n' "$DIG_REPLY"; }
DIG_REPLY=';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1'
dns_ok 127.0.0.1
for DIG_REPLY in 'status: SERVFAIL, ANSWER: 0' 'status: NXDOMAIN, ANSWER: 0' 'status: NOERROR, ANSWER: 0'; do
    if dns_ok 127.0.0.1; then echo 'Failed DNS response passed'; exit 1; fi
done
dig() { return 9; }
if dns_ok 127.0.0.1; then echo 'DNS timeout passed'; exit 1; fi
# Validate automatic rollback dispatch without modifying the host.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
if (
    BACKUP=test-backup CHANGING=1
    restore() { printf '%s\n' "$1" > "$fixture/restored"; }
    false || on_failure 123
) >/dev/null 2>&1; then echo 'Failure handler exited successfully'; exit 1; fi
[[ $(cat "$fixture/restored") == test-backup ]]
rm "$fixture/restored"
if (
    CHANGING=0
    restore() { touch "$fixture/restored"; }
    false || on_failure 123
) >/dev/null 2>&1; then exit 1; fi
[[ ! -f $fixture/restored ]]
if restore /tmp/not-a-backup >/dev/null 2>&1; then echo 'Invalid restore path accepted'; exit 1; fi
printf 'PASS: syntax, CLI, client validation, DNS health checks, rollback dispatch.\n'
printf 'Ubuntu integration / reboot / remote reachability have NOT been tested here.\n'
