---
name: ticket-queue-discipline
description: >-
  Agent-only judgment for tracker-backed ticket work.
  Load before claiming, dispatching, closing, or auditing tickets in a project tracker
  so readiness, claims, and close reasons stay tied to live canon rather than scratch state.
user-invocable: false
metadata:
  internal: true
---

# ticket-queue-discipline

This skill is judgment only.
Mechanizable claim, close, and status mutations belong in code and trackers, not here.
Load before claiming, dispatching, closing, or auditing tracker-backed ticket work.

## One live tracker

Treat one tracker as authoritative.
A per-ship scratch copy is never a source of readiness or claims - it drifts the moment work lands elsewhere.
Query live; never cache tracker state in durable firstmate records.

## Claim at dispatch

Claim atomically at dispatch (`bd update <id> --claim` or the project's equivalent write-to-canon claim).
The value is the forced write to canon at the moment work is chosen, which is the verification step that catches already-delivered tickets before a worker starts.

## Verify at pickup

Check acceptance criteria against code and merge history, not against an impression of the ticket.
"Unclear" is a permitted answer and escalates - guessing acceptance criteria ships the wrong work.

## Close with a satisfied-by reason

Close only with a satisfied-by reason that names the merged PR.
A close without a land pointer makes later audits invent causality.

## Decision classes

- **Decide alone** - defects inside accepted criteria.
  Reason: the ticket already authorized that fix surface.
- **Decide-and-report** - converging fix rounds, or fail-closed refusals that still leave the ticket on its intended path.
  Reason: the captain needs the trail without owning every mechanical correction.
- **Stop-and-escalate** - the same defect family surviving twice, a new schema/contract/public interface, or a finding where the ticket fails its own criteria either way.
  Reason: continuing alone burns cycles or freezes a bad contract.
- **Stop-for-the-captain** - widening or narrowing the product, accepting a residual, production, credentials, or customer data.
  Reason: those choices are authority, not implementation detail.

Log real decisions only - never routine mechanics - because the log is sampled and noise hides the few lines that matter.

## Convergence

Falling counts of distinct defects means keep going.
The same family surviving repeatedly means stop and reassess.
Without that distinction, thrash looks like progress.

## Decision becomes a test

Every decision becomes an executable test that would fail if the decision were reversed or dropped.
An untested decision is an oral history and will be lost on the next pass.

## Evidence honesty

A check rollup containing any FAILURE is not "green" without naming what failed and why it no longer counts.
"No checks reported" means UNPROVEN, never green.
Never report an instruction delivered without confirming it landed.
False green is worse than a visible red: it ends supervision of work that is still broken.
