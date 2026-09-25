# Development guidance

Computah is one Swift package at the repository root.
`Sources/Computah` contains the app.
`Sources/ComputahCore` owns native capabilities and command execution.

- Preserve observed source text ranges, native object binding, cancellation, and prevention of repeated uncertain input.
  Native object binding ties an action to the control that was observed.
  A sent action is not evidence of success. Unobserved state is unknown.
- Never decide intent or command boundaries with phrase lists, regular expressions that match verbs, or routing specific to an app.
  Jev interprets language in context.
  Code validates typed decisions, metadata, source ranges, limits, execution, and observed effects.
- Do not key production behavior to a target app's name, bundle ID, website, or private selectors.
  Test fixtures may name apps.
  AXPress and simulated clicks are allowed when current native capabilities support them.
- Apply the [generalization standard](docs/GENERALIZATION_STANDARD.md) to behavioral fixes and audits, including prompts.
  State the cause of failure and the invariant.
  Check the original failure, an unrelated case, and a counterexample before you claim that a fix applies more broadly.
  Passing one requested command is not sufficient.
- Keep UI and speech out of the core.
  Keep prompt meanings in resources where practical.
  Do not shorten or change them as a cosmetic refactor.
- Run `zsh scripts/build.sh` for an offline build and a signed developer bundle.
  The end-to-end tests are in `Tests/end_to_end.py`.
  Run them with `--live` only after explicit permission and confirmation of an available Mac.
  Live app/API diagnostics require explicit permission and an available Mac.
  Do not run them as part of cleanup, CI, or routine tests.
- Keep credentials only in ignored `.env` at the repository root, with mode `0600`.
  Never print or commit keys, captures, recordings, transcripts, bundles, or personal app content.
- Save detailed diagnostics only with explicit permission.
  Use `PrivateFile` for private writes.
  Redaction does not make ordinary app content safe to publish.
- Keep plans and review notes under ignored `docs/local/`.
  Public `docs/` files explain how to use and change the current app.
  Use short sentences and plain words.
- Preserve ignored local evidence under `outputs/`.
  Do not publish app captures, recordings, source archives, or local reference downloads.
- Read [architecture](docs/ARCHITECTURE.md) and [testing](docs/TESTING.md) before you change boundaries.
  Update docs and scripts when paths or interfaces change.
