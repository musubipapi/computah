# What Computah sends to Jev

Computah sends text and named choices to TypeSafe's Jev model.
The text describes the request, relevant app controls, and observed results.
Jev selects from the supplied choices. Code checks the answers and operates the Mac.

This document describes the current implementation.
The examples use fictional app data. They are not saved user sessions.

## The request format

The default endpoint is `POST https://api.typesafe.ai/v1/systemone`.
The default model is `jev-1.13.0`.
The API key goes in the `Authorization` header.

Each JSON body has three fields:

| Field | Contents |
| --- | --- |
| `model` | The requested model name. |
| `state` | Shared information for the questions in this request. |
| `questions` | Named questions, each with instructions and a map of allowed answers. |

Every current question uses `type: "choice"`.
Each `criteria` entry maps an answer ID to its meaning.
Computah adds `none_here` so Jev can report uncertainty or no applicable answer.

Independent questions can share one request.
They receive the same state, but cannot read each other's answers.
Dependent decisions can require another request.

## Example: select a control

This example shows only the `action` question.
A normal planning request also asks about the instruction boundary, route, and source value.
Instructions and control descriptions are shortened here.
The full prompt text lives in [language.json](../Sources/ComputahCore/Prompts/language.json).

```json
{
  "model": "jev-1.13.0",
  "state": {
    "original_request": "Type hello",
    "consumed_utf16": 0,
    "remaining_request": "Type hello",
    "verified_progress": [],
    "source_tokens": [
      {"id": "t0", "text": "Type", "start_utf16": 0, "end_utf16": 4},
      {"id": "t1", "text": "hello", "start_utf16": 5, "end_utf16": 10}
    ],
    "observed_scene": "app=Demo Editor; window=Draft; partial=false",
    "coverage": {},
    "secondary_capabilities": [],
    "available_controls": [
      "AXTextArea; label=Document body; value=; focused=false",
      "AXButton; label=Done; enabled=true"
    ]
  },
  "questions": {
    "action": {
      "type": "choice",
      "instructions": "Choose the observed control action that advances the current instruction.",
      "criteria": {
        "n7_typeText": "Type text into the Document body text area.",
        "n9_pressClick": "Click the Done button.",
        "none_here": "No offered action applies, or the evidence is insufficient."
      }
    }
  }
}
```

A fictional answer could be:

```json
{
  "answers": {
    "action": {
      "type": "choice",
      "choice": "n7_typeText",
      "confidence": 0.94,
      "probabilities": {
        "n7_typeText": 0.94,
        "n9_pressClick": 0.01,
        "none_here": 0.05
      }
    }
  }
}
```

Code checks the answer IDs and probability values.
It maps `n7_typeText` back to a retained native control.
The answer does not contain a script or a new control reference.
Other judgments identify `hello` through source positions before code can type it.
Native focus, target, and cancellation checks still apply.

## Planning data

The planner builds these fields from the transcript and current observation.
An instruction is the part of a request whose result can be checked separately.

| State field | What it contains |
| --- | --- |
| `original_request` | The original command text. Credential filtering applies before transmission. |
| `consumed_utf16` | The position already consumed in the original text. |
| `remaining_request` | The uncompleted text, or the active instruction during continuation. |
| `source_tokens` | Word and punctuation IDs, text, and original source positions. These are not model tokens. |
| `verified_progress` | Supplied progress notes, including verified instructions and intermediate results. |
| `observed_scene` | A filtered text summary of the app, window, and selected observations. |
| `coverage` | Counts of observation gaps by reason, when an observation exists. |
| `secondary_capabilities` | Regions with deferred operations, their operation names, and counts. |
| `available_controls` | Descriptions of offered controls when the questions include control metadata. |

Source positions use UTF-16 code units.
Code uses these positions to extract original text instead of asking Jev to rewrite it.

Additional fields appear only when needed:

