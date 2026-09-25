# Listening cues

- `sparkle.wav` plays when listening starts.
- `droplet.wav` plays when listening stops.

These sounds were rendered from Cuelume 0.2.2, commit `b879b72c01f3b3fa74c45c9b20bbd064baffb282`:
https://github.com/Danilaa1/cuelume

The sounds use the MIT license, copyright 2026 Daniel Belyi.
The full notice is in `Cuelume-LICENSE.txt`.
The app bundle includes that file alongside the sound files.

The renderer used the original `src/audio/engine.ts` and `src/sounds/recipes.ts` with WebKit's OfflineAudioContext.
The output format was 48 kHz mono, 16-bit PCM WAV.
Each sound lasts one second, including the shimmer tail.
The volume was 0.7, the demo's default.

The renderer exposed renderRecipe and reset the shared output between contexts.
It omitted cleanup based on elapsed wall-clock time during offline rendering.
Envelopes, oscillators, shimmer, output gain, and limiter were unchanged.
No normalization was applied.

The finished app loads these resources into NSSound at launch.
Sound playback has no JavaScript, npm, or WebKit runtime dependency.
