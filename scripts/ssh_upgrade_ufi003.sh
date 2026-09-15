#!/usr/bin/env bash
# Host-side SSH upgrade helper for UFI003 after the dedicated upgrade partition
# has been introduced by a full flash.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
DEFAULT_STAGE_DIR="/mnt/upgrade/ssh-upgrade"
DEFAULT_MOUNT_POINT="/mnt/upgrade"
DEFAULT_REBOOT_TIMEOUT=600

HOST=""
SSH_PORT=""
IDENTITY_FILE=""
BOOT_IMG=""
ROOTFS_GZ=""
SYSTEM_IMG=""
STAGE_DIR="$DEFAULT_STAGE_DIR"
MOUNT_POINT="$DEFAULT_MOUNT_POINT"
FORMAT_UPGRADE=0
ASSUME_YES=0
REBOOT_TIMEOUT="$DEFAULT_REBOOT_TIMEOUT"
TMP_DIR=""
SUMS_FILE=""
WRITER_FILE=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --host root@192.168.1.1 --boot boot.img --rootfs rootfs.raw.img.gz
  $SCRIPT_NAME --host root@192.168.1.1 --boot boot.img --system system.img

Options:
  --host TARGET            SSH target, for example root@192.168.1.1.
  --boot FILE             boot.img to flash to the boot partition.
  --rootfs FILE           gzip-compressed raw rootfs image.
  --system FILE           Android sparse or raw system.img. Sparse images are
                           converted locally to rootfs.raw.img.gz with simg2img.
  --ssh-port PORT         SSH port.
  --identity FILE         SSH private key.
  --stage-dir PATH        On-device staging directory. Default: $DEFAULT_STAGE_DIR
  --mount-point PATH      Mount point for the upgrade partition. Default: $DEFAULT_MOUNT_POINT
  --format-upgrade        Force-format the upgrade partition as ext4 before staging.
                           Not needed for normal first use; the script auto-formats
                           when the partition cannot be mounted.
  --reboot-timeout SEC    Forced reboot fallback after writing starts. Default: $DEFAULT_REBOOT_TIMEOUT
  --yes                   Skip the final interactive confirmation.
  -h, --help              Show this help.

This script expects the target device to expose these GPT labels:
  /dev/disk/by-partlabel/upgrade
  /dev/disk/by-partlabel/boot
  /dev/disk/by-partlabel/rootfs
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '[INFO] %s\n' "$*" >&2
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "$SUMS_FILE" ]; then
        rm -f "$SUMS_FILE"
    fi
    if [ -n "$WRITER_FILE" ]; then
        rm -f "$WRITER_FILE"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            HOST=${2:-}
            shift 2
            ;;
        --boot)
            BOOT_IMG=${2:-}
            shift 2
            ;;
        --rootfs)
            ROOTFS_GZ=${2:-}
            shift 2
            ;;
        --system)
            SYSTEM_IMG=${2:-}
            shift 2
            ;;
        --ssh-port)
            SSH_PORT=${2:-}
            shift 2
            ;;
        --identity)
            IDENTITY_FILE=${2:-}
            shift 2
            ;;
        --stage-dir)
            STAGE_DIR=${2:-}
            shift 2
            ;;
        --mount-point)
            MOUNT_POINT=${2:-}
            shift 2
            ;;
        --format-upgrade)
            FORMAT_UPGRADE=1
            shift
            ;;
        --reboot-timeout)
            REBOOT_TIMEOUT=${2:-}
            shift 2
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$HOST" ] || die "--host is required"
[ -n "$BOOT_IMG" ] || die "--boot is required"
[ -f "$BOOT_IMG" ] || die "boot image not found: $BOOT_IMG"
[ -s "$BOOT_IMG" ] || die "boot image is empty: $BOOT_IMG"
[ "$ROOTFS_GZ" = "" ] || [ -f "$ROOTFS_GZ" ] || die "rootfs image not found: $ROOTFS_GZ"
[ "$SYSTEM_IMG" = "" ] || [ -f "$SYSTEM_IMG" ] || die "system image not found: $SYSTEM_IMG"
[ "$ROOTFS_GZ" != "" ] || [ "$SYSTEM_IMG" != "" ] || die "use --rootfs or --system"
[ "$ROOTFS_GZ" = "" ] || [ "$SYSTEM_IMG" = "" ] || die "use only one of --rootfs or --system"

