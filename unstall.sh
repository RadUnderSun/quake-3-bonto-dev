#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Q3 DEDICATED ONE-CLICK INSTALLER
#
# No Docker required.
#
# What this script does:
#   1. Removes previous ~/q3ded installation
#   2. Gets GHCR manifest
#   3. Resolves linux/amd64 image
#   4. Downloads ALL image layers
#   5. Extracts Docker layers into rootfs-fixed
#   6. Fixes permissions while applying layers
#   7. Creates runtime
#   8. Creates dynamic-loader wrappers
#   9. Creates local entrypoint
#  10. Starts dedicated_room_agent
#  11. Waits for rtc.json
#  12. Starts ioq3ded
#
# ============================================================

export LC_ALL=C

IMG="$HOME/q3ded"

# ------------------------------------------------------------
# IMAGE
# ------------------------------------------------------------

REGISTRY="ghcr.io"
REPOSITORY="doszoner/q3ded"
TAG="20260920-29517a4"

IMAGE="$REGISTRY/$REPOSITORY:$TAG"

# ------------------------------------------------------------
# DEFAULT SERVER CONFIG
# ------------------------------------------------------------

SERVER_NAME="${SERVER_NAME:-Local Q3 Test}"
ROOM_NAME="${ROOM_NAME:-room.q3ded.local}"

MODE="${MODE:-duel}"
MAP="${MAP:-q3dm17}"

MAXCLIENTS="${MAXCLIENTS:-2}"
PORT="${PORT:-27960}"

TIMELIMIT="${TIMELIMIT:-15}"
FRAGLIMIT="${FRAGLIMIT:-30}"

RTC_WAIT_SECS="${RTC_WAIT_SECS:-30}"

NET_PEER_SERVER="${NET_PEER_SERVER:-wss://net.js-dos.com:444}"

# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

log() {
    echo
    echo "==> $*"
}

ok() {
    echo "[OK] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

trap 'echo; echo "[ERROR] Installation failed at line $LINENO" >&2' ERR

# ------------------------------------------------------------
# CHECKS
# ------------------------------------------------------------

log "Checking dependencies"

command -v bash >/dev/null || die "bash is required"
command -v curl >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required"
command -v tar >/dev/null || die "tar is required"

ok "Basic dependencies present"

# ------------------------------------------------------------
# CLEAN EVERYTHING
# ------------------------------------------------------------

log "Removing previous installation"

if [ -d "$IMG" ]; then
    rm -rf "$IMG"
fi

mkdir -p \
    "$IMG" \
    "$IMG/layers" \
    "$IMG/logs" \
    "$IMG/runtime" \
    "$IMG/rootfs-fixed"

ok "Previous installation removed"

# ------------------------------------------------------------
# GHCR TOKEN
# ------------------------------------------------------------

log "Getting GHCR pull token"

TOKEN_JSON="$IMG/token.json"

curl -fsSL \
    "https://ghcr.io/token?scope=repository:${REPOSITORY}:pull" \
    -o "$TOKEN_JSON"

TOKEN="$(python3 - "$TOKEN_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

token = data.get("token") or data.get("access_token")

if not token:
    raise SystemExit("No token in GHCR response")

print(token)
PY
)"

[ -n "$TOKEN" ] || die "Empty GHCR token"

ok "GHCR token obtained"

AUTH_HEADER="Authorization: Bearer $TOKEN"

# ------------------------------------------------------------
# MANIFEST
# ------------------------------------------------------------

log "Getting image manifest"

MANIFEST="$IMG/manifest.json"

curl -fsSL \
    -H "$AUTH_HEADER" \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/${REPOSITORY}/manifests/${TAG}" \
    -o "$MANIFEST"

ok "Manifest downloaded"

# ------------------------------------------------------------
# RESOLVE AMD64
# ------------------------------------------------------------

log "Resolving linux/amd64 image"

MANIFEST_DIGEST="$(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