| State field | When it is used |
| --- | --- |
| `active_instruction` | Continue or recover an instruction already selected. |
| `conversation_context` | Resolve references using unresolved utterances or a completed request and its observed result. |
| `instruction_revisions` | Supply revised source text and token IDs. |
| `operation_targets` | Describe controls that support multiple operations. |
| `selected_target`, `selected_control` | Ask about operations or values for a selected control. |
| `prior_binding`, `current_binding` | Compare the earlier object context with the current observation. |

Selected control fields include `role`, `label`, `current_value`, and `focused`.
Binding evidence can include identifiers, document references, labels, values, parent labels, focus, and selection.

## Planning questions

These are question keys before any splitting for request limits.
Conditional questions can be absent. Unneeded answers do not authorize an action.

| Question | Allowed answers or purpose |
| --- | --- |
| `boundary` | Select the last source token of the next instruction. Omitted when the instruction is fixed. |
| `route` | Choose `application`, `navigation`, or `controls`. |
| `application` | Select an installed app by an offered `appN` ID. Descriptions include its name, aliases, and bundle ID. |
| `action` | Select a control, `inspect_secondary`, `reobserve`, or `already_satisfied`. |
| `operation_target_nN` | Select an operation on a control with multiple capabilities. |
| `format` | Choose `absent`, `literal`, `address`, `number`, or `percent`. |
| `value_start`, `value_end` | Select source token IDs that bound the input value. |
| `continuation_binding` | Choose `app_scope`, `fresh_target`, `same_document`, or `changed_or_unknown`. |

Every question also offers `none_here`.
The `application` question offers `unavailable` when no app catalog is supplied.
The planner can ask operation questions for two targets before the action answer arrives.
It uses only the answer for the selected target. Other targets can require a later question.

## How controls fit within the limits

Computah does not serialize the complete Accessibility tree into a Jev request.
It prepares native action candidates and a separate scene summary.

Candidate descriptions include the operation, role, label, and region.
Available context can include help text, purpose, current value, nearby text, row text, focus, selection, and numeric limits.
Multiple operations on one control share a `target_nN` choice.
A control with one operation can use an ID such as `n7_typeText` directly.

The scene summary includes disabled, focused, and selected controls, plus samples from visible collections.
It also states observation gaps. Missing evidence does not establish that a control is absent.

Two different forms of grouping apply:

1. Native structure groups controls into regions and operations into targets.
2. Request limits split long option lists into smaller lists for Jev.

The default budget is 254 supplied options plus `none_here`.
The action question uses 64 supplied options plus `none_here`.
Split keys can look like `action_part0`.
The selector retains up to three candidates per result and compares finalists in another request.
If all parts choose `none_here`, it preserves that answer.

The client also limits each serialized body to less than 180,000 bytes.
On a context-limit failure, it splits questions or option lists further.
It stops with an error if further splitting cannot make progress.
Source and revision choices together must fit within 254 tokens.
These limits bound requests; they do not guarantee that every useful control was observed or retained.

## Other requests

### Relate a new command to earlier work

A separate request can ask whether a new utterance replaces, revises, resumes, appends to, or cancels unfinished work.
Its state contains `original_request`, `source_tokens`, `prior_goal`, and `observed_scene`.

`prior_goal` includes the previous request, remaining instruction, revisions, progress, execution status, and bound scene.
It also describes any dispatched action whose result is still unknown, and unresolved newer utterances.
The `relationship` question offers `replace`, `revise`, `resume`, `append`, `cancel`, and `unclear`.
The `append_start` question selects where an appended instruction begins.

This request can run alongside preparation for the new command.
The previous unfinished goal is kept out of that initial action preparation to avoid carrying its target into a replacement command.

### Convert a source value

Literal text comes from the selected source span.
An already valid address or directly parsed number does not need a conversion request.
Other cases can require these questions:

| Conversion | State | Choices |
| --- | --- | --- |
| Spoken address | `address_source`, `tokens` | For each `address_N` question: copy the token, select punctuation, or abstain. |
| Written-out number | `value_source` | A `number` question selects among numeric interpretations prepared by code. |

