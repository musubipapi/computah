# Testing

## Build checks

Run `zsh scripts/build.sh` to compile and sign the developer app.
Continuous integration (CI) runs the build and the public-file check on macOS.
It also checks the end-to-end runner's Python syntax.
CI needs no API keys or app permissions. It does not run the live tests.
A hosted CI run requires you to push the repository.

The project has no unit test suite or Swift test targets.
A successful build does not prove that commands work.

## End-to-end tests

`Tests/end_to_end.py` contains five tests:

| Test | Expected result |
| --- | --- |
| Notes | Create exactly one new note containing only `hello`. |
| TextEdit | Create exactly one new document window containing only `quiet mornings`. |
| Spotify | Play `Mary Had a Little Lamb` and observe the playback clock advance. |
| Discord | Open the current server's general text channel. Match its destination and message editor. |
| Chrome | Navigate from a blank tab to Google results for `penguins`. |

Each test generates speech locally with the macOS Samantha voice by default.
Use `--voice Daniel` to check another installed voice.
The summary records the selected voice.
The runner converts the audio to PCM16 and sends it through the signed Computah app.
Computah uses the real Deepgram and Jev connections, then operates the real target app.
There are no simulated provider replies or app controls.

The test requires a final Deepgram turn, recorded Jev requests, actual input, and a completed diagnostic report.
The document tests also compare object IDs before and after the command through each app's scripting interface.
Only the new object's content is read for the final text check.
Text comparison ignores letter case and whitespace formatting.
An existing document with the same text cannot satisfy the creation check.
More than one new object fails the test.

Spotify and Chrome checks use their scripting interfaces.
Discord checks the loaded Accessibility document against the channel link observed before the command.
The message editor must also identify the general channel.
This assertion shares the native reader with Computah, but does not use Jev to judge success.
App-specific names and assertions belong only in test fixtures.
Personal server names and channel IDs are not stored in the test source.

### Run the tests

These tests create documents, play music, change channels, and navigate Chrome.
They can send private app content to providers.
Use them only with explicit permission and an idle, unlocked Mac.

1. Set `TYPESAFE_API_KEY` and `DEEPGRAM_API_KEY` in the ignored root `.env` file.
2. Enable Accessibility access for `outputs/Computah.app`.
3. Open the apps for the selected tests. Sign in where required.
4. Pause Spotify before its test.
5. In Discord, select a server with a visible general text channel. Open a different channel in that server.
6. In Chrome, select an `about:blank` tab in the front window.
7. Quit Computah.
8. Run the following command from the project folder:

```sh
python3 Tests/end_to_end.py --live
```

To select individual tests, repeat `--case` as needed:

```sh
python3 Tests/end_to_end.py --live --case spotify --case discord --case chrome
```

Available cases are `notes`, `textedit`, `spotify`, `discord`, and `chrome`.
A missing starting condition fails the test before its speech command runs.
The runner builds the app before testing.
The `--live` flag is required. A command without this flag fails before it builds or operates apps.
macOS may request Automation permission for the terminal to read the target apps.
If permission is unavailable, the test fails.

The suite runs serially and stops at the first failure.
It never repeats an uncertain app action to obtain a passing result.
Each diagnostic has a 90-second deadline. The runner kills its child process if it exceeds 105 seconds.
If someone starts using the Mac, press **Control+C** to stop the tests.
The runner kills its active child process. It does not undo input already received by an app.

Private audio, provider traces, reports, logs, and a summary remain in a unique folder under `outputs/e2e/`.
New files use mode `0600`; new directories use `0700`.
The new documents and final app states remain for inspection.
Spotify may continue playing after the test.
Each successful speech command also saves its duration in `timing.json`.
This duration includes local speech generation; `diagnosticSeconds` records the app's reported run time.
Delete the test documents after you inspect them.

### Coverage limits

These tests cover generated speech through providers, command execution, and observed app results.
They do not check physical microphone capture, notch interaction, or every app and command.
They do not replace the detailed boundary coverage of the removed unit suite.
A passing run establishes those specific flows from their stated starting conditions.
It does not establish general accuracy or a performance guarantee.

## Project scripts

| Script | Purpose |
| --- | --- |
| `scripts/build.sh` | Compile and sign the developer app. CI uses this too. |
| `Tests/end_to_end.py` | Run live speech-to-app tests with explicit opt-in. |
| `scripts/run.sh` | Build and open one copy of Computah. |
| `scripts/check-public-tree.py` | Check public files for private data and generated artifacts. CI uses this too. |
| `scripts/clear-diagnostics.sh` | Delete the app's default saved input and run history. |

