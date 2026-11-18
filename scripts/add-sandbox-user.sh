#!/usr/bin/env bash
# scripts/add-sandbox-user.sh — give a person an account on the sandbox host.
# Root only. The one admin action per user; everything after it they do
# themselves with `sandbox setup`.
#
#   sudo ./scripts/add-sandbox-user.sh <username> <public-key> [<public-key> ...]
#   cat their_key.pub | sudo ./scripts/add-sandbox-user.sh <username> -
#
# Each <public-key> is a file (id_ed25519.pub) or the key text itself
# ("ssh-ed25519 AAAA... them@laptop"). Re-running adds keys and changes nothing
# else, so it is also how a user gets a second key.
#
# The account is a plain local one, made with useradd. That is what allocates
# the /etc/subuid and /etc/subgid ranges rootless podman cannot run without, and
# it gets NO sudo: running the sandbox needs none, and an account without sudo
# cannot read anyone else's tokens. (SERVER.md, "Adding a user", route B. On a GCP
# host, project-metadata SSH keys are the other route; they come with sudo.)
set -euo pipefail

die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ok()  { printf '  \033[1;32mok\033[0m      %s\n' "$*"; }

[[ "$(id -u)" == 0 ]] || die "run as root (sudo)."
(( $# >= 2 )) || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

user="$1"; shift
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "'$user' is not a valid username."

# Collect and validate keys before touching anything.
keys=()
add_key_text() {
    local k
    while IFS= read -r k; do
        k="${k%%$'\r'}"
        [[ -z "$k" || "$k" == \#* ]] && continue
        ssh-keygen -l -f <(printf '%s\n' "$k") >/dev/null 2>&1 || die "not a valid SSH public key: ${k:0:40}..."
        [[ "$k" == *"PRIVATE KEY"* ]] && die "that is a PRIVATE key. Ask for the .pub file."
        keys+=("$k")
    done
}
for src in "$@"; do
    if [[ "$src" == "-" ]]; then
        add_key_text
    elif [[ -f "$src" ]]; then
        add_key_text < "$src"
    else
        add_key_text <<<"$src"
    fi
done
(( ${#keys[@]} )) || die "no public keys given."

if id "$user" >/dev/null 2>&1; then
    ok "account ${user} exists"
else
    # On a REBUILT VM the data disk already holds this user's files, owned by the
    # uid they had before. useradd would hand out the next free uid instead, and
    # every file they own would then belong to someone else, or to no one. So
    # when their directory exists, re-create the account with its owner's uid.
    existing="/mnt/sandbox/users/${user}"
    note_uid=""
    if [[ -d "$existing" ]]; then
        old_uid=$(stat -c %u "$existing")
        old_gid=$(stat -c %g "$existing")
        if getent passwd "$old_uid" >/dev/null; then
            die "${existing} is owned by uid ${old_uid}, which already belongs to $(getent passwd "$old_uid" | cut -d: -f1)."
        fi
        if ! getent group "$old_gid" >/dev/null; then
            groupadd --gid "$old_gid" "$user"
        elif [[ "$(getent group "$old_gid" | cut -d: -f1)" != "$user" ]]; then
            die "${existing} has gid ${old_gid}, which already belongs to group $(getent group "$old_gid" | cut -d: -f1)."
        fi
        useradd --create-home --shell /bin/bash --uid "$old_uid" --gid "$old_gid" "$user"
        note_uid=" with uid ${old_uid}, the owner of ${existing}"
    else
        useradd --create-home --shell /bin/bash --user-group "$user"
    fi
    ok "created account ${user}${note_uid} (no password, no sudo)"
fi
if id -nG "$user" | tr ' ' '\n' | grep -qxE 'sudo|wheel|google-sudoers|admin'; then
    echo "  note    ${user} is in a sudo-capable group: $(id -nG "$user")" >&2
fi

# useradd allocates subordinate ids for new accounts (SUB_UID_* in login.defs).
# An account made some other way may lack them, so check rather than assume.
for f in /etc/subuid /etc/subgid; do
    if ! grep -q "^${user}:" "$f"; then
        start=$(awk -F: 'BEGIN{m=100000} {e=$2+$3; if (e>m) m=e} END{print m}' /etc/subuid /etc/subgid)
        usermod --add-subuids "${start}-$((start + 65535))" --add-subgids "${start}-$((start + 65535))" "$user"
        break
    fi
done
ok "subordinate ids: $(grep "^${user}:" /etc/subuid)"

home="$(getent passwd "$user" | cut -d: -f6)"
install -d -m 700 -o "$user" -g "$user" "${home}/.ssh"
ak="${home}/.ssh/authorized_keys"
touch "$ak"
added=0
for k in "${keys[@]}"; do
    # Compare on the key material, ignoring the trailing comment.
    material="$(awk '{print $1" "$2}' <<<"$k")"
    if ! grep -qF "$material" "$ak"; then
        printf '%s\n' "$k" >> "$ak"
        added=$((added + 1))
    fi
done
chown "$user:$user" "$ak"
chmod 600 "$ak"
ok "authorized_keys: ${added} added, $(grep -c . "$ak") total"

# Linger keeps the user's systemd instance (and so their tmux sessions, agents
# and host-side fiss-mcp) alive after they log out.
loginctl enable-linger "$user"
ok "linger enabled"

host="$(hostname)"
ip="$(curl -fsS -m 3 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')"
cat <<EOF

Send ${user} this:

    ssh ${user}@${ip}        # ${host}; from the Broad network or VPN
    sandbox setup            # once: logins, repos, everything else

EOF
