#!/usr/bin/env bash
set -euo pipefail

VM_DIR="${VM_DIR:-$PWD/vm}"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
BASE_IMG="$VM_DIR/noble-server-cloudimg-arm64.img"
DISK="$VM_DIR/ubuntu-arm64.qcow2"
SEED="$VM_DIR/seed.iso"
EFI="$VM_DIR/QEMU_EFI.fd"
VARS="$VM_DIR/QEMU_VARS.fd"
DISK_SIZE="20G"
SMP="4"
MEM="4096"
SSH_PORT="2222"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[+] $*"; }

cmd_preflight() {
    log "preflight: WSL2 check"
    grep -qi microsoft /proc/version || die "not running under WSL — this script is WSL2-only"
    grep -qi 'wsl2\|microsoft-standard' /proc/version || log "warning: kernel does not look like WSL2; continuing"

    log "preflight: cwd not under /mnt"
    case "$PWD" in
        /mnt/*) die "cwd is $PWD — VM files must live on ext4 (e.g. \$HOME), not DrvFs" ;;
    esac
    case "$VM_DIR" in
        /mnt/*) die "VM_DIR is $VM_DIR — must be on ext4, not DrvFs" ;;
    esac

    log "preflight: RAM >= 6 GB"
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    [ "$mem_kb" -ge $((6 * 1024 * 1024)) ] \
        || die "WSL2 sees ${mem_kb} kB RAM; need >=6 GB. Set memory=8GB in %UserProfile%\\.wslconfig and run 'wsl --shutdown'."

    log "preflight: disk >= 6 GB free in $(dirname "$VM_DIR")"
    local avail_kb
    avail_kb="$(df -Pk "$(dirname "$VM_DIR")" | awk 'NR==2 {print $4}')"
    [ "$avail_kb" -ge $((6 * 1024 * 1024)) ] \
        || die "only ${avail_kb} kB free; need >=6 GB"

    log "preflight: ok"
}

cmd_deps() {
    log "deps: apt install"
    sudo apt update
    sudo apt install -y \
        qemu-system-arm \
        qemu-utils \
        qemu-efi-aarch64 \
        cloud-image-utils \
        wget \
        openssh-client \
        genisoimage
    command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 not on PATH after install"
    log "deps: ok ($(qemu-system-aarch64 --version | head -1))"
}

cmd_fetch() {
    mkdir -p "$VM_DIR"
    if [ -f "$BASE_IMG" ] && [ "$(stat -c%s "$BASE_IMG")" -gt $((400 * 1024 * 1024)) ]; then
        log "fetch: $BASE_IMG already present, skipping"
        return
    fi
    log "fetch: downloading $IMG_URL"
    wget -O "$BASE_IMG.part" "$IMG_URL"
    mv "$BASE_IMG.part" "$BASE_IMG"
    [ "$(stat -c%s "$BASE_IMG")" -gt $((400 * 1024 * 1024)) ] || die "downloaded image is suspiciously small"
    log "fetch: ok"
}

find_aavmf() {
    for p in \
        /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd \
        /usr/share/edk2/aarch64/QEMU_EFI.fd
    do
        [ -f "$p" ] && { echo "$p"; return; }
    done
    die "could not find AAVMF firmware (looked in /usr/share/qemu-efi-aarch64, /usr/share/AAVMF, /usr/share/edk2/aarch64)"
}

cmd_prepare() {
    mkdir -p "$VM_DIR"

    log "prepare: copy UEFI firmware"
    local fw
    fw="$(find_aavmf)"
    cp "$fw" "$EFI"
    truncate -s 64M "$EFI"
    if [ ! -f "$VARS" ]; then
        truncate -s 64M "$VARS"
    fi

    log "prepare: create qcow2 overlay (backed by $BASE_IMG)"
    [ -f "$BASE_IMG" ] || die "base image missing — run 'fetch' first"
    qemu-img create -F qcow2 -b "$BASE_IMG" -f qcow2 "$DISK" "$DISK_SIZE"
    qemu-img info "$DISK" | grep -q "virtual size: 20 GiB" || die "qcow2 not sized to 20G"

    log "prepare: ssh keypair"
    local keyfile="$VM_DIR/id_ed25519"
    if [ ! -f "$keyfile" ]; then
        ssh-keygen -t ed25519 -N "" -C "armv9qemu" -f "$keyfile"
    fi
    local pubkey
    pubkey="$(cat "$keyfile.pub")"

    log "prepare: write user-data / meta-data"
    cat > "$VM_DIR/meta-data" <<EOF
instance-id: armv9-vm-1
local-hostname: armv9-vm
EOF
    cat > "$VM_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ubuntu
    ssh_authorized_keys:
      - $pubkey
ssh_pwauth: true
chpasswd:
  expire: false
package_update: false
EOF

    log "prepare: build seed.iso"
    cloud-localds "$SEED" "$VM_DIR/user-data" "$VM_DIR/meta-data"
    [ -f "$SEED" ] || die "seed.iso not created"

    log "prepare: ok"
}

cmd_run() {
    [ -f "$DISK" ] || die "disk missing — run 'prepare' first"
    [ -f "$SEED" ] || die "seed missing — run 'prepare' first"
    [ -f "$EFI" ]  || die "UEFI firmware missing — run 'prepare' first"

    cat <<EOF
[+] launching VM (Ctrl-A X to quit serial console)
    SSH from WSL:     ssh -i $VM_DIR/id_ed25519 -p $SSH_PORT ubuntu@localhost
    SSH from Windows: works on Win11 (localhost passthrough); on Win10 use 'netsh interface portproxy'
    Login fallback:   user 'ubuntu' / password 'ubuntu' on the serial console
EOF

    exec qemu-system-aarch64 \
        -M virt \
        -cpu max \
        -smp "$SMP" -m "$MEM" \
        -drive if=pflash,format=raw,readonly=on,file="$EFI" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive if=virtio,format=qcow2,file="$DISK" \
        -drive if=virtio,format=raw,file="$SEED" \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic
}

cmd_all() {
    cmd_preflight
    cmd_deps
    cmd_fetch
    cmd_prepare
    cmd_run
}

usage() {
    cat <<EOF
usage: $0 {preflight|deps|fetch|prepare|run|all}

  preflight  check WSL2, ext4 cwd, RAM, disk
  deps       apt install qemu + cloud-image tools
  fetch      download Ubuntu 24.04 arm64 cloud image
  prepare    build qcow2 overlay, UEFI vars, cloud-init seed
  run        launch the VM (serial console, ssh on :$SSH_PORT)
  all        do everything in order
EOF
    exit 1
}

[ $# -eq 1 ] || usage
case "$1" in
    preflight|deps|fetch|prepare|run|all) "cmd_$1" ;;
    *) usage ;;
esac
