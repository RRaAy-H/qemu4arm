#!/usr/bin/env bash
set -euo pipefail

VM_DIR="${VM_DIR:-$PWD/vm}"
IMG_URL="${IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img}"
BASE_IMG="$VM_DIR/noble-server-cloudimg-arm64.img"
DISK="$VM_DIR/ubuntu-arm64.qcow2"
SEED="$VM_DIR/seed.iso"
EFI="$VM_DIR/QEMU_EFI.fd"
VARS="$VM_DIR/QEMU_VARS.fd"
ACCEL="${ACCEL:-tcg,thread=multi}"
CPU_MODEL="${CPU_MODEL:-max,pauth=off,sve=on,sve128=on}"
DISK_SIZE="${DISK_SIZE:-100G}"
SSH_PORT="${SSH_PORT:-2222}"
REQUIRED_FREE_GB="${REQUIRED_FREE_GB:-10}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

host_cpus() {
    local cores
    cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    case "$cores" in
        ''|*[!0-9]*) cores=4 ;;
    esac
    echo "$cores"
}

host_mem_mb() {
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    case "$mem_kb" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo $((mem_kb / 1024)) ;;
    esac
}

default_smp() {
    local cores smp
    cores="$(host_cpus)"
    smp=$((cores * 3 / 4))

    [ "$smp" -lt 4 ] && smp="$cores"
    [ "$smp" -gt 48 ] && smp=48
    [ "$smp" -lt 1 ] && smp=1

    echo "$smp"
}

default_mem() {
    local total_mb mem_mb
    total_mb="$(host_mem_mb)"

    if [ "$total_mb" -lt 8192 ]; then
        echo 4096
        return
    fi

    mem_mb=$((total_mb * 3 / 4))
    [ "$mem_mb" -gt 98304 ] && mem_mb=98304
    [ "$mem_mb" -lt 4096 ] && mem_mb=4096

    echo "$mem_mb"
}

SMP="${SMP:-$(default_smp)}"
MEM="${MEM:-$(default_mem)}"

cpuinfo_has_feature() {
    local feature="$1"
    awk -v feature="$feature" '
        /^Features/ {
            for (i = 3; i <= NF; i++) {
                if ($i == feature) found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' /proc/cpuinfo 2>/dev/null
}

check_qemu_version() {
    local version major
    version="$(qemu-system-aarch64 --version | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+[.][0-9]+/) { print $i; exit } }')"
    major="${version%%.*}"

    case "$major" in
        ''|*[!0-9]*) die "could not parse qemu-system-aarch64 version" ;;
    esac

    [ "$major" -ge 7 ] || die "qemu-system-aarch64 $version is too old; need QEMU >= 7 for SVE2 via -cpu max"
}

check_qemu_cpu() {
    local output status cpu_help

    command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 not on PATH; run 'deps' first"
    log "qemu: $(qemu-system-aarch64 --version | awk 'NR == 1 { print; exit }')"
    check_qemu_version

    if command -v timeout >/dev/null; then
        if output="$(timeout 3s qemu-system-aarch64 \
            -accel "$ACCEL" \
            -machine virt,gic-version=3 \
            -cpu "$CPU_MODEL" \
            -display none \
            -nodefaults \
            -S \
            -serial none \
            -monitor none 2>&1)"; then
            status=0
        else
            status=$?
        fi

        case "$status" in
            0|124) log "qemu: CPU model accepted ($CPU_MODEL)" ;;
            *) die "qemu rejected CPU model '$CPU_MODEL': $output" ;;
        esac
    else
        warn "timeout command not found; skipping paused QEMU CPU-model validation"
    fi

    cpu_help="$(qemu-system-aarch64 -cpu max,help 2>&1 || true)"
    if printf '%s\n' "$cpu_help" | grep -qi 'sve2'; then
        log "qemu: CPU help lists SVE2 support"
    elif printf '%s\n' "$cpu_help" | grep -qi 'sve128'; then
        log "qemu: CPU help lists SVE vector lengths; guest /proc/cpuinfo remains the SVE2 authority"
    else
        warn "could not confirm SVE/SVE2 from QEMU help; verify inside the guest after boot"
    fi
}