case "$STAGE_DIR" in
    "$MOUNT_POINT"/*) ;;
    *) die "--stage-dir must be inside --mount-point" ;;
esac
[ "$MOUNT_POINT" != "/" ] || die "--mount-point must not be /"
[ "$STAGE_DIR" != "/" ] || die "--stage-dir must not be /"

case "$REBOOT_TIMEOUT" in
    ''|*[!0-9]*) die "--reboot-timeout must be a positive integer" ;;
esac
[ "$REBOOT_TIMEOUT" -ge 120 ] || die "--reboot-timeout must be at least 120 seconds"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
SCP_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
if [ -n "$SSH_PORT" ]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    SCP_OPTS+=(-P "$SSH_PORT")
fi
if [ -n "$IDENTITY_FILE" ]; then
    [ -f "$IDENTITY_FILE" ] || die "identity file not found: $IDENTITY_FILE"
    SSH_OPTS+=(-i "$IDENTITY_FILE")
    SCP_OPTS+=(-i "$IDENTITY_FILE")
fi

remote_sh() {
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

remote_script() {
    ssh "${SSH_OPTS[@]}" "$HOST" sh -s -- "$@"
}

copy_to_remote() {
    scp "${SCP_OPTS[@]}" "$1" "$HOST:$2"
}

require_host_tool() {
    command -v "$1" >/dev/null 2>&1 || die "host tool is missing: $1"
}

host_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        die "host tool is missing: sha256sum or shasum"
    fi
}

is_android_sparse() {
    local magic
    magic=$(LC_ALL=C od -An -tx4 -N4 "$1" | tr -d '[:space:]')
    [ "$magic" = "ed26ff3a" ]
}

prepare_rootfs() {
    if [ -n "$ROOTFS_GZ" ]; then
        require_host_tool gzip
        gzip -t "$ROOTFS_GZ"
        return
    fi

    require_host_tool gzip
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ufi003-ssh-upgrade.XXXXXX")
    local raw_img="$TMP_DIR/rootfs.raw.img"
    local gz_img="$TMP_DIR/rootfs.raw.img.gz"

    if is_android_sparse "$SYSTEM_IMG"; then
        require_host_tool simg2img
        info "Converting Android sparse system.img to a raw rootfs image..."
        simg2img "$SYSTEM_IMG" "$raw_img"
    else
        info "system.img does not look sparse; treating it as a raw rootfs image."
        cp "$SYSTEM_IMG" "$raw_img"
    fi

    [ -s "$raw_img" ] || die "converted rootfs image is empty"
    info "Compressing raw rootfs image for staging..."
    gzip -c "$raw_img" > "$gz_img"
    gzip -t "$gz_img"
    ROOTFS_GZ=$gz_img
}

prepare_rootfs

require_host_tool wc
require_host_tool awk
require_host_tool od
require_host_tool tr
require_host_tool ssh
require_host_tool scp

BOOT_SIZE=$(wc -c < "$BOOT_IMG" | tr -d ' ')
ROOTFS_RAW_SIZE=$(gzip -l "$ROOTFS_GZ" | awk 'NR == 2 { print $2 }')
case "$ROOTFS_RAW_SIZE" in
    ''|*[!0-9]*) die "could not determine uncompressed rootfs size from $ROOTFS_GZ" ;;
esac

BOOT_SHA=$(host_sha256 "$BOOT_IMG")
ROOTFS_SHA=$(host_sha256 "$ROOTFS_GZ")

info "Checking SSH connectivity and device tools..."
remote_script "$FORMAT_UPGRADE" <<'REMOTE'
set -eu
format_upgrade=$1
for tool in busybox cp dd gzip sha256sum readlink mount mkdir rm sync reboot wc tr sleep kill date awk cat sh; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing required device tool: $tool" >&2
        exit 1
    }
done
if [ "$format_upgrade" = "1" ]; then
    command -v mkfs.ext4 >/dev/null 2>&1 || {
        echo "missing required device tool for --format-upgrade: mkfs.ext4" >&2
        exit 1
    }
fi
REMOTE

info "Checking device partition labels and sizes..."
read -r REMOTE_BOOT_DEV REMOTE_BOOT_SIZE REMOTE_ROOTFS_DEV REMOTE_ROOTFS_SIZE REMOTE_UPGRADE_DEV REMOTE_UPGRADE_SIZE <<EOF
$(remote_script <<'REMOTE'
set -eu
resolve_part() {
    label=$1
    path="/dev/disk/by-partlabel/$label"
    [ -e "$path" ] || {
        echo "missing partition label: $label" >&2
        exit 1
    }
    readlink -f "$path"
}
block_bytes() {
    node=${1##*/}
    sectors=$(cat "/sys/class/block/$node/size")
    echo $((sectors * 512))
}
boot_dev=$(resolve_part boot)
rootfs_dev=$(resolve_part rootfs)
upgrade_dev=$(resolve_part upgrade)
[ "$boot_dev" != "$rootfs_dev" ] || exit 1
[ "$boot_dev" != "$upgrade_dev" ] || exit 1
[ "$rootfs_dev" != "$upgrade_dev" ] || exit 1
printf '%s %s %s %s %s %s\n' \
    "$boot_dev" "$(block_bytes "$boot_dev")" \
    "$rootfs_dev" "$(block_bytes "$rootfs_dev")" \
    "$upgrade_dev" "$(block_bytes "$upgrade_dev")"