# Already a single manifest.
if data.get("config"):
    print("")
    raise SystemExit

for m in data.get("manifests", []):
    p = m.get("platform", {})
    if p.get("os") == "linux" and p.get("architecture") == "amd64":
        print(m["digest"])
        raise SystemExit

raise SystemExit("linux/amd64 manifest not found")
PY
)"

if [ -n "$MANIFEST_DIGEST" ]; then

    echo "linux/amd64 digest: $MANIFEST_DIGEST"

    curl -fsSL \
        -H "$AUTH_HEADER" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
        "https://ghcr.io/v2/${REPOSITORY}/manifests/${MANIFEST_DIGEST}" \
        -o "$IMG/amd64-manifest.json"

    cp "$IMG/amd64-manifest.json" "$MANIFEST"

else

    echo "Manifest is already platform-specific."

fi

ok "linux/amd64 manifest selected"

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

log "Downloading image config"

CONFIG_DIGEST="$(python3 - "$MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print(data["config"]["digest"])
PY
)"

CONFIG_HEX="${CONFIG_DIGEST#sha256:}"
CONFIG="$IMG/config.json"

echo "Config: $CONFIG_DIGEST"

curl -fsSL \
    -H "$AUTH_HEADER" \
    "https://ghcr.io/v2/${REPOSITORY}/blobs/${CONFIG_DIGEST}" \
    -o "$CONFIG"

ok "Config saved: $(du -h "$CONFIG" | awk '{print $1}')"

# ------------------------------------------------------------
# IMAGE METADATA
# ------------------------------------------------------------

log "Reading image metadata"

python3 - "$CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    c = json.load(f)

print("OS           :", c.get("os"))
print("Architecture :", c.get("architecture"))
print("User         :", c.get("config", {}).get("User"))
print("WorkingDir   :", c.get("config", {}).get("WorkingDir"))
print("Entrypoint   :", c.get("config", {}).get("Entrypoint"))
print("Cmd          :", c.get("config", {}).get("Cmd"))
PY

# ------------------------------------------------------------
# LAYERS
# ------------------------------------------------------------

log "Reading image layers"

python3 - "$MANIFEST" > "$IMG/layers.list" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for layer in data["layers"]:
    print(
        layer["digest"],
        layer.get("mediaType", ""),
        layer.get("size", 0)
    )
PY

LAYER_COUNT="$(wc -l < "$IMG/layers.list" | tr -d ' ')"

echo "Layers: $LAYER_COUNT"

[ "$LAYER_COUNT" -gt 0 ] || die "No layers found"

# ------------------------------------------------------------
# DOWNLOAD ALL LAYERS
# ------------------------------------------------------------

INDEX=0

while read -r DIGEST MEDIA SIZE; do

    INDEX=$((INDEX + 1))

    HEX="${DIGEST#sha256:}"
    LAYER="$IMG/layers/${HEX}.layer"

    echo
    echo "Layer $INDEX/$LAYER_COUNT"
    echo "  digest : $DIGEST"
    echo "  media  : $MEDIA"
    echo "  size   : $SIZE"

    if [ -s "$LAYER" ]; then
        echo "  already downloaded"
    else

        echo
        echo "==> Downloading layer $INDEX/$LAYER_COUNT"

        curl -fL \
            --retry 5 \
            --retry-delay 2 \
            -H "$AUTH_HEADER" \
            "https://ghcr.io/v2/${REPOSITORY}/blobs/${DIGEST}" \
            -o "$LAYER"

        ok "Layer downloaded"

    fi

done < "$IMG/layers.list"

# ------------------------------------------------------------
# CREATE FIXED EXTRACTOR
# ------------------------------------------------------------

log "Creating safe Docker layer extractor"

cat > "$IMG/extract_layers.py" <<'PYTHON'
#!/usr/bin/env python3

import os
import sys
import tarfile
import shutil

root = os.path.abspath(sys.argv[1])
layer = sys.argv[2]


