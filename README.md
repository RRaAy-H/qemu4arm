# armv9qemu

Boot an Ubuntu 24.04 arm64 VM with **SVE2** support under QEMU on a **WSL2** Ubuntu host (x86_64). One bash script, six subcommands, no libvirt.

## Goal

Run a real arm64 Ubuntu Server inside WSL2 so you can test ARMv9-class code (SVE2, ARMv8.5+ features) on an x86 laptop. Verified by `grep sve2 /proc/cpuinfo` inside the guest.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Windows host (Hyper-V)                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  WSL2 Ubuntu (x86_64)                                │  │
│  │                                                      │  │
│  │   install-arm64-vm.sh                                │  │
│  │       │                                              │  │
│  │       ├─ apt: qemu-system-aarch64, cloud-image-utils │  │
│  │       ├─ wget noble-server-cloudimg-arm64.img        │  │
│  │       ├─ qemu-img create qcow2 overlay (20 G)        │  │
│  │       ├─ cloud-localds seed.iso  ← user-data         │  │
│  │       └─ exec qemu-system-aarch64                    │  │
│  │              │                                       │  │
│  │              ▼                                       │  │
│  │   ┌─────────────────────────────────────────────┐    │  │
│  │   │  QEMU TCG (no KVM — cross-arch)             │    │  │
│  │   │   -M virt  -cpu max  (SVE2, ARMv8.5+)       │    │  │
│  │   │   ┌──────────────────────────────────────┐  │    │  │
│  │   │   │  Guest: Ubuntu 24.04 arm64           │  │    │  │
│  │   │   │   sshd :22  ──hostfwd──▶  WSL :2222  │  │    │  │
│  │   │   └──────────────────────────────────────┘  │    │  │
│  │   └─────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

Key choices:
- **Cloud image + cloud-init**, not the live-server ISO installer. Standard arm64 path; first boot provisions user/ssh from a NoCloud seed ISO.
- **`-cpu max`** is what exposes SVE2 in QEMU ≥ 7.0. This is the whole point.
- **TCG, not KVM.** Cross-arch emulation; expect 5–15 min first boot.
- **qcow2 overlay** on top of the read-only base image, resized to 20 G — re-creating the VM is a `rm vm/ubuntu-arm64.qcow2 && ./install-arm64-vm.sh prepare` away.
- **`-nographic`**, serial console only — WSL2 has no display server.

## Design

One script, `install-arm64-vm.sh`, with idempotent subcommands so any step can be re-run alone:

| Subcommand | Action | Verify |
|---|---|---|
| `preflight` | WSL2 detected, cwd not `/mnt/*`, RAM ≥ 6 GB, disk ≥ 6 GB free | aborts with actionable error otherwise |
| `deps` | `apt install qemu-system-arm qemu-utils qemu-efi-aarch64 cloud-image-utils wget …` | `command -v qemu-system-aarch64` |
| `fetch` | `wget` noble-server-cloudimg-arm64.img if missing | size > 400 MB |
| `prepare` | probe AAVMF path, copy UEFI + vars, qcow2 overlay 20 G, ed25519 keypair, cloud-init seed.iso | `qemu-img info` shows 20 G |
| `run` | `exec qemu-system-aarch64 -M virt -cpu max …` with serial→stdio, hostfwd 2222→22 | `login:` on serial; SSH works |
| `all` | preflight → deps → fetch → prepare → run | end-to-end |

### Files produced under `./vm/`

```
noble-server-cloudimg-arm64.img   # base, read-only source (~600 MB download)
ubuntu-arm64.qcow2                # 20 G qcow2 overlay (sparse, ~200 KiB at start)
seed.iso                          # cloud-init NoCloud seed
QEMU_EFI.fd  QEMU_VARS.fd         # UEFI firmware + per-VM vars
user-data  meta-data              # cloud-init source
id_ed25519  id_ed25519.pub        # SSH keypair injected into the guest
```

### Generated QEMU command

```
qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=vm/QEMU_EFI.fd \
  -drive if=pflash,format=raw,file=vm/QEMU_VARS.fd \
  -drive if=virtio,format=qcow2,file=vm/ubuntu-arm64.qcow2 \
  -drive if=virtio,format=raw,file=vm/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

## User guide

### Prerequisites

- Windows 10/11 with WSL2 + an Ubuntu distro.
- Inside WSL2: `sudo` access (for `apt install`).
- ≥ 6 GB free disk on the Linux ext4 side; `~/` is fine, `/mnt/c/...` is not.
- ≥ 6 GB RAM available to WSL2. Configure in `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  memory=8GB
  ```
  then `wsl --shutdown` from a Windows shell.

### Quick start

```bash
git clone … armv9qemu && cd armv9qemu
./install-arm64-vm.sh all
```

`all` chains preflight → deps → fetch → prepare → run. Expect:
- `deps`: a sudo password prompt.
- `fetch`: ~1–2 min download.
- `prepare`: instant.
- `run`: VM boots on serial console; **first boot takes 5–15 min** under TCG. SSH becomes reachable around the 6–7 min mark; cloud-init finishes around 11–12 min.

### Logging in

From the WSL terminal (recommended):
```bash
ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost
```
Or use the password fallback set by cloud-init: user `ubuntu`, password `ubuntu`.

From Windows (PowerShell/cmd): same command works on **Windows 11** (localhost passthrough). On **Windows 10**, set up `netsh interface portproxy` from a Windows admin prompt:
```
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=<wsl-ip>
```
(`<wsl-ip>` from `wsl hostname -I`.)

### Verify SVE2

```bash
ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost \
  'uname -m && grep -m1 ^Features /proc/cpuinfo | tr " " "\n" | grep -E "^sve2$"'
# aarch64
# sve2
```

### Lifecycle

| Action | Command |
|---|---|
| Re-run a single step | `./install-arm64-vm.sh prepare` (or any other) |
| Stop the VM cleanly | `ssh ... sudo poweroff` |
| Force-kill | `Ctrl-A X` on the serial console, or `kill $(pgrep -f qemu-system-aarch64)` |
| Wipe & rebuild guest disk | `rm vm/ubuntu-arm64.qcow2 vm/QEMU_VARS.fd && ./install-arm64-vm.sh prepare` |
| Wipe everything | `rm -rf vm/` |

### Tuning

- `SMP` / `MEM` / `SSH_PORT` / `DISK_SIZE` are at the top of `install-arm64-vm.sh`.
- `VM_DIR` env var moves the artifact directory; must still be on ext4.

## Limitations

- **Slow.** TCG arm64-on-x86 is ~10–50× slower than native. No way around it without an arm64 host.
- **Single distro.** Ubuntu 24.04 arm64 only. No branching for other guests.
- **No KVM, ever.** Wrong architecture; not a configuration option.
- **WSL2 only.** Native Linux works in practice but is out of scope (preflight refuses).
- **No GUI.** Serial console + SSH only.

## Files in this repo

```
install-arm64-vm.sh   # the script
Project.md            # design plan (kept in sync with the script)
CLAUDE.md             # behavioral guidelines for AI-assisted edits
README.md             # this file
```