REMOTE
)
EOF

[ "$BOOT_SIZE" -le "$REMOTE_BOOT_SIZE" ] || die "boot image is larger than the boot partition"
[ "$ROOTFS_RAW_SIZE" -le "$REMOTE_ROOTFS_SIZE" ] || die "rootfs image is larger than the rootfs partition"

info "Device partitions:"
printf '  boot:    %s (%s bytes)\n' "$REMOTE_BOOT_DEV" "$REMOTE_BOOT_SIZE"
printf '  rootfs:  %s (%s bytes)\n' "$REMOTE_ROOTFS_DEV" "$REMOTE_ROOTFS_SIZE"
printf '  upgrade: %s (%s bytes)\n' "$REMOTE_UPGRADE_DEV" "$REMOTE_UPGRADE_SIZE"
printf '  boot.img:           %s bytes\n' "$BOOT_SIZE"
printf '  rootfs raw image:   %s bytes\n' "$ROOTFS_RAW_SIZE"

info "Preparing upgrade partition mount..."
remote_script "$FORMAT_UPGRADE" "$MOUNT_POINT" "$STAGE_DIR" <<'REMOTE'
set -eu
format_upgrade=$1
mount_point=$2
stage_dir=$3
upgrade_dev=$(readlink -f /dev/disk/by-partlabel/upgrade)

[ -n "$mount_point" ] || exit 1
[ -n "$stage_dir" ] || exit 1
[ "$mount_point" != "/" ] || exit 1
[ "$stage_dir" != "/" ] || exit 1

current_mount=$(
    awk -v dev="$upgrade_dev" '$1 == dev { print $2; found=1; exit } END { if (!found) exit 1 }' /proc/mounts
) || current_mount=""

if [ -n "$current_mount" ]; then
    if [ "$format_upgrade" = "1" ]; then
        echo "upgrade partition is already mounted; refusing to format it" >&2
        exit 1
    fi
    case "$stage_dir" in
        "$current_mount"/*) ;;
        *)
            echo "upgrade partition is mounted at $current_mount, but stage dir is $stage_dir" >&2
            exit 1
            ;;
    esac
else
    mkdir -p "$mount_point"
    if [ "$format_upgrade" = "1" ]; then
        mkfs.ext4 -F "$upgrade_dev"
        mount "$upgrade_dev" "$mount_point"
    elif ! mount "$upgrade_dev" "$mount_point"; then
        echo "upgrade partition did not mount; formatting it as ext4 for first use" >&2
        mkfs.ext4 -F "$upgrade_dev"
        mount "$upgrade_dev" "$mount_point"
    fi
fi

rm -rf "$stage_dir"
mkdir -p "$stage_dir"
REMOTE

REMOTE_BOOT="$STAGE_DIR/boot.img"
REMOTE_ROOTFS="$STAGE_DIR/rootfs.raw.img.gz"
REMOTE_SUMS="$STAGE_DIR/SHA256SUMS"
REMOTE_WRITER="/tmp/ufi003-ssh-upgrade-writer.sh"

info "Copying images to the upgrade partition..."
copy_to_remote "$BOOT_IMG" "$REMOTE_BOOT"
copy_to_remote "$ROOTFS_GZ" "$REMOTE_ROOTFS"

SUMS_FILE=$(mktemp "${TMPDIR:-/tmp}/ufi003-ssh-upgrade-sums.XXXXXX")
{
    printf '%s  boot.img\n' "$BOOT_SHA"
    printf '%s  rootfs.raw.img.gz\n' "$ROOTFS_SHA"
} > "$SUMS_FILE"
copy_to_remote "$SUMS_FILE" "$REMOTE_SUMS"

info "Verifying staged hashes on the device..."
remote_script "$STAGE_DIR" <<'REMOTE'
set -eu
stage_dir=$1
cd "$stage_dir"
sha256sum -c SHA256SUMS
REMOTE

printf '\n'
printf 'This will write the target device partitions over SSH:\n'
printf '  boot   <- %s\n' "$REMOTE_BOOT"
printf '  rootfs <- %s\n' "$REMOTE_ROOTFS"
printf '\n'
printf 'After rootfs writing starts, SSH may disconnect. The device will reboot forcibly.\n'

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Type SSHUPGRADE exactly to continue: '
    read -r CONFIRM
    [ "$CONFIRM" = "SSHUPGRADE" ] || die "cancelled"
fi

WRITER_FILE=$(mktemp "${TMPDIR:-/tmp}/ufi003-ssh-upgrade-writer.XXXXXX")
cat > "$WRITER_FILE" <<'REMOTE'
#!/bin/sh
set -eu

stage_dir=$1
reboot_timeout=$2
rootfs_size=$3
boot_dev=$(readlink -f /dev/disk/by-partlabel/boot)
rootfs_dev=$(readlink -f /dev/disk/by-partlabel/rootfs)
log="$stage_dir/upgrade.log"

block_bytes() {
    node=${1##*/}
    sectors=$(cat "/sys/class/block/$node/size")
    echo $((sectors * 512))
}

