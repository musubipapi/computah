# Development guidance

This is the canonical repository for the fast-mac-computer-use MVP. The earlier prototype was developed in a temporary Codex task folder; make future changes here.

## Scope

- Native Swift/AppKit macOS app. Keep one process and no backend unless a measured requirement justifies one.
- MVP target apps: Notes, Arc, and Photo Booth. Start execution with a complete Notes interaction.
- Speech transcription uses Deepgram Flux. TypeSafe Jev integration and Mac execution are the next components.
- Use the installed `.agents/skills/typesafe-ai/SKILL.md` for TypeSafe work and verify current API contracts against the live docs.

## Code development philosophy

Apply the grug-brained-development skill when writing, changing, debugging, reviewing, or designing code and APIs; planning implementation or testing; or refactoring and optimizing. Do not apply it merely for research, file operations, or product discussion.

- Prefer the smallest working design and an 80/20 vertical slice.
- Avoid speculative abstractions, services, frameworks, and dependencies.
- Let stable cut points emerge before factoring.
- Prefer understandable duplication over the wrong abstraction.
- Use integration tests around real boundaries.
- Refactor incrementally and optimize only from measurements.
- Treat complexity as a cost that must justify itself.

## Verification and data

- Run `zsh build.sh` after code changes; it compiles, signs, and runs the offline self-tests.
- Test provider behavior live only when needed and accurately distinguish it from offline validation.
- Never print, commit, or export API keys. Credentials use the existing app-owned Keychain service.
- Do not commit recordings, transcripts, app bundles, or local configuration.
- Mark app state unknown when unobserved; never infer that an action succeeded merely because it was dispatched.