def safe_join(base, name):
    name = name.lstrip("/")
    dest = os.path.abspath(os.path.join(base, name))

    if dest != base and not dest.startswith(base + os.sep):
        raise RuntimeError(f"unsafe archive path: {name}")

    return dest


def make_writable(path):
    """
    Make an existing object removable/replacable.

    Docker image layers can contain files whose mode comes from the
    previous layer. Since we are extracting as an unprivileged user,
    make objects writable before replacing/removing them.
    """

    try:
        if os.path.islink(path):
            return

        if os.path.isdir(path):
            os.chmod(path, 0o755)
        else:
            os.chmod(path, 0o700)

    except OSError:
        pass


def remove_path(path):
    try:

        if os.path.islink(path) or os.path.isfile(path):
            make_writable(path)
            os.unlink(path)

        elif os.path.isdir(path):
            make_writable(path)
            shutil.rmtree(path)

    except FileNotFoundError:
        pass


def ensure_parent(path):
    parent = os.path.dirname(path)

    if not parent:
        return

    os.makedirs(parent, exist_ok=True)

    # Make every directory on the path writable enough for
    # subsequent layers.
    current = parent

    while current.startswith(root + os.sep):

        try:
            os.chmod(current, 0o755)
        except OSError:
            pass

        if current == root:
            break

        current = os.path.dirname(current)


def extract_member(tf, member):

    name = member.name

    if not name or name == ".":
        return

    dest = safe_join(root, name)

    base = os.path.basename(name)

    # Docker overlay whiteout: remove everything in directory.
    if base == ".wh..wh..opq":

        directory = os.path.dirname(dest)

        if os.path.isdir(directory):

            for child in os.listdir(directory):
                remove_path(os.path.join(directory, child))

        return

    # Docker overlay whiteout: remove target.
    if base.startswith(".wh."):

        target_name = base[4:]
        target = os.path.join(
            os.path.dirname(dest),
            target_name
        )

        remove_path(target)

        return

    ensure_parent(dest)

    # Directory
    if member.isdir():

        if os.path.exists(dest) and not os.path.isdir(dest):
            remove_path(dest)

        os.makedirs(dest, exist_ok=True)

        try:
            os.chmod(
                dest,
                member.mode & 0o7777
            )
        except OSError:
            pass

        return

    # Symlink
    if member.issym():

        remove_path(dest)

        target = member.linkname

        os.symlink(target, dest)

        return

    # Hardlink
    if member.islnk():

        remove_path(dest)

        link_target = safe_join(
            root,
            member.linkname
        )

        if not os.path.exists(link_target):
            raise RuntimeError(
                f"hardlink target missing: {member.linkname}"
            )

        os.link(link_target, dest)

        return

    # Regular file
    if member.isfile():

        remove_path(dest)

        src = tf.extractfile(member)

        if src is None:
            raise RuntimeError(
                f"cannot read archive member: {name}"
            )

        with open(dest, "wb") as out:
            shutil.copyfileobj(src, out)

        try:
            os.chmod(
                dest,
                member.mode & 0o7777
            )
        except OSError:
            pass

        try:
            os.utime(
                dest,
                (member.mtime, member.mtime),
                follow_symlinks=False
            )
        except OSError:
            pass

        return

    # Devices/FIFOs/etc.
    if member.ischr() or member.isblk() or member.isfifo():

        if os.geteuid() != 0:
            print(
                f"WARNING: skipping special file {name}",
                file=sys.stderr
            )
            return

        remove_path(dest)

        tf.extract(
            member,
            root,
            set_attrs=True
        )

        return

    print(
        f"WARNING: unsupported archive member {name}",
        file=sys.stderr
    )


with tarfile.open(layer, mode="r:*") as tf:

    for member in tf:
        extract_member(tf, member)
PYTHON

chmod +x "$IMG/extract_layers.py"

ok "Extractor created"

# ------------------------------------------------------------
# EXTRACT ALL LAYERS IN ORDER
# ------------------------------------------------------------

