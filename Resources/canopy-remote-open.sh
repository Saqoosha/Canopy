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
#   and another Mac is attached to it. There is no ssh, so the destination is
#   read from ~/.canopy/viewers/$CANOPY_OPEN_KEY, which that Canopy writes when
#   a Mac attaches and removes when it detaches. It is read HERE, at call time,
#   rather than baked into the environment at spawn: a mirror starts and stops
#   while the CLI runs, and an environment variable cannot be revoked.
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

mac=
if [ -n "${SSH_CONNECTION:-}" ]; then
    mac=${SSH_CONNECTION%% *}
elif [ -n "${CANOPY_OPEN_KEY:-}" ] && [ -r "$HOME/.canopy/viewers/$CANOPY_OPEN_KEY" ]; then
    mac=$(cat "$HOME/.canopy/viewers/$CANOPY_OPEN_KEY" 2>/dev/null)
fi
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
mac_sh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$mac" "/bin/sh -c $(sq "$1")"; }

mac_sh 'mkdir -p "$HOME"/'"$(sq "$inbox")" || passthrough "$@"

for a in "$@"; do
    sent=0
    case $a in
        http://*|https://*|mailto:*)
            mac_sh 'open '"$(sq "$a")" && sent=1
            ;;
        *)
            if [ -e "$a" ]; then
                # `./` so a relative name with a colon is not read as remote.
                case $a in /*) src=$a ;; *) src=./$a ;; esac
                scp -q -o BatchMode=yes -o ConnectTimeout=10 "$src" "$mac:$inbox/" &&
                    mac_sh 'open "$HOME"/'"$(sq "$inbox/$(basename -- "$a")")" && sent=1
            fi
            ;;
    esac
    # A hop that failed, or an argument we could not ship, leaves nothing on
    # either screen - so let the real one decide what it is.
    [ "$sent" = 1 ] || { [ -n "$real_open" ] && "$real_open" "$a"; }
done
