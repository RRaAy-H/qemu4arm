# Project Plan — QEMU arm64 Ubuntu VM with SVE2 (WSL2 host)

## Goal

A single bash script on an **x86_64 WSL2 Ubuntu** host that:

1. Verifies the host is suitable (WSL2, ext4 cwd, enough RAM).
2. Installs the required host packages (qemu-system-arm, cloud-image-utils, qemu-utils, qemu-efi-aarch64, wget).
3. Downloads the Ubuntu Server 24.04 LTS arm64 cloud image.
4. Prepares a working disk (qcow2 overlay, resized) and a cloud-init NoCloud seed ISO.
5. Launches the VM under `qemu-system-aarch64 -M virt -cpu max` so SVE2 is exposed to the guest.
6. Lets the user SSH into the guest on first boot.

## Non-goals (keep it simple)

- No libvirt, no virt-manager, no systemd units.
- No GUI / graphical console — serial console only.
- No snapshots, no live migration, no networking modes beyond user-mode TCP port forward.
- No multi-distro support. Only Ubuntu 24.04 arm64.
- No native-Linux or non-WSL host support. WSL2 only.

## Target host (WSL2-specific)

- **Distro**: Ubuntu under **WSL2** on Windows 10/11. Uses `apt`. No branching for other distros.
- **Architecture**: x86_64 host, arm64 guest. KVM is **not** used (cross-arch). QEMU runs in pure TCG emulation — slow, expected, not tuned beyond `-smp` and `-m`.
- **Disk location**: VM artifacts must live on the Linux ext4 filesystem (e.g. `~/vm/`), **not** under `/mnt/c/...`. DrvFs is ~10× slower and breaks qcow2 sparse semantics. The script refuses to run from a `/mnt/*` path.
- **RAM budget**: WSL2's RAM ceiling is set in `%UserProfile%\.wslconfig` on the Windows side. QEMU is launched with `-m 4096`; WSL2 needs ≥6 GB visible (`MemTotal` in `/proc/meminfo`) or the guest will OOM during cloud-init. Script checks and aborts with a clear message pointing at `.wslconfig`.
- **SSH access**:
  - From inside WSL: `ssh -p 2222 ubuntu@localhost` — works directly.
  - From Windows host: works on Windows 11 (localhost forwarding is automatic) but **not reliably on Windows 10** without `netsh portproxy` or mirrored networking mode. Script prints both the WSL-side and Windows-side instructions on success.

## Files the script will produce

```
./vm/
  noble-server-cloudimg-arm64.img      # base image (downloaded, read-only source)
  ubuntu-arm64.qcow2                   # qcow2 overlay, resized, used as VM disk
  seed.iso                             # cloud-init NoCloud seed (user-data + meta-data)
  QEMU_EFI.fd                          # UEFI firmware (copied from qemu-efi-aarch64 pkg)
  QEMU_VARS.fd                         # UEFI vars (per-VM copy)
  user-data                            # cloud-init: user `ubuntu`, ssh key, password
  meta-data                            # cloud-init: instance-id, hostname
```

## Script breakdown

One script, `install-arm64-vm.sh`, with subcommands so steps are independently runnable:

| Subcommand | Action | Verify |
|---|---|---|
| `preflight` | Check WSL2 (`grep -qi microsoft /proc/version`), cwd not under `/mnt/*`, `MemTotal` ≥ 6 GB, ≥6 GB free disk | All checks pass; otherwise abort with actionable message |
| `deps`    | `apt install qemu-system-arm cloud-image-utils qemu-utils qemu-efi-aarch64 wget` | `command -v qemu-system-aarch64` exits 0 |
| `fetch`   | `wget` the noble-server-cloudimg-arm64.img if missing | file exists, size > 400 MB |
| `prepare` | Probe AAVMF path (`/usr/share/AAVMF/` or `/usr/share/qemu-efi-aarch64/`), copy UEFI firmware, create qcow2 overlay on top of base, resize to 20G, generate `user-data`/`meta-data`, build `seed.iso` via `cloud-localds` | `qemu-img info` shows 20G; `seed.iso` exists |
| `run`     | `exec qemu-system-aarch64 -M virt -cpu max …` with serial to stdio, user-net forwarding host :2222 → guest :22 | boots to login prompt; `ssh -p 2222 ubuntu@localhost` works |
| `all`     | preflight → deps → fetch → prepare → run | same as `run` |

## QEMU command (target)

```
qemu-system-aarch64 \
  -M virt \
  -cpu max \
  -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=vm/QEMU_EFI.fd \
  -drive if=pflash,format=raw,file=vm/QEMU_VARS.fd \
  -drive if=virtio,format=qcow2,file=vm/ubuntu-arm64.qcow2 \
  -drive if=virtio,format=raw,file=vm/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

## Success criteria (goal-driven)

1. `./install-arm64-vm.sh all` → boot reaches `ubuntu login:` on serial console. **Verify:** prompt visible in terminal.
2. From the WSL terminal: `ssh -p 2222 ubuntu@localhost` succeeds. **Verify:** login ok.
3. Inside the guest: `uname -m` returns `aarch64`. **Verify:** string match.
4. Inside the guest: `cat /proc/cpuinfo | grep -o sve2 | head -1` returns `sve2`. **Verify:** non-empty (this is the SVE2 confirmation — the whole reason for `-cpu max`).
5. Inside the guest: `lsb_release -d` reports `Ubuntu 24.04 LTS`. **Verify:** string match.

Step 4 is the load-bearing check. If `/proc/cpuinfo` does not list `sve2` the setup has failed regardless of whether the VM boots.

## Known risks / assumptions

- `edk2-aarch64` package path differs across Ubuntu versions (`/usr/share/AAVMF/` vs `/usr/share/qemu-efi-aarch64/`). Script must probe both.
- TCG emulation of arm64 on x86 is slow; first boot (cloud-init) on WSL2 can take 5–10 minutes. Not a bug.
- WSL2 RAM cap is invisible from inside the guest's `apt` — set it via `.wslconfig` on the Windows side and `wsl --shutdown` before relaunching WSL.
- Host must have ~6 GB free disk on the ext4 side (base image + 20 GB sparse qcow2 overlay + seed).
- We do **not** install via the full `ubuntu-24.04-live-server-arm64.iso` installer — cloud image + cloud-init is the standard arm64 path.
- SSH from Windows (not from WSL) is out of scope to script around; we print guidance only.
