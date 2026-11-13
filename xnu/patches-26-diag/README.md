# y2q SMP bring-up diagnostics (not applied by default)

Kept for the next time secondary CPUs misbehave. They apply in order on top of `patches-26/0152`:

| patch | prints |
|---|---|
| 0153 | first IRQs / sync exceptions / idle entry on secondaries, cpu0 wait heartbeat |
| 0154 | per-CPU IRQ counts (timer / ipi / dev) at powers of two |
| 0155 | secondary timer registers, CNTVCT/CNTPCT on cpu0 and cpu1, GIC redistributor state |
| 0156 | decrementer writes on secondaries, cpu_running and the rtclock deadline at idle |
| 0157 | every IRQ and decrementer write on all CPUs from the first secondary initCPU (48 lines) |
| 0158 | cpu1 (with `wfi=0`) reads cpu0's redistributor and timer state every 0.5 s |

What they found (2026-11-13): on SM8250 the arch timer node uses the standard PPIs `<13 14 11 12>`, so
the EL1 virtual timer is INTID 27, not SM8150's 19. `tools/mkadt.py --y2q` now writes
`virtual-timer-intid = 27`; with it all 8 CPUs come up and the kernel reaches the root-device wait.

To use them locally: copy the wanted files back into `patches-26/` and run
`linux-build/build.sh --sync` (WSL), or push them for CI.
