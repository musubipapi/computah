# Generalization standard

Use this standard when you debug, review, or change command interpretation, control discovery, action delivery, recovery, or verification.
It applies to code and prompts.
Moving a special case into a prompt does not prove that the rule works in other cases.

## Acceptance rule

A fix must address a stated cause of failure.
The command that exposed the failure must pass.
That result alone does not prove that the fix applies more broadly.

Before you adopt a behavioral fix:

1. Describe the failure without an app name or the original command's wording.
2. State the invariant that the implementation must preserve.
   An invariant is a condition that must remain true during execution.
3. Identify the observed facts or API contract that justify each decision.
4. Check the original failure, an unrelated example, and a counterexample where the proposed rule must not apply.
5. Review existing rules for the same responsibility.
   Consolidate overlapping rules when you understand their behavior.
   Do not add another exception by default.
6. State what remains unproven, including response time and accuracy limits.

Do not infer intent from app names, command keywords, phrase lists, or regular expressions that match verbs.
Model judgments interpret the original request in context.
Code validates typed decisions, source text ranges, permission to execute, and observed state.

## What a general solution preserves

### Observation

- Keep observed facts separate from inferred meaning.
- Preserve native object identity and observation coverage.
  Keep a missing object distinct from an object that was not read.
- A newly observed node is not necessarily a newly created object.
- A provider's successful return is not proof of the requested effect.

### Selection and compression

- Group related evidence without assuming that parent and child actions are equivalent.
- Preserve access to distinct actions.
  Recovery must provide a way to find choices that were deferred.
- Retain the original targets and relationships when you compress descriptions.
- Treat ranking, truncation, and shortlist sizes as heuristics with explicit limits.
  A heuristic is a practical rule whose reliability depends on the situation.
  Test changes in tree order, irrelevant controls, and competing valid options.

### Execution and recovery

- Base input on a current target, its available capabilities, and permission to send input.
- Keep input delivery separate from judgments about what the user wants.
- Do not repeat uncertain input to discover whether it worked.
- Distinguish repeated uncertain input from a new intentional action on the same control after verified progress.
  Neither repetition nor prohibition is automatic.
- Limit observation and recovery.
  Extra waiting must address an observed readiness problem.
  Do not add delays merely because one example became reliable.

### Completion

- Verify every effect required by the active instruction against the intended object.
- A successful operation can be intermediate progress.
  It does not automatically complete the instruction that selected it.
- A count change, label, or value provides limited evidence.
  Preserve alternative explanations and require enough evidence for the requested result.
- Preserve these rules during normal execution, interruption, and reconciliation.
  Reconciliation checks earlier effects before work continues.

## Classify each conditional

| Kind | Required justification |
| --- | --- |
| API or data contract | A documented protocol, type, capability, or syntax rule. |
| Execution invariant | A required property, such as target identity or cancellation authority. |
| Resource limit | The limited resource and behavior at its limit. Include the measured tradeoff when you adjust the limit. |
| Semantic judgment | A model decision based on the original intent and observed evidence, with an option to abstain. |
| Heuristic or workaround | The cause of failure, applicable conditions, a counterexample, and evidence of benefit. |

The absence of an app-name check does not make a heuristic general.
Structural rules can also fit only the examples used to develop them.
Review existing heuristics. Do not delete protections without understanding them.

## Evidence for a change

Record these items in the review or private investigation note:

- The failure and invariant.
- The relevant code or prompt locations.
- The facts that support the decision, and the facts that the decision cannot establish.
- The original failure, an unrelated positive case, and a negative counterexample.
- The effects on missing choices, repeated input, object identity, and partial observations.
- The measured response time when you make a performance claim.
- The remaining uncertainty and any deliberate scope limits.

Use integration tests at real system boundaries where practical.
Scripted model answers test command coordination. They do not establish interpretation accuracy.
Provider comparisons must judge outcomes from evidence.
The return of the desired ID alone is not sufficient.

Live tests require explicit permission and an available Mac.
Keep captured app content private.
Reuse saved evidence when appropriate.
Do not broaden live testing without a concrete question.

## Audit format

For each finding, record:

- The priority and location.
- The current rule and cause of failure.
- The confidence in the finding.
- The existing test coverage and missing counterexample.
- The proposed direction for a general solution.

Distinguish a reproduced defect from a possible defect found by code review or a gap in measurements.
Also record protections that should stay.
A list of suspicious constants alone is not an audit.

Public documentation contains this standard.
Dated audits, captures, and working plans belong under ignored `docs/local/` or `outputs/`.
