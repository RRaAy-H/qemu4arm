# qemu4arm

Boot an Ubuntu 24.04 arm64 VM with SVE/SVE2 visible inside the guest on the Ubuntu 24.10 aarch64 server.

The server CPU is Cortex-A72 and does not expose SVE. That means KVM cannot satisfy this repo's goal: KVM can only virtualize CPU features the physical CPU has. This repo intentionally uses QEMU TCG with `-cpu max` so QEMU emulates an ARMv8.5+/ARMv9-class CPU with SVE/SVE2.

## Target Host

- Host OS: Ubuntu 24.10 aarch64.
- Host CPU: Cortex-A72, 64 cores, no host SVE/SVE2.
- Emulator: `qemu-system-aarch64`.
- Acceleration: `-accel tcg,thread=multi` on purpose.
- Guest OS: Ubuntu Server 24.04 LTS arm64 cloud image.
- Firmware: AAVMF/UEFI from `qemu-efi-aarch64`.
- Provisioning: cloud-init NoCloud seed ISO.

This does not run on the local Windows machine. Run it on the remote ARM server.

## Quick Start

```bash
git clone ... qemu4arm
cd qemu4arm
./install-arm64-vm.sh all
```

`all` runs `preflight`, `deps`, `fetch`, `prepare`, then `run`.

The first boot can take a while because this is CPU emulation, not KVM. The VM runs on the serial console with SSH forwarded from host port `2222` to guest port `22`.

For normal use, start the VM inside `tmux` so it keeps running after your SSH session to the server disconnects:

```bash
sudo apt install -y tmux
cd ~/qemu4arm
tmux new -s qemu4arm './install-arm64-vm.sh all'
```

Detach from the VM console with `Ctrl-b` then `d`. Reattach later with:

```bash
tmux attach -t qemu4arm
```

## Ubuntu 24.10 Apt Sources

Ubuntu 24.10 Oracular is no longer available from the normal `ports.ubuntu.com` repository. If `./install-arm64-vm.sh all` fails during `sudo apt update` or `sudo apt install` with `oracular Release` or package `404 Not Found` errors, move the Oracular sources to Ubuntu old releases:

```bash
sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
sudo cp -a /etc/apt/sources.list.d /etc/apt/sources.list.d.bak

sudo grep -RIl 'oracular' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
  | xargs -r sudo sed -i -E \
    's|https?://ports.ubuntu.com/ubuntu-ports|http://old-releases.ubuntu.com/ubuntu|g'

sudo apt clean
sudo apt update
```

After `sudo apt update` succeeds, run the normal command:

```bash
./install-arm64-vm.sh all
```

## Login

Connect from the ARM server host to the VM over the forwarded SSH port:

```bash
ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost
```

The VM login is:

- Username: `ubuntu`
- SSH key: `vm/id_ed25519`
- Password fallback: `ubuntu`

Password login is enabled by cloud-init, so this also works after SSH is ready:

```bash
ssh -p 2222 ubuntu@localhost
```

The same username and password work on the serial console shown in the QEMU/tmux session.

## Verify SVE2

Run this on the server after the VM boots:

```bash
ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost \
  'uname -m; grep -m1 ^Features /proc/cpuinfo'
```

Success means `uname -m` prints `aarch64` and the `Features` line contains both `sve` and `sve2`.

## Defaults And Tuning

The script chooses server-sized defaults while leaving simple environment overrides:

- `SMP`: defaults to 75% of online host CPUs, capped at `48`.
- `MEM`: defaults to 75% of host RAM, capped at `98304` MiB.
- `DISK_SIZE`: defaults to `100G` for the sparse qcow2 overlay.
- `SSH_PORT`: defaults to `2222`.
- `CPU_MODEL`: defaults to `max,pauth=off,sve=on,sve128=on`.
- `VM_DIR`: defaults to `./vm`.

Example:

```bash
SMP=48 MEM=98304 DISK_SIZE=200G ./install-arm64-vm.sh all
```

Keep `ACCEL=tcg,thread=multi` unless the goal changes. Switching to KVM on the Cortex-A72 host would improve speed but lose the required emulated SVE/SVE2 CPU features.

## Subcommands

- `./install-arm64-vm.sh preflight`: checks the aarch64 host, RAM, disk, and QEMU if installed.
- `./install-arm64-vm.sh deps`: installs QEMU, UEFI firmware, cloud-init image tools, and SSH tools.
- `./install-arm64-vm.sh fetch`: downloads `noble-server-cloudimg-arm64.img`.
- `./install-arm64-vm.sh prepare`: creates the qcow2 overlay, UEFI vars, SSH key, and cloud-init seed.
- `./install-arm64-vm.sh run`: launches the VM.
- `./install-arm64-vm.sh all`: runs the full flow.

`startvm.sh` is only a wrapper for `./install-arm64-vm.sh run`.

## Keep The VM In tmux

After the first successful `all` run, start the prepared VM with:

```bash
cd ~/qemu4arm
tmux new -s qemu4arm './startvm.sh'
```

If a `qemu4arm` tmux session may already exist, use this duplicate-safe command:

```bash
tmux has-session -t qemu4arm 2>/dev/null \
  || tmux new -d -s qemu4arm 'cd ~/qemu4arm && ./startvm.sh'
```

To start the VM in tmux automatically when the server reboots, add the same command to your user crontab:

```bash
crontab -e
```

Add:

```cron
@reboot tmux has-session -t qemu4arm 2>/dev/null || tmux new -d -s qemu4arm 'cd /home/rayh/qemu4arm && ./startvm.sh'
```

Check it after login with:

```bash
tmux ls
tmux attach -t qemu4arm
```

## Files Produced Under `./vm`

```text
noble-server-cloudimg-arm64.img   # downloaded Ubuntu 24.04 arm64 base image
ubuntu-arm64.qcow2                # sparse qcow2 overlay
seed.iso                          # cloud-init NoCloud seed
QEMU_EFI.fd  QEMU_VARS.fd         # UEFI firmware and per-VM variables
user-data  meta-data              # cloud-init source files
id_ed25519  id_ed25519.pub        # SSH keypair injected into the guest
```

## Lifecycle

Re-run one step:

```bash
./install-arm64-vm.sh prepare
```

Stop cleanly:

```bash
ssh -i vm/id_ed25519 -p 2222 ubuntu@localhost sudo poweroff
```

Force quit from the serial console with `Ctrl-A X`.

Rebuild the guest disk:

```bash
rm vm/ubuntu-arm64.qcow2 vm/QEMU_VARS.fd
./install-arm64-vm.sh prepare
```