For example, Jev can decide that a spoken token means a period in an address.
Code then validates the resulting URL. A command-word replacement list does not make that decision.

### Find missing choices

Recovery usually reuses planning fields with a fixed instruction and scoped progress notes.
Large secondary lists can first require a region choice.
That request contains `instruction`, `revisions`, `scene`, `verified_progress`, and `reference_context`.
Region descriptions include a label, count, and sample actions. A `fresh_visible` choice requests another visible read.

### Check the result

After input, Computah reads the app again.
Verification requests can include:

| State field | Contents |
| --- | --- |
| `user_goal` | The current instruction with relevant revision context. |
| `observed_evidence` | Bounded text describing observations before and after the action. |
| `attempted_action` | The `operation`, described `target`, and `source_value`; empty for some checks. |
| `instruction_history` | Observed progress for this instruction. |
| `reference_context` | Context for references, including earlier verified instructions. |
| `before_evidence` | Historical evidence when checking an already-satisfied claim. |
| `native_window_facts` | Known window comparisons, such as `same_native_window` and `current_window_existed_before_action`. |

Evidence can include control values, focus, selection, nearby controls, collection samples, and observed changes.
The default evidence budget is 12,000 characters. Omitted observations remain unknown.

Control checks ask separate questions in the same request:

| Question | Choices |
| --- | --- |
| `outcome` | `complete`, `progress`, `contradicted`, `pending`. |
| `object` | `same_intended_object`, `wrong_object`, `unknown`. |
| `progress_effect` | `resolved`, `conflicting`, `unknown`. Asked when progress is an allowed outcome. |

Each also offers `none_here`.
Other verification paths use smaller choice sets.
For example, an already-satisfied check offers `complete` or `pending`, plus the object question.
An exact observed destination URL can pass a native check without another Jev request.

A dispatched action alone cannot establish completion.
An uncertain result does not grant permission to repeat the action.

## Data boundaries and inspection

Jev receives no microphone audio or screenshots from this flow.
Audio goes to Deepgram. Jev receives transcript text and the selected app evidence described above.
Native Accessibility references and execution permissions stay in the local process.

Labels, text values, window titles, document references, and command history can contain private information.
Credential filtering masks selected patterns. It does not remove all private app content.
See [Privacy](PRIVACY.md) for storage and provider details.

Debug Mode shows decision summaries. It does not show the full HTTP body.
For an explicitly enabled diagnostic run, `--trace-dir PATH` saves private request and response JSON.
Use an ignored directory under `outputs/`. Do not commit these traces.
See [Testing](TESTING.md) for diagnostic options.

Optional cost tracking reads provider usage fields at the HTTP boundary.
It does not add model questions or requests.

## Source map

| Source | Responsibility |
| --- | --- |
| [JevChoice.swift](../Sources/ComputahCore/Language/JevChoice.swift) | HTTP body, choice splitting, response checks, and tracing. |
| [CommandLanguage.swift](../Sources/ComputahCore/Language/CommandLanguage.swift) | Planning state, source choices, relationships, and value conversion. |
| [language.json](../Sources/ComputahCore/Prompts/language.json) | Full prompt meanings and instructions. |
| [AXGrouping.swift](../Sources/ComputahCore/Accessibility/AXGrouping.swift) | Native targets and action candidate descriptions. |
| [VerificationEvidence.swift](../Sources/ComputahCore/Commands/VerificationEvidence.swift) | Scene, binding, and result evidence. |
| [Recovery.swift](../Sources/ComputahCore/Commands/Recovery.swift) | Scoped recovery and region questions. |
| [Workflow.swift](../Sources/ComputahCore/Commands/Workflow.swift) | Result questions and execution flow. |
| [SensitiveText.swift](../Sources/ComputahCore/Diagnostics/SensitiveText.swift) | Credential filtering before transmission and trace storage. |
