# Privacy and debug data

## Data sent to providers

- Deepgram receives microphone audio while listening is on.
- TypeSafe receives commands and selected app content to choose actions and check results.
- App content can include document text, names, addresses, and other private information.

The app reads API keys from `.env` at the project root.
Never commit that file.
Computah masks some credential patterns, but it does not remove all private data.

Detected credential text stays masked when commands are split into model tokens, values, revisions, and progress context.
The original source text positions remain local for input.
If a protected value requires model conversion, Computah asks for a literal address or decimal value.
It does not send the isolated protected fragment for that conversion.

Model requests run on provider servers.
This project does not control how long providers keep the data.

## Save debug history

By default, the app keeps the latest 30 results in memory.
It saves no routine command history to disk.
Quitting the app clears that history from memory.

To save history, quit the app.
Start it with this option:

```sh
zsh scripts/run.sh --record-diagnostics
```

The app saves final input text and run details in `outputs/computah/`.
These files can contain app content.
This option does not save raw microphone audio or partial transcripts.
Files remain until you delete them.

The panel reads only the newest 30 saved reports in the background.
It merges those reports with current results.

To delete the default saved history:

```sh
zsh scripts/clear-diagnostics.sh
```

This command does not clear history from the running app's memory.
Quit the app to clear that history.

## Track Jev costs

**Track Jev costs** in Debug Mode is off by default.
When enabled, it saves aggregate request counts, input tokens, estimated cost, and the start date.
It does not save commands, audio, app content, or API keys.
The file is `outputs/computah/jev-costs.json` and uses the same private file permissions as diagnostics.

The setting and total survive restarts.
Turning the option off stops counting new requests. Replies to already counted requests can still update the total.
**Reset…** clears the local total. It does not change your provider bill.
The history cleanup script keeps this cost file.

Totals cover requests from this checkout while tracking is enabled, including retries and early preparation.
Run one Computah instance at a time so separate processes do not overwrite the same total.
Missing usage after cancellation, failure, or a process exit remains unknown.
The estimate does not include Deepgram or usage from other clients.

The current rate for Jev 1.13 is $0.042 per million input tokens. Output tokens are free.
This public list price was checked on September 25, 2026 against [TypeSafe's model pricing](https://docs.typesafe.ai/models).
A model without a known price is marked unpriced.
The estimate can differ from your bill because of missing usage, pricing changes, or account terms.

## Other diagnostic files

The `--report`, `--trace-dir`, and `--snapshot-json` options save the requested data to a path you choose.
These files can contain private content.
Delete them yourself. The default cleanup script does not remove custom reports or traces.
Command-line diagnostics can also print private content to the terminal.

The app creates private files before it writes their contents.
It then replaces the destination file.
New files use mode `0600`; new directories use `0700`.
These permissions do not protect copies, backups, or data saved by other tools.

## Keep private files out of Git

Git ignores `.env`, `outputs/`, build files, app bundles, and `docs/local/`.
Keep plans and review notes in `docs/local/`.
Keep real test data in `outputs/`.
Do not force-add ignored files.

The public-tree check finds some unwanted files and secret patterns.
It does not find every possible secret or review Git history.
Read the proposed changes and history before you publish them.
