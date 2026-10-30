# SYNTH.R4X

`SYNTH.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.10`
- Image target: `/R4OS/SOFTWARE/TERMINAL/SYNTH.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

WAV and the PCM selftest use absolute source deadlines from the real write
attempt, with fractional ticks and a 160-ms source lead. Source/input work,
synchronous writes and Busy consume that budget. A long pause expires old
budget; resuming grants no accumulated burst credit. The final host wait covers
only remaining time. Quit skips that host wait and still invokes the actual
owned Close. Deadlines do not acknowledge device playback, and unavailable
ticks/sleep/frequency fail visibly before opening PCM. The SID/MIDI cadence
and hardware paths retain their existing contracts.

`./Build.sh test` (Windows: `Build.bat test`) runs actual app/SDK integration
cases for direct/converted exact PCM, fast/slow work, partial writes/Busy,
Pause/Resume/Quit, short tails, missing time support and real Close failures.

SID Stop preserves the kernel's private-source and shared-output receipts.
The app retries only Busy for at most three seconds, sleeping one tick between
attempts, and retains the real error/timeout result. It does not stop hardware
itself. Stop success with another producer active acknowledges this SID source;
last-source success also requires the output owner's actual Idle completion.
The same bounded Busy retry applies to SID Release and MIDI Close. Kernel428
binds exclusive sessions to the full calling process generation; program threads
share that process session, and the reaper retains actual teardown obligations
when application cleanup is skipped.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


Playback boundaries and cadence (0.78.74)
---------------------------------------
A host routine call supplies an emulated return address. Nested JSR/RTS and
balanced stack data continue until the outer return restores the caller's
stack and return target; BRK, unsupported instructions and exhausted budgets
remain failures.

Each public load replaces the entire title RAM and resets the runtime,
registers and fractional audio state, including after an invalid load.
Init must start inside the current image. Play may also start in RAM written
by that title, allowing relocated or decompressed code. Mapped I/O and absent
ROM are not executable entry points. The diagnostic loadProgram helper can
assemble multiple segments explicitly; sid_load_data never appends them.

PCM uses 48000 stereo s16le frames per second and carries integer division
remainders between intervals. The driver returns the exact byte count,
including silence; a short output buffer does not consume the interval.
The existing 3840-byte contract admits integer rates from 50 to 48000 Hz;
zero selects 50 Hz. Changing cadence starts a new remainder sequence.

R4Synth selects 50-Hz PAL VBI or 60-Hz NTSC/default CIA cadence from the
selected subtune's speed bit and clock flags. Legacy speed bits wrap after
32 subtunes; C64-compatible modern headers reuse bit 31. Its sleep accounting
uses the same cadence. A zero init address uses the effective load address.
Interrupt-driven PSID and RSID are reported as unsupported, rather than
claiming playback after only init. This remains a routine-driven renderer:
PAL oscillator/VIC timing, dynamic CIA timers and full ROM/IRQ execution
are outside this correction; NTSC cadence does not imply full NTSC emulation.

Format reference: https://hvsc.c64.org/download/C64Music/DOCUMENTS/SID_file_format.txt