exec >> "$log" 2>&1

echo "===== UFI003 SSH upgrade started: $(date) ====="
echo "boot device: $boot_dev"
echo "rootfs device: $rootfs_dev"
echo "stage dir: $stage_dir"

tool_dir=/tmp/ufi003-ssh-upgrade-tools
busybox_src=$(command -v busybox)
mkdir -p "$tool_dir"
cp "$busybox_src" "$tool_dir/busybox"
bb="$tool_dir/busybox"

hard_sync() {
    "$bb" sync 2>/dev/null || sync 2>/dev/null || true
}

hard_reboot() {
    hard_sync
    "$bb" reboot -f 2>/dev/null || reboot -f 2>/dev/null || {
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo b > /proc/sysrq-trigger 2>/dev/null || true
    }
    while :; do
        "$bb" sleep 1 2>/dev/null || sleep 1
    done
}

red_led="red:power"
blue_led="blue:wan"
red_blink_pid=""

led_write() {
    led_path="/sys/class/leds/$1/$2"
    if [ -w "$led_path" ]; then
        echo "$3" > "$led_path" 2>/dev/null || true
    fi
}

led_prepare() {
    led_write "$1" trigger none
}

led_set() {
    led_prepare "$1"
    led_write "$1" brightness "$2"
}

led_delay_fast() {
    "$bb" usleep 200000 2>/dev/null || "$bb" sleep 1
}

set_upgrade_leds_off() {
    led_set "$red_led" 0
    led_set "$blue_led" 0
}

blink_red_upgrade() {
    set_upgrade_leds_off
    while :; do
        led_set "$red_led" 1
        led_delay_fast
        led_set "$red_led" 0
        led_delay_fast
    done
}

start_upgrade_leds() {
    blink_red_upgrade &
    red_blink_pid=$!
}

stop_upgrade_leds() {
    if [ -n "$red_blink_pid" ]; then
        "$bb" kill "$red_blink_pid" 2>/dev/null || kill "$red_blink_pid" 2>/dev/null || true
        wait "$red_blink_pid" 2>/dev/null || true
        red_blink_pid=""
    fi
    set_upgrade_leds_off
}

show_success_led() {
    set_upgrade_leds_off
    led_set "$blue_led" 1
    "$bb" sleep 10
    led_set "$blue_led" 0
}

(
    "$bb" sleep "$reboot_timeout"
    echo "watchdog timeout reached; forcing reboot"
    hard_reboot
) &
watchdog_pid=$!

finish_reboot() {
    hard_reboot
}
trap finish_reboot EXIT HUP INT TERM

cd "$stage_dir"
sha256sum -c SHA256SUMS

boot_size=$(wc -c < boot.img | tr -d ' ')
boot_limit=$(block_bytes "$boot_dev")
rootfs_limit=$(block_bytes "$rootfs_dev")

[ "$boot_size" -le "$boot_limit" ] || {
    echo "boot image exceeds boot partition"
    exit 1
}
[ "$rootfs_size" -le "$rootfs_limit" ] || {
    echo "rootfs image exceeds rootfs partition"
    exit 1
}

echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

echo "starting red upgrade indicator..."
start_upgrade_leds

echo "writing boot..."
dd if=boot.img of="$boot_dev" bs=1M conv=fsync

echo "writing rootfs..."
gzip -dc rootfs.raw.img.gz | dd of="$rootfs_dev" bs=1M conv=fsync

hard_sync
"$bb" kill "$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
stop_upgrade_leds
echo "upgrade completed; showing blue success indicator"
show_success_led
trap - EXIT HUP INT TERM
echo "upgrade completed; rebooting"
hard_reboot
REMOTE

info "Installing remote writer..."
copy_to_remote "$WRITER_FILE" "$REMOTE_WRITER"
remote_sh "chmod 700 '$REMOTE_WRITER'"

info "Starting remote writer. Follow progress later with: ssh $HOST 'tail -f $STAGE_DIR/upgrade.log'"
remote_sh "sh '$REMOTE_WRITER' '$STAGE_DIR' '$REBOOT_TIMEOUT' '$ROOTFS_RAW_SIZE' >/tmp/ufi003-ssh-upgrade.launch.log 2>&1 < /dev/null &"

info "Writer launched. SSH may drop while rootfs is being overwritten; wait for the device to reboot."