log "Extracting Docker layers"

INDEX=0

while read -r DIGEST MEDIA SIZE; do

    INDEX=$((INDEX + 1))

    HEX="${DIGEST#sha256:}"
    LAYER="$IMG/layers/${HEX}.layer"

    echo
    echo "Layer $INDEX/$LAYER_COUNT"
    echo "  $LAYER"

    [ -s "$LAYER" ] || die "Missing layer: $LAYER"

    python3 \
        "$IMG/extract_layers.py" \
        "$IMG/rootfs-fixed" \
        "$LAYER"

    ok "Layer extracted"

done < "$IMG/layers.list"

# ------------------------------------------------------------
# VERIFY ROOTFS
# ------------------------------------------------------------

log "Verifying extracted image"

APP_DIR="$IMG/rootfs-fixed/app"
DATA_DIR="$IMG/rootfs-fixed/opt/q3-data"

[ -d "$APP_DIR" ] || die "Missing /app in rootfs"
[ -d "$DATA_DIR" ] || die "Missing /opt/q3-data in rootfs"

[ -f "$APP_DIR/ioq3ded.x86_64" ] \
    || die "ioq3ded.x86_64 not found"

[ -f "$APP_DIR/dedicated_room_agent" ] \
    || die "dedicated_room_agent not found"

[ -f "$APP_DIR/entrypoint.sh" ] \
    || die "entrypoint.sh not found"

ok "Q3 binaries found"

# ------------------------------------------------------------
# FIND LOADER
# ------------------------------------------------------------

log "Finding dynamic loader"

LOADER="$(
    find "$IMG/rootfs-fixed" \
        -type f \
        -name 'ld-linux-x86-64.so.2' \
        -print \
        -quit
)"

[ -n "$LOADER" ] || die "ld-linux-x86-64.so.2 not found"

echo "LOADER=$LOADER"

# ------------------------------------------------------------
# LIBRARY PATH
# ------------------------------------------------------------

ROOTFS="$IMG/rootfs-fixed"

LIBPATH="$ROOTFS/lib/x86_64-linux-gnu:$ROOTFS/usr/lib/x86_64-linux-gnu:$ROOTFS/app"

# ------------------------------------------------------------
# RUNTIME
# ------------------------------------------------------------

log "Preparing runtime"

RUNTIME="$IMG/runtime"

rm -rf "$RUNTIME"

mkdir -p \
    "$RUNTIME/bin" \
    "$RUNTIME/run" \
    "$RUNTIME/home"

chmod 755 \
    "$RUNTIME" \
    "$RUNTIME/bin" \
    "$RUNTIME/run" \
    "$RUNTIME/home"

ok "Runtime prepared"

# ------------------------------------------------------------
# LOADER WRAPPERS
# ------------------------------------------------------------

log "Creating loader wrappers"

cat > "$RUNTIME/bin/dedicated_room_agent" <<EOF
#!/bin/sh
exec "$LOADER" \
  --library-path "$LIBPATH" \
  "$ROOTFS/app/dedicated_room_agent" \
  "\$@"
EOF

cat > "$RUNTIME/bin/ioq3ded.x86_64" <<EOF
#!/bin/sh
exec "$LOADER" \
  --library-path "$LIBPATH" \
  "$ROOTFS/app/ioq3ded.x86_64" \
  "\$@"
EOF

chmod +x \
    "$RUNTIME/bin/dedicated_room_agent" \
    "$RUNTIME/bin/ioq3ded.x86_64"

ok "Wrappers created"

# ------------------------------------------------------------
# LOCAL ENTRYPOINT
# ------------------------------------------------------------

log "Creating local entrypoint"

cp \
    "$ROOTFS/app/entrypoint.sh" \
    "$RUNTIME/entrypoint-local.sh"

# Replace executable paths used by the original entrypoint.
sed -i \
    "s#\"\$APP_DIR/dedicated_room_agent\"#\"$RUNTIME/bin/dedicated_room_agent\"#g" \
    "$RUNTIME/entrypoint-local.sh"

