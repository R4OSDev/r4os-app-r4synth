SYNTH.R4X
=========

R4Synth ist der Shell-Mediaplayer fuer WAV, SID und MIDI.

Build:

    cd Code\System\Software\R4Synth
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\R4Synth\zig-out\SYNTH.R4X

Projektstruktur seit 0.51.20:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4DESK-/R4AUDIO-Imports und Contract.
- Der zentrale `cd Code`-Build baut weiterhin das Image-Artefakt
  `Code\zig-out\SYNTH.R4X`.

Contract:
- R4XStart-Entry: `synth_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4DESK`, `R4AUDIO`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\SYNTH.R4X`

Das Image-Build-Script kopiert SYNTH.R4X nach /R4OS/SOFTWARE/TERMINAL/SYNTH.R4X. Testdateien
werden manuell unter Injection/Temp/ bereitgestellt und erscheinen im Image
unter C:\Temp\, z.B. C:\Temp\tada.wav.

Aktueller Stand:
- PCM-WAV mono/stereo mit 8-bit unsigned oder 16-bit signed little endian.
- WAV-Wiedergabe normalisiert intern auf stereo/s16le.
- PSID/RSID-Erkennung mit Header-Ausgabe und SID-Runtime ueber SID.R4D.
- MIDI-Wiedergabe ueber das MIDI-Backend mit Note/Program/Controller-Events.
- P pausiert, Q beendet die Wiedergabe.