cmd_preflight() {
    log "preflight: Ubuntu aarch64 server"
    local arch
    arch="$(uname -m)"
    [ "$arch" = "aarch64" ] || die "this repo is now targeted at the remote aarch64 server; got host architecture '$arch'"

    if cpuinfo_has_feature sve2; then
        log "preflight: host CPU exposes SVE2"
    elif cpuinfo_has_feature sve; then
        warn "host CPU exposes SVE but not SVE2; using QEMU TCG with -cpu max for guest SVE2"
    else
        warn "host CPU does not expose SVE/SVE2; using QEMU TCG with -cpu max is required for the guest"
    fi

    log "preflight: selected VM resources: ${SMP} vCPU, ${MEM} MiB RAM, ${DISK_SIZE} disk"
    local mem_mb min_mem_mb
    mem_mb="$(host_mem_mb)"
    min_mem_mb=$((MEM + 2048))
    [ "$min_mem_mb" -lt 6144 ] && min_mem_mb=6144
    [ "$mem_mb" -ge "$min_mem_mb" ] \
        || die "only ${mem_mb} MiB RAM visible; need >= ${min_mem_mb} MiB for MEM=${MEM}"

    log "preflight: disk >= ${REQUIRED_FREE_GB} GB free in $(dirname "$VM_DIR")"
    local vm_parent avail_kb
    vm_parent="$(dirname "$VM_DIR")"
    [ -d "$vm_parent" ] || die "VM_DIR parent does not exist: $vm_parent"
    avail_kb="$(df -Pk "$vm_parent" | awk 'NR == 2 {print $4}')"
    [ "$avail_kb" -ge $((REQUIRED_FREE_GB * 1024 * 1024)) ] \
        || die "only ${avail_kb} kB free; need >= ${REQUIRED_FREE_GB} GB"

    if command -v qemu-system-aarch64 >/dev/null; then
        check_qemu_cpu
    else
        log "preflight: qemu-system-aarch64 not installed yet; 'deps' will install it"
    fi

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
        genisoimage \
        coreutils
    check_qemu_cpu
    log "deps: ok"
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

find_aavmf_code() {
    for p in \
        /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd \
        /usr/share/edk2/aarch64/QEMU_EFI.fd
    do
        [ -f "$p" ] && { echo "$p"; return; }
    done
    die "could not find AAVMF firmware (looked in /usr/share/qemu-efi-aarch64, /usr/share/AAVMF, /usr/share/edk2/aarch64)"
}

find_aavmf_vars() {
    for p in \
        /usr/share/qemu-efi-aarch64/QEMU_VARS.fd \
        /usr/share/AAVMF/AAVMF_VARS.fd \
        /usr/share/edk2/aarch64/QEMU_VARS.fd
    do
        [ -f "$p" ] && { echo "$p"; return; }
    done
    return 1
}

cmd_prepare() {
    mkdir -p "$VM_DIR"

    log "prepare: copy UEFI firmware"
    local fw vars_template
    fw="$(find_aavmf_code)"
    cp "$fw" "$EFI"
    truncate -s 64M "$EFI"
    if [ ! -f "$VARS" ]; then
        if vars_template="$(find_aavmf_vars)"; then
            cp "$vars_template" "$VARS"
        else
            truncate -s 64M "$VARS"
        fi
        truncate -s 64M "$VARS"
    fi

    [ -f "$BASE_IMG" ] || die "base image missing - run 'fetch' first"
    if [ -f "$DISK" ]; then
        log "prepare: $DISK already exists, keeping it"
    else
        log "prepare: create qcow2 overlay (backed by $BASE_IMG, size $DISK_SIZE)"
        qemu-img create -F qcow2 -b "$BASE_IMG" -f qcow2 "$DISK" "$DISK_SIZE"
    fi
    qemu-img info "$DISK" | grep -q "^virtual size:" || die "could not read qcow2 virtual size"

    log "prepare: ssh keypair"
    local keyfile="$VM_DIR/id_ed25519"
    if [ ! -f "$keyfile" ]; then
        ssh-keygen -t ed25519 -N "" -C "qemu4arm" -f "$keyfile"
    fi
    local pubkey
    pubkey="$(cat "$keyfile.pub")"

    log "prepare: write user-data / meta-data"
    cat > "$VM_DIR/meta-data" <<EOF
instance-id: qemu4arm-vm-1
local-hostname: qemu4arm-vm
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
    [ -f "$DISK" ] || die "disk missing - run 'prepare' first"
    [ -f "$SEED" ] || die "seed missing - run 'prepare' first"
    [ -f "$EFI" ]  || die "UEFI firmware missing - run 'prepare' first"
    check_qemu_cpu

    cat <<EOF
[+] launching VM (Ctrl-A X to quit serial console)
    Acceleration:    $ACCEL (forced so SVE2 is emulated even on Cortex-A72)
    CPU model:       $CPU_MODEL
    Resources:       $SMP vCPU, $MEM MiB RAM
    Disk:            $DISK ($DISK_SIZE virtual size when newly prepared)
    SSH:            ssh -i $VM_DIR/id_ed25519 -p $SSH_PORT ubuntu@localhost
    Login fallback: user 'ubuntu' / password 'ubuntu' on the serial console
    Verify SVE2:     ssh -i $VM_DIR/id_ed25519 -p $SSH_PORT ubuntu@localhost 'uname -m; grep -m1 ^Features /proc/cpuinfo'
EOF

    exec qemu-system-aarch64 \
        -accel "$ACCEL" \
        -machine virt,gic-version=3 \
        -cpu "$CPU_MODEL" \
        -smp "$SMP" -m "$MEM" \
        -drive if=pflash,format=raw,readonly=on,file="$EFI" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive if=virtio,format=qcow2,file="$DISK" \
        -drive if=virtio,format=raw,file="$SEED" \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-rng-pci \
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

  preflight  check aarch64 host, RAM, disk, and QEMU if installed
  deps       apt install qemu + cloud-image tools
  fetch      download Ubuntu 24.04 arm64 cloud image
  prepare    build qcow2 overlay, UEFI vars, cloud-init seed
  run        launch the VM (serial console, ssh on :$SSH_PORT)
  all        do everything in order

Environment overrides:
  VM_DIR=$VM_DIR
  SMP=$SMP
  MEM=$MEM
  DISK_SIZE=$DISK_SIZE
  SSH_PORT=$SSH_PORT
  CPU_MODEL=$CPU_MODEL
EOF
    exit 1
}

[ $# -eq 1 ] || usage
case "$1" in
    preflight|deps|fetch|prepare|run|all) "cmd_$1" ;;
    *) usage ;;
esac
