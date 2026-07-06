# Design: three plugin levers and a `medium` grade

Status: implemented — all three levers and the `medium` grade have landed. This
extends the plugin system from one lever (reason) to three
(reason, acquit, account), adds a `medium` confidence grade, and makes every
plugin action auditable. It exists because the reasons-only model can't express
two things a real codebase needs: a DSL that *definitely* invokes a method
(a state-machine guard), and a dynamic construct that provably *doesn't* reach a
method (a base class's `send` plumbing). Both show up dogfooding on a large
Rails codebase, where a single service-object base module wholesale-taints every
private in the service layer.

## The three levers

A plugin can make three different claims about a candidate, each with a different
failure mode:

| Lever | Claim | Mechanism | Effect on a candidate | Wrong-plugin failure → harm |
|---|---|---|---|---|
| **reason** | "this symbol *might* be a dynamic call" | adds a reason string | → `low` | noise → none |
| **acquit** | "the DSL *definitely* invokes this" | adds a real call edge from the class body | → **removed** (reached) | hides a dead method (false negative) → low |
| **account** | "this construct provably *doesn't* reach these" | un-taints a marker, per method | → `medium` / `high` | promotes a live method → bad deletion (false positive) → high |

The load-bearing asymmetry: **acquit can only ever remove a finding — it can never
promote a live method into `high`/`medium`**, so it cannot corrupt the trustworthy
buckets. `account` is the only lever that can, which is why it earns `medium` and
the heavier safeguards.

## Grade model: `high` / `medium` / `low`

- **not a candidate** — reached by a live method, *or acquitted by a plugin*.
- **`high`** — unreached, zero doubt, no plugin involvement whatsoever.
- **`medium`** — unreached and clean, but its cleanliness rests on a plugin's
  *account* of a marker. Surfaced, not CI-gating; the grade itself says
  "plugin-vouched".
- **`low`** — real doubt: a symbol reference, an *un*accounted marker, or an
  accounted marker whose reach includes this method.

The CI exit code fails on `high` only (unchanged). `medium` is advisory.

## Auditability invariant: no plugin action is invisible

Every lever's effect must be visible in the output:

- reason → the finding stays `low`, with the reason printed.
- account → the finding becomes `medium`, with "accounted by X" provenance.
- acquit → the finding leaves the candidate list, but appears in an **acquittal
  report** ("acquitted by X"), so a wrong acquit is reviewable rather than a silent
  false negative.

A plugin can never silently change the answer.

## The acquittal report

The meaningful audit set is the methods that *would have been flagged but for the
plugin*: a non-public definition that is not reached by any real call edge, but is
reached because a plugin acquitted it. Mechanically, a with/without diff in
`Reachability`: `reached_final − reached_real`, filtered to non-public definitions a
plugin's `invokes` named directly (transitive callees ride along, no separate line).

- The **count** is always in the summary when plugins are active (the minimum
  "never invisible" signal).
- The **detail** is opt-in (`--show-acquittals`).
- Acquittals do **not** affect the exit code — they aren't candidates.

```
2,698 candidate(s), 770 high, 887 medium; 41 acquitted by plugins.
   (run --show-acquittals to review)

# --show-acquittals:
Acquitted by plugins — not flagged, review the claim:
  Job#may_run?     AASMPlugin   via transitions   app/models/job.rb:9
```

## Plugin API

Three declarations, sharing `reference_macro`'s slot vocabulary; the author chooses
per macro/slot which lever applies. Anchor example:

```ruby
class AASMPlugin < Thanatos::Plugin
  inherits_from "AASM"

  # guards/callbacks are DEFINITELY invoked → acquit (removed from candidates)
  invokes :transitions, kwargs: %i[guard if unless]   # from:/to: are states, not methods
  invokes :before, :after                              # event callback symbols are invoked

  # AASM's internal define_method/send reaches the generated (public) event
  # methods, not arbitrary privates → account (unrelated privates climb to medium)
  accounts_for_dispatch reaches: :public
end
```

`accounts_for_dispatch reaches:` vocabulary: `:none` / `:public` (reaches nothing
that could be a private candidate), a `Regexp` (reaches names matching it), or the
imperative `account_for(marker)` for class-derived reaches (e.g. serializer
attributes, or a service-object base's `send`-over-declared-readers edge).

## Confidence rule (per method, replacing wholesale `markers.any?`)

For a candidate `m` over its hierarchy:

1. If `m` is reached (incl. via an acquit edge) → not a candidate.
2. Gather marker-bearing classes in the hierarchy. A marker is *accounted* if some
   applicable plugin claims it. **Any unaccounted marker → `m` is `low`** (sound
   default: unknown dynamism stays blunt).
3. If every marker is accounted → `m` is tainted only if an account's reach includes
   `m`. Tainted → `low`; else `medium` (clean, but plugin-vouched).
4. A symbol reference, explicit-call (protected), or plugin reason → `low`.
5. No marker anywhere and no other doubt → `high`.

## Sequencing (each step green; the no-plugin path stays byte-identical)

1. **Acquit + acquittal report (done).** `invokes` DSL → attributed call edges in
   `apply_plugins!`; `Reachability` returns candidates *and* an acquittals list;
   CLI count + `--show-acquittals`. Lowest-risk lever, landed first.
2. **Per-hierarchy marker resolution + explicit grade (done).** Markers resolved
   per class, confidence set explicitly (three-way, `medium` inert), the marker
   reason moved into `Reachability`. Behaviour-preserving.
3. **Account + `medium` grade (done).** `accounts_for_dispatch`/`account_for`,
   `markers_verdict` producing `:medium` with provenance, the CLI medium count.
   The one step that changes output toward promotion; the no-plugin path stays
   byte-identical, the reclaim behaviour is pinned by unit tests.

The regression net throughout is a byte-identical check of the no-plugin path
against a pinned snapshot of a real Rails codebase; the with-plugin behaviour is
pinned by unit/behaviour tests.

## What does not change

Registration (`Thanatos.configure`), the reasons-only path (`reference_macro`,
symbol literals, callbacks), and the zero-false-negative guarantee for any codebase
with no accounting plugins configured.