sed -i \
    "s#\"\$APP_DIR/ioq3ded.x86_64\"#\"$RUNTIME/bin/ioq3ded.x86_64\"#g" \
    "$RUNTIME/entrypoint-local.sh"

chmod +x "$RUNTIME/entrypoint-local.sh"

ok "Local entrypoint created"

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

log "Writing server configuration"

cat > "$RUNTIME/server.env" <<EOF
export Q3_APP_DIR="$ROOTFS/app"
export Q3_DATA_DIR="$ROOTFS/opt/q3-data"
export Q3_RUN_DIR="$RUNTIME/run"
export Q3_HOME_DIR="$RUNTIME/home"

export NET_SERVER_NAME="$ROOM_NAME"
export HOSTNAME="$SERVER_NAME"

export MODE="$MODE"
export MAP="$MAP"
export MAXCLIENTS="$MAXCLIENTS"
export PORT="$PORT"

export TIMELIMIT="$TIMELIMIT"
export FRAGLIMIT="$FRAGLIMIT"

export RUN_ROOM_AGENT="1"
export RTC_WAIT_SECS="$RTC_WAIT_SECS"

export NET_PEER_SERVER="$NET_PEER_SERVER"
EOF

ok "Server configuration written"

# ------------------------------------------------------------
# ROOM AGENT CONFIG
# ------------------------------------------------------------

log "Writing room-agent configuration"

cat > "$RUNTIME/run/dedicated_room_agent.runtime.toml" <<EOF
base_url = "https://cloud.js-dos.com"
send_interval_secs = 1
stale_after_secs = 13

[[server]]
alias = "$ROOM_NAME"
status_file = "./status.json"
prefix = "q3ded"
EOF

ok "Room-agent configuration written"

# ------------------------------------------------------------
# STATUS
# ------------------------------------------------------------

cat > "$RUNTIME/run/status.json" <<EOF
{
  "name": "$SERVER_NAME",
  "gametype": 1,
  "map": "$MAP"
}
EOF

# ------------------------------------------------------------
# CONTROL SCRIPT
# ------------------------------------------------------------

log "Creating q3ctl"

cat > "$IMG/q3ctl" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

IMG="\$HOME/q3ded"
ROOTFS="\$IMG/rootfs-fixed"
RUNTIME="\$IMG/runtime"

case "\${1:-}" in

start)

    if [ -f "\$RUNTIME/q3.pid" ]; then

        PID="\$(cat "\$RUNTIME/q3.pid" 2>/dev/null || true)"

        if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
            echo "Q3 is already running: PID \$PID"
            exit 0
        fi

        rm -f "\$RUNTIME/q3.pid"
    fi

    echo "Starting Q3..."

    export Q3_APP_DIR="\$ROOTFS/app"
    export Q3_DATA_DIR="\$ROOTFS/opt/q3-data"
    export Q3_RUN_DIR="\$RUNTIME/run"
    export Q3_HOME_DIR="\$RUNTIME/home"

    export NET_SERVER_NAME="$ROOM_NAME"
    export HOSTNAME="$SERVER_NAME"

    export MODE="$MODE"
    export MAP="$MAP"
    export MAXCLIENTS="$MAXCLIENTS"
    export PORT="$PORT"

    export TIMELIMIT="$TIMELIMIT"
    export FRAGLIMIT="$FRAGLIMIT"

    export RUN_ROOM_AGENT="1"
    export RTC_WAIT_SECS="$RTC_WAIT_SECS"

    export NET_PEER_SERVER="$NET_PEER_SERVER"

    mkdir -p "\$RUNTIME/logs"

    nohup "\$RUNTIME/entrypoint-local.sh" \
        > "\$RUNTIME/logs/q3.log" \
        2>&1 < /dev/null &

    PID=\$!

    echo "\$PID" > "\$RUNTIME/q3.pid"

    echo "Q3 started: PID \$PID"

    ;;

