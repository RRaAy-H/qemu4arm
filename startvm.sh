#!/bin/bash

qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=vm/QEMU_EFI.fd \
  -drive if=pflash,format=raw,file=vm/QEMU_VARS.fd \
  -drive if=virtio,format=qcow2,file=vm/ubuntu-arm64.qcow2 \
  -drive if=virtio,format=raw,file=vm/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic