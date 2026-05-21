#!/bin/bash

qemu-system-aarch64 \
  -accel tcg,thread=multi \
  -machine virt,gic-version=3 \
  -cpu max,pauth=off,sve128=on \
  -smp 36 -m 100000 \
  -drive if=pflash,format=raw,readonly=on,file=vm/QEMU_EFI.fd \
  -drive if=pflash,format=raw,file=vm/QEMU_VARS.fd \
  -drive if=virtio,format=qcow2,file=vm/ubuntu-arm64.qcow2 \
  -drive if=virtio,format=raw,file=vm/seed.iso \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -nographic
