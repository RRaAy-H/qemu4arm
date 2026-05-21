# Project Plan - QEMU ARM VM With SVE2 On ARM Server

## Goal

Provide a Bash workflow on the remote Ubuntu 24.10 aarch64 server that:

1. Verifies the host is the intended aarch64 server target.
2. Installs QEMU, UEFI firmware, and cloud-init tooling.
3. Downloads the Ubuntu Server 24.04 LTS arm64 cloud image.
4. Creates a qcow2 guest disk and cloud-init NoCloud seed.
5. Launches `qemu-system-aarch64` with an emulated ARMv8.5+/ARMv9-class CPU exposing SVE/SVE2.
6. Lets the user SSH into the guest and verify SVE/SVE2.

The load-bearing requirement is guest SVE/SVE2. Since the physical Cortex-A72 host does not expose SVE, the VM must use QEMU TCG instead of KVM.

## Non-Goals

- No libvirt, virt-manager, systemd service, or GUI.
- No bridge networking unless the SSH port-forward approach becomes insufficient.
- No distro matrix. The guest is Ubuntu 24.04 LTS arm64.
- No local Windows execution support. This repo is for the remote ARM server.
- No KVM mode while SVE/SVE2 is required on the current Cortex-A72 host.

## Target Host

- OS: Ubuntu 24.10.
- Architecture: `aarch64`.
- CPU: Cortex-A72, 64 online CPUs, no SVE/SVE2 in host flags.
- Emulator: `qemu-system-aarch64`.
- Acceleration: `-accel tcg,thread=multi`.
- CPU model: `max,pauth=off,sve=on,sve128=on`.
- Machine: `virt,gic-version=3`.
- Firmware: AAVMF/UEFI from `qemu-efi-aarch64`.

## Script Breakdown

`install-arm64-vm.sh` is the authoritative entry point:

- `preflight`: checks host architecture, host SVE/SVE2 status, selected VM resources, free disk, and QEMU if already installed.
- `deps`: installs `qemu-system-arm`, `qemu-utils`, `qemu-efi-aarch64`, `cloud-image-utils`, `wget`, `openssh-client`, `genisoimage`, and `coreutils`.
- `fetch`: downloads `noble-server-cloudimg-arm64.img` if missing.
- `prepare`: copies UEFI firmware, creates `QEMU_VARS.fd`, creates the qcow2 overlay, creates the SSH key, and builds `seed.iso`.
- `run`: validates QEMU, launches the VM on the serial console, and forwards host port `2222` to guest SSH port `22`.
- `all`: runs `preflight`, `deps`, `fetch`, `prepare`, and `run`.

`startvm.sh` is intentionally just a wrapper for `./install-arm64-vm.sh run` so resource defaults stay in one place.

## Resource Defaults

The script picks server-oriented defaults while keeping environment overrides:

- `SMP`: 75% of online CPUs, capped at `48`.
- `MEM`: 75% of host RAM, capped at `98304` MiB.
- `DISK_SIZE`: `100G` sparse qcow2 overlay.
- `SSH_PORT`: `2222`.
- `VM_DIR`: `./vm`.

These values are deliberately conservative for a shared 64-core server. Use explicit overrides when the server is dedicated to this VM, for example:

```bash
SMP=48 MEM=98304 DISK_SIZE=200G ./install-arm64-vm.sh all
```

## QEMU Command Shape

```bash
qemu-system-aarch64 \
  -accel tcg,thread=multi \
  -machine virt,gic-version=3 \
  -cpu max,pauth=off,sve=on,sve128=on \
  -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,readonly=on,file=vm/QEMU_EFI.fd \
  -drive if=pflash,format=raw,file=vm/QEMU_VARS.fd \
  -drive if=virtio,format=qcow2,file=vm/ubuntu-arm64.qcow2 \
  -drive if=virtio,format=raw,file=vm/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -nographic
```

## Files Produced

```text
./vm/
  noble-server-cloudimg-arm64.img
  ubuntu-arm64.qcow2
  seed.iso
  QEMU_EFI.fd
  QEMU_VARS.fd
  user-data
  meta-data
  id_ed25519
  id_ed25519.pub
```

## Success Criteria

1. `./install-arm64-vm.sh preflight` accepts the Ubuntu 24.10 aarch64 server.
2. `./install-arm64-vm.sh all` reaches the Ubuntu serial console.
3. SSH works from the server with `ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost`.
4. `uname -m` inside the guest returns `aarch64`.
5. The guest `Features` line in `/proc/cpuinfo` contains `sve` and `sve2`.

Step 5 is the deciding check. If `sve2` is missing in the guest, the setup failed even if the VM boots.

## Known Risks

- TCG is slower than KVM. It is required here because KVM cannot invent SVE/SVE2 on a Cortex-A72 host.
- QEMU package paths for AAVMF can vary; the script probes common Ubuntu paths.
- QEMU CPU help output is not the final source of truth. The guest `/proc/cpuinfo` check is authoritative.
- High `SMP` values can increase TCG overhead for some workloads. The default aims to use the large server safely without consuming every core.
