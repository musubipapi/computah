# fast-mac-computer-use

A native macOS experiment in fast voice-driven computer control: stream speech through Deepgram, interpret partial commands with TypeSafe Jev, and perform bounded actions while the user is still speaking.

## Current MVP

The implemented component is speech capture and inspection:

- Swift with AppKit, AVFoundation, and Security; no backend or third-party runtime dependencies.
- Deepgram Flux streaming transcription with provisional and completed phrases.
- Word confidence, word timestamps, turn confidence, and event diagnostics.
- App-name hints for Notes, Arc, and Photo Booth.
- Deepgram and Typesafe API-key storage in macOS Keychain.

Jev inference and Mac app control are planned, not implemented yet. Saving a Typesafe key does not send it to Typesafe or start inference.

## Build and run

Requires macOS 14 or later and Apple's command-line developer tools.

```sh
zsh build.sh
```

Open `outputs/Speech Test.app`, enter a Deepgram API key, and click **Save keys** or **Start listening**. Allow microphone access when prompted. Each test stops after 60 seconds. Optional Typesafe credentials can be saved for the next development stage.

The build runs offline self-tests for transcript revisions, metadata parsing, and audio chunking. Live recognition requires a key and a microphone test. The app is locally ad-hoc signed; macOS may ask for Keychain access again after a rebuild.

See [speech test usage and diagnostics](docs/speech-test.md) for details.

## Next milestones

1. Inspect Notes' accessibility structure and display a small, observed Mac-state snapshot.
2. Evaluate partial transcripts and observed state with Jev, showing proposed actions and request timing.
3. Connect and verify one complete interaction: open Notes, create one note, and insert dictated text.
4. Extend the working path to Arc and Photo Booth.

Keep latency measurements separate from audio timestamps. The current microphone-start timer includes engine startup, so its offset from Deepgram's audio timeline is not yet calibrated.

## Development

- `Sources/SpeechTest.swift`: native UI, microphone pipeline, Flux connection, metadata, Keychain, and self-tests.
- `Sources/Info.plist`: app identity and microphone usage description.
- `.agents/skills/typesafe-ai/`: official TypeSafe development skill and its license.
- `outputs/`: generated app bundle, ignored by Git.

API keys belong in Keychain, never in source or checked-in configuration. The app does not persist microphone recordings or transcripts. Keep observed app state separate from proposed actions and verify outcomes before marking actions complete.
