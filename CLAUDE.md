# CLAUDE.md

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

Write a bash script to install and launch a QEMU virtual machine running Ubuntu Server 24.04 LTS (arm64) on an x86 WSL Ubuntu host.

The guest must emulate an ARMv9-capable / ARMv8+ arm64 CPU with SVE2 ISA support. 

# Target configuration

- Host: x86_64 WS
- Emulator: `qemu-system-aarch64`
- Machine: `-M virt`
- CPU: `-cpu max` (exposes SVE2 and ARMv8.5+/v9 features in QEMU 7.0+)
- Firmware: UEFI via `edk2-aarch64` (AAVMF)
- Guest OS: Ubuntu Server 24.04 LTS arm64 cloud image (`noble-server-cloudimg-arm64.img`)
- Provisioning: cloud-init (NoCloud seed ISO) for user/ssh setup on first boot

# Technical stack
Bash


