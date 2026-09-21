#!/bin/sh
# Canopy - `open` / `xdg-open` redirector: open things on the machine the
# person is actually sitting at, not the one the CLI happens to run on.
#
# Two arrangements put the agent and the human on different machines, and this
# one script serves both because only the DESTINATION differs:
#
#   SSH remote - Canopy runs the CLI on another host over ssh. The destination
#   is SSH_CONNECTION's client address, the machine that opened the connection.
#   ssh-claude-wrapper.sh installs this script into ~/.canopy/bin there and
#   prepends that directory to PATH for that one launch.
#
#   Mirror - the session is an ordinary LOCAL session of the host's own Canopy,
#   and another Mac is attached to it. No ssh at all: the request is left in
#   ~/.canopy/outbox/$CANOPY_OPEN_KEY/ for that Canopy, which streams the file
#   over the mirror connection. The directory exists only while a Mac is
#   attached, and it is checked HERE, at call time, rather than baked into the
#   environment at spawn: a mirror starts and stops while the CLI runs, and an
#   environment variable cannot be revoked.
#
# Neither arrangement is reachable when nobody is watching from elsewhere, and
# then this script is exactly the stock `open`.
#
# Scoping: PATH is prepended per CLI launch, so a hand-run `ssh host` shell and
# a terminal on the host keep the stock `open`.
#
# Every failure falls back to the real `open` on this host. Opening on the
# wrong screen beats not opening at all, and a broken redirect must not become
# a broken `open`.
set -u

self_name=$(basename -- "$0")
self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || self_dir=

# The real one: first match on PATH that is not this script's directory.
real_open=
saved_IFS=$IFS
IFS=:
for d in $PATH; do
    [ "$d" = "$self_dir" ] && continue
    if [ -x "$d/$self_name" ]; then
        real_open="$d/$self_name"
        break
    fi
done
IFS=$saved_IFS

passthrough() {
    [ -n "$real_open" ] || { echo "canopy: no $self_name on PATH" >&2; exit 127; }
    exec "$real_open" "$@"
}

[ $# -gt 0 ] || passthrough "$@"

# Flags (-a -R -e -n -b ...) carry too many meanings to re-target; and a
# directory opened on another machine is meaningless. Both stay here.
for a in "$@"; do
    case $a in
        -*) passthrough "$@" ;;
        *) [ -d "$a" ] && passthrough "$@" ;;
    esac
done

# Mirror: the host's own Canopy is running and holds the connection the
# watcher is on, so hand each request to it and exit - one small file per
# `open` in ~/.canopy/outbox/<key>/, an absolute path or a URL. It streams
# the bytes over that connection (`MirrorFileSender`), which is why this
# branch never touches ssh: measured, the handshake back to the watcher was
# ~1.2 s and the payload nothing. Written as .tmp then renamed, so the
# watcher never reads half a line. The directory exists only while a Mac is
# attached; absent, nobody is watching and the stock `open` is right.
if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${CANOPY_OPEN_KEY:-}" ] &&
   [ -d "$HOME/.canopy/outbox/$CANOPY_OPEN_KEY" ]; then
    outbox="$HOME/.canopy/outbox/$CANOPY_OPEN_KEY"
    for a in "$@"; do
        case $a in
            http://*|https://*|mailto:*|/*) entry=$a ;;
            *)
                if [ -e "$a" ]; then entry=$PWD/$a
                else [ -n "$real_open" ] && "$real_open" "$a"; continue
                fi ;;
        esac
        id=$(uuidgen 2>/dev/null || echo "$$-$(date +%s)-$RANDOM")
        printf '%s\n' "$entry" > "$outbox/$id.tmp" && mv -f "$outbox/$id.tmp" "$outbox/$id"
    done
    exit 0
fi

# SSH remote: the destination is the machine that opened the connection.
mac=
[ -n "${SSH_CONNECTION:-}" ] && mac=${SSH_CONNECTION%% *}
# A host with whitespace, or one that would read as an ssh flag, is not a
# host. Nor is one with a colon: scp splits the target on it, so a raw IPv6
# address cannot be shipped to as written, and it is declined here rather
# than bracketed (a link-local one would also need its scope).
case "$mac" in
    ""|-*|*[!-.%_0-9A-Za-z@]*) passthrough "$@" ;;
esac

inbox="Downloads/from-$(hostname -s 2>/dev/null || hostname || echo remote)"

# Wrap in single quotes, splitting any embedded quote - the same escape
# ssh-claude-wrapper.sh uses, and for the same reason: ssh hands the string to
# the far side's LOGIN shell, which is fish on the Macs this runs against.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ONE connection per open, and the connection is kept for a minute. Measured
# studio -> Mac: a bare ssh costs ~1.2 s and the 600 KB payload nothing, so
# the first shape (mkdir + scp + open, three connections) took 4.2 s and
# read as "did that work?". Piping the file through the one command that
# also creates the directory and opens it is 1.2 s; a reused master is 0.4 s.
cm="$HOME/.canopy/cm-%C"
mac_sh() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o ControlMaster=auto -o ControlPath="$cm" -o ControlPersist=60 \
        "$mac" "/bin/sh -c $(sq "$1")"
}

for a in "$@"; do
    sent=0
    case $a in
        http://*|https://*|mailto:*)
            mac_sh 'open '"$(sq "$a")" </dev/null && sent=1
            ;;
        *)
            if [ -e "$a" ]; then
                dest="$inbox/$(basename -- "$a")"
                mac_sh 'd="$HOME"/'"$(sq "$inbox")"'; f="$HOME"/'"$(sq "$dest")"'; mkdir -p "$d" && cat > "$f" && open "$f"' < "$a" && sent=1
            fi
            ;;
    esac
    # A hop that failed, or an argument we could not ship, leaves nothing on
    # either screen - so let the real one decide what it is.
    [ "$sent" = 1 ] || { [ -n "$real_open" ] && "$real_open" "$a"; }
done
