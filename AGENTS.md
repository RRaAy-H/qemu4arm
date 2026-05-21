# AGENTS.md

# Behavioral guidelines 


## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.


# Project Goal

Write a bash script to install and launch a QEMU virtual machine running Ubuntu Server 24.04 LTS (arm64) on the remote Ubuntu 24.10 aarch64 server.

The guest must expose SVE/SVE2. The physical Cortex-A72 host does not have SVE, so this repo must use QEMU TCG with `-cpu max` instead of KVM.

# Target configuration

- Host: Ubuntu 24.10 aarch64 server, Cortex-A72, 64 CPUs, no host SVE/SVE2
- Emulator: `qemu-system-aarch64`
- Acceleration: `-accel tcg,thread=multi`
- Machine: `-machine virt,gic-version=3`
- CPU: `-cpu max,pauth=off,sve=on,sve128=on` (exposes SVE/SVE2 in the guest with QEMU 7.0+)
- Firmware: UEFI via `qemu-efi-aarch64` / AAVMF
- Guest OS: Ubuntu Server 24.04 LTS arm64 cloud image (`noble-server-cloudimg-arm64.img`)
- Provisioning: cloud-init (NoCloud seed ISO) for user/ssh setup on first boot

# Technical stack
Bash