Run `python3 scripts/check-public-tree.py` before you prepare a public commit.
Also review the changes and Git history.
The script performs a limited check. It is not a complete secret scanner.
Keep individual experiments out of the maintained scripts and test folders.
Save private investigation notes under ignored `docs/local/`.

## Live checks

Live checks can read private app content, call providers, and operate your Mac.
Run them only with permission and an available, unlocked Mac.
Start each test in the intended app.
If someone starts using the Mac during the test, stop the test.
A result from the wrong app does not count as success.

Build first.
The executable is `outputs/Computah.app/Contents/MacOS/Computah`.
Pass `--root "$PWD"` when you run it from the project folder.
Keep reports and captures under ignored `outputs/`.

| Option | What it does |
| --- | --- |
| `--inspect` | Read the foreground app's controls. Do not call the model or send input. |
| `--inspect-app BUNDLE_ID` | Read a specific app. It must already be running. |
| `--inspect-initial` | Use the smaller initial read budget. |
| `--inspect-all-children` | Also read controls outside the visible area, within the read limits. |
| `--inspect-focus` | Include details about the focused control. |
| `--snapshot-json PATH` | Save the controls from an inspection. |
| `--inspect-hits LABEL` | Check pointer targets whose descriptions contain this label. |
| `--hover` | Move the pointer during `--inspect-hits`. This is a live action. |
| `--command TEXT --report PATH` | Run a command with real providers and app input. Save its result. |
| `--scenario PATH --report PATH` | Run a series of commands through the normal command controller. |
| `--audio-pcm PATH --report PATH` | Send supplied audio through Deepgram, Jev, and real app actions. |
| `--trace-dir PATH` | Save private provider requests and replies for a command run. |
| `--initial-nodes COUNT` | Change the initial control-read limit for a diagnostic run. |
| `--physical-activation` | Explicitly use the default physical clicks after target hit testing. |
| `--native-activation` | Compare AXPress delivery for controls that provide it, using the same target checks. |

Never combine `--physical-activation` and `--native-activation`.

### Scenarios and results

A scenario is a JSON array.
Each step has `command` and `afterMilliseconds`.
Use `afterIdle: true` to wait until the previous command finishes.
The optional `afterEffects` and `afterResults` fields wait for counts.
A result count does not prove that the controller is idle.
One new command can produce several results.

Reports include `diagnosticOutcome`:

| Value | Exit code | Meaning |
| --- | --- | --- |
| `completed` | 0 | The requested work completed. |
| `unconfirmed` | 2 | Completion was not confirmed. |
| `failed` | 1 | The diagnostic failed. |
| `timedOut` | 124 | The diagnostic exceeded its deadline. |

Invalid arguments, unreadable inputs, and report-write failures exit with code 1.
A timeout is never a successful result.
Scenario and audio reports record each submitted turn and its final outcome.
A completed step cannot hide an unresolved later turn.
If a later turn supersedes an earlier turn, the later turn must have a resolved outcome.
Explicit cancellation is a resolved outcome.

Commands, scenarios, and supplied-audio runs have a 90-second deadline.
Scenario and audio reports keep the latest 4,096 input-audit events.
They also report how many older events were dropped.
Lifetime effect counts remain available for scenario barriers.
A scenario barrier waits for a specified amount of progress.
These barriers use a short polling interval for interruption tests.
Routine command execution does not use that interval.

### Usage and timing

AI request totals count attempts submitted to the HTTP client.
These totals include retries, rejected responses, and early preparation.
Splitting a request locally does not count as an HTTP attempt.
Token totals are unknown when any attempt lacks provider usage data.

Results from one turn share its cumulative usage.
Do not add those results together to calculate total billing.
Step timings separate preparation and verification.
AI time is included in those phases. Do not add it to their durations.

### Supplied audio

Audio input must be raw PCM16, mono, 16 kHz, at most 60 seconds long.
This checks the speech connection and command flow.
It does not check the physical microphone or prove general speech accuracy.

## Known limits

- Spoken numeric values use native locale parsing, then model confirmation.
  Unsupported expressions require the user to state a decimal value.
  There is no fixed list of percentage values or numeric dictionary specific to an app.
- Broad accuracy is unproven.
  Jev can choose different actions from the same evidence, including the wrong playback control or an unrelated target.
- App observations can be incomplete or slow.
  A native read can exceed its time limit.
- Selections of the wrong field and incorrect object checks have occurred.
  Prompt and evidence changes still need broader live tests.
- Speech recognition can mishear a word even when the following app actions work.
  The generated-speech tests retain a fixed expected result so those errors still fail the test.
- Some controlled speech tests have passed.
  Physical microphone quality and reliable operation across apps remain unproven.

Build checks and individual successful commands do not establish general accuracy.