stop)

    if [ ! -f "\$RUNTIME/q3.pid" ]; then
        echo "Q3 is not running."
        exit 0
    fi

    PID="\$(cat "\$RUNTIME/q3.pid")"

    echo "Stopping Q3 PID \$PID..."

    kill "\$PID" 2>/dev/null || true

    for i in \$(seq 1 20); do

        if ! kill -0 "\$PID" 2>/dev/null; then
            break
        fi

        sleep 1
    done

    kill -9 "\$PID" 2>/dev/null || true

    rm -f "\$RUNTIME/q3.pid"

    echo "Stopped."

    ;;

restart)

    "\$0" stop || true
    sleep 1
    "\$0" start

    ;;

status)

    if [ -f "\$RUNTIME/q3.pid" ]; then

        PID="\$(cat "\$RUNTIME/q3.pid")"

        if kill -0 "\$PID" 2>/dev/null; then
            echo "Q3: RUNNING"
            echo "PID: \$PID"
        else
            echo "Q3: DEAD"
        fi

    else
        echo "Q3: STOPPED"
    fi

    echo
    echo "Room      : $ROOM_NAME"
    echo "Name      : $SERVER_NAME"
    echo "Mode      : $MODE"
    echo "Map       : $MAP"
    echo "Players   : $MAXCLIENTS"
    echo "Port      : $PORT"

    echo
    echo "rtc.json:"

    if [ -s "\$RUNTIME/run/rtc.json" ]; then
        echo "READY"
    else
        echo "NOT READY"
    fi

    ;;

logs)

    tail -f "\$RUNTIME/logs/q3.log"

    ;;

logs-tail)

    tail -n 100 "\$RUNTIME/logs/q3.log"

    ;;

config)

    "\${EDITOR:-nano}" "\$IMG/server.env"

    ;;

stop-agent)

    pkill -f "\$RUNTIME/bin/dedicated_room_agent" 2>/dev/null || true

    ;;

*)

    echo
    echo "Q3 CONTROL"
    echo
    echo "  \$0 start"
    echo "  \$0 stop"
    echo "  \$0 restart"
    echo "  \$0 status"
    echo "  \$0 logs"
    echo "  \$0 logs-tail"
    echo "  \$0 config"
    echo

    ;;

esac
EOF

chmod +x "$IMG/q3ctl"

# ------------------------------------------------------------
# USER CONFIG
# ------------------------------------------------------------

cat > "$IMG/server.env" <<EOF
SERVER_NAME="$SERVER_NAME"
ROOM_NAME="$ROOM_NAME"

MODE="$MODE"
MAP="$MAP"

MAXCLIENTS="$MAXCLIENTS"
PORT="$PORT"

TIMELIMIT="$TIMELIMIT"
FRAGLIMIT="$FRAGLIMIT"

RTC_WAIT_SECS="$RTC_WAIT_SECS"
NET_PEER_SERVER="$NET_PEER_SERVER"
EOF

ok "Control script created"

# ------------------------------------------------------------
# START
# ------------------------------------------------------------

log "Starting Q3"

"$IMG/q3ctl" start

sleep 2

# ------------------------------------------------------------
# STATUS
# ------------------------------------------------------------

log "Initial status"

"$IMG/q3ctl" status || true

echo
echo "============================================================"
echo "                 Q3 INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Room : $ROOM_NAME"
echo "Name : $SERVER_NAME"
echo "Mode : $MODE"
echo "Map  : $MAP"
echo
echo "Commands:"
echo
echo "  ~/q3ded/q3ctl start"
echo "  ~/q3ded/q3ctl stop"
echo "  ~/q3ded/q3ctl restart"
echo "  ~/q3ded/q3ctl status"
echo "  ~/q3ded/q3ctl logs"
echo "  ~/q3ded/q3ctl config"
echo
echo "Settings:"
echo
echo "  ~/q3ded/server.env"
echo
echo "============================================================"

