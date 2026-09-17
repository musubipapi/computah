# Speech Test

A native Mac microphone-to-text test using Deepgram Flux (`flux-general-en`). No Jev or computer control yet.

Open **Speech Test.app**, enter your Deepgram API key, and choose **Start listening**. Allow microphone access when macOS asks. Speak, pause, and try a correction. Choose **Stop** or press Escape to stop recording. Tests stop automatically after 60 seconds. Closing the app also stops recording.

Try:
- Open Notes and create a new note that says hello.
- Open Arc and search for weekend trips from New York.
- Open Photo Booth and take a photo.
- Open Notes—actually, open Arc.
- Create a note that says don't open Safari.

Live phrases are provisional. Completed phrases have received Flux's `EndOfTurn`. Early turn endings are not treated as final. If you stop in the middle of speech, Flux drains remaining audio but does not finalize the turn; that phrase stays in the live box.

Audio is sent directly to Deepgram over TLS only during a test. Transcripts stay in app memory and are not written to disk by this app. Deepgram processes the submitted audio under your account's settings. No other app content is collected. API usage consumes Deepgram credits.

## Saved API keys

Enter Deepgram and optionally Typesafe keys, then click **Save keys**. **Start listening** also saves populated fields before starting. Keys are stored as non-synchronizing generic-password entries in macOS Keychain under the service `local.speechtest.api-keys`, with separate Deepgram and Typesafe accounts. They load automatically when the app opens. The Typesafe key is only stored; Jev is not connected and receives no requests yet.

**Forget keys** removes both app-owned Keychain entries and clears the fields; it does not revoke credentials at the providers. Blank fields leave saved entries unchanged. Keychain failures are shown in the app, and a pasted key can still be used for the current session if saving fails. The app never prints keys or saves them in project files or preferences.

With no saved key, fields can fall back to `DEEPGRAM_API_KEY` and `TYPESAFE_API_KEY` inherited from a configured shell; Finder generally does not inherit shell variables. Forgetting saved keys does not change shell variables. This local app is ad-hoc signed, so macOS may ask you to authorize Keychain access after a rebuild; a stable production signing identity is needed for smoother updates.

## Metadata and timing

- **Finished speaking**: Deepgram's `end_of_turn_confidence`, refreshed on every accepted update, including unchanged text. It estimates whether the speaker has finished the turn; it does not measure command readiness or transcript accuracy.
- **Word details**: each word's transcription confidence and optional start/end time in seconds from the beginning of the audio stream. These are audio positions, not recognition latency. Missing or invalid values appear as `—`. Revisions replace the entire word list; the last spoken phrase stays visible during silent updates, with its original turn number.
- **App hints**: Notes, Arc, and Photo Booth are supplied as separate Flux keyterms to help recognition. Hints do not guarantee correct spelling or app intent.
- **Tabs**: switch between word details, completed phrases, and events. All remain available after Stop.

- **Connection**: request start to Deepgram's Connected event.
- **First text**: microphone start to first nonempty transcript; includes silence before speaking.
- **Audio backlog**: audio sent minus Deepgram's reported processed audio endpoint. This is an approximation of streaming backlog, not model inference time or word-level latency.
- **Events**: arrival time relative to microphone start, plus event name, turn, sequence ID, end-of-turn confidence, and finalization trigger when supplied. Nonempty transcript events are retained even when text is unchanged so confidence changes remain visible. The latest 300 are kept. Displayed turn numbers start at 1 (the API starts at 0).

These diagnostics help assess responsiveness. A controlled recording with annotated word times is needed for an accurate speech-to-text latency benchmark. No live Deepgram benchmark is claimed until a valid key and microphone test are used.

## Build

Requires macOS 14+ and Apple command-line developer tools. Run `zsh build.sh` at the repository root. The app is built into `outputs/Speech Test.app`. No third-party dependencies. The locally built app is ad-hoc signed, not notarized for distribution.

Self-tests cover revised partial transcripts, eager/resumed/final turns, duplicate and stale events, retaining unfinished text, wire JSON metadata parsing, optional/invalid values, revised word lists, keyterm encoding, and exact 80 ms audio chunking. A live API/microphone integration test is still required after changes.

## Protocol

- https://developers.deepgram.com/docs/flux/quickstart
- https://developers.deepgram.com/docs/flux/state
- https://developers.deepgram.com/docs/flux/close-stream
- https://developers.deepgram.com/reference/speech-to-text/listen-flux
- https://developers.deepgram.com/docs/keyterm

Uses `/v2/listen`, 16 kHz mono linear16 audio, 80 ms packets, a bounded upload buffer, and a graceful CloseStream on Stop. Unexpected disconnections stop the microphone; there is no automatic reconnect that could duplicate speech or extend billing unnoticed.
