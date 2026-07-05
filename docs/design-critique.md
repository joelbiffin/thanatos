# Thanatos — Design Critique

A formal design review of the codebase: where the dependencies and load-bearing
assumptions sit, the weak points, and for each potential change the pros and cons
of refactoring versus leaving it. The emphasis is deliberately on weaknesses, not
strengths. References are to the code as reviewed on branch `VIBE_cli` (commit
`c73ba20`); §2.1 has since landed (`8484304`) and is marked resolved below. Performance figures (§1, §2.4) come from a `vernier`
CPU profile of a run over a Rails monolith's `app/` directory and are quoted as
shares of wall-clock time — no absolute timings, since those vary by machine.

---

## 0. The core bet (so the critique has a frame)

Thanatos makes one central bet: **reachability over a *name-based*,
*hierarchy-scoped* call graph is a good enough proxy for Ruby's dynamic dispatch,
and everything it can't see statically should be graded down, not hidden.** Almost
every strength and weakness below traces back to that bet and to a second, quieter
one: **the set of Ruby/Rails idioms worth modelling is small, fixed, and can live
in hardcoded constant tables.**

The first bet is sound and well-executed. The second is where most of the debt sits.

---

## 1. Where the dependencies and load-bearing assumptions are

| Assumption | Lives in | Where it bites |
|---|---|---|
| The whole codebase fits in one in-memory `Index` | `Analyzer`, `Index` | No incremental/parallel analysis: every run re-parses and re-walks unchanged files — about 60% of wall-clock on a monolith's `app/` is parsing + the two AST walks |
| Reachability can be recomputed per-class without caching | `Reachability#candidates` | The call graph and working sets are rebuilt per class — the analysis pass is ~⅓ of wall-clock, about half of that Set/adjacency reconstruction (the tree-walks themselves are cheap) |
| Ruby's dispatchable idioms are an enumerable fixed set | the constant tables in `IndexBuilder` + `RUNTIME_HOOKS` | `delegate`/`enum`/`attribute`/`has_many`, callbacks, and the next DSL are invisible or mis-graded |
| Name equality ≈ method identity within a scope | `Reachability#reachable_methods` | Same-named methods in one hierarchy are indistinguishable |
| "Scope = the files you passed" | `Analyzer`, `Index#resolve` | Out-of-architecture false positives; a module's verdict depends on what else was parsed |
| Prism's node shapes are stable | `IndexBuilder`, `LocalVariables` | A hard, woven-through coupling to one parser (acceptable — Prism is now canonical) |

The one to watch: **a module's candidate set changes depending on which of its
includers happen to be in scope.** The *confidence* version of this is the
vendored↔in-app flip (see [the mixin matrix tests](../test/mixin_confidence_test.rb)).
The stronger version is that a concern's private method can be a *candidate at all*
in one invocation and not in another. That's inherent to static scope-bounding, but
it means results aren't stable across "what did I point it at," which undercuts a
clean CI contract.

---

## 2. Weaknesses, with refactor-vs-leave-it for each

### 2.1 `IndexBuilder`'s six hand-balanced stacks — RESOLVED (`8484304`)

**What was wrong:** `@scope`, `@visibility`, `@facts`, `@method`,
`@singleton_context`, and `@singleton_class` had to be pushed and popped in
lockstep, but the balancing was spread across *four* different combinations
(`push_scope`/`leave`, `visit_def_node`, `visit_singleton_class_node`, and the
`define_method` macro). The `class << self` bug was exactly this — a construct
that forgot a frame.

**What changed:** the six arrays became one `@scopes` stack of `Scope` value
objects — a base class with a subclass per kind (`Namespace`, `InstanceMethod`,
`SingletonMethod`, `SingletonClass`) — so callers read `scope.singleton?` /
`scope.class_self?` instead of decoding flags. The `Scope` factories (`root`,
`method_for`, `singleton_class_for`, `define_method_for`) own the rule for which
kind each construct opens, and a visibility flip is a value replacement
(`scope.with_visibility`). Every construct pushes and pops exactly one frame, so
the balance is *structural* — the next scope-like construct adds one factory call
or it doesn't work at all. Verified behaviour-preserving: full suite green and
byte-identical output on a Rails monolith's `app/`.

### 2.2 `ClassFacts` doubles everything by dimension instead of owning a `MethodTable`

Instance and singleton are modelled as parallel fields and parallel methods
(`add_definition`/`add_singleton_definition`, `call_edges`/`singleton_call_edges`,
`definitions`/`singleton_definitions`, …), and that doubling leaks outward:
`Reachability` has `definitions_for`/`edges_for` switches keyed on a dimension
symbol, and `ClassFacts` holds two of every table. Since 2.1 the *builder* models
the dimension as first-class `Scope` kinds (`SingletonMethod` vs `InstanceMethod`),
but the *fact model* still does not — the "dimension" exists nowhere as an object
there, and the `extend`-marker asymmetry is a *symptom*: the marker union walks
one dimension's ancestry but the cross-dimension link lives elsewhere, so it was
easy to miss.

- **Refactor** (extract a `MethodTable` value object, hold two of them): kills the
  duplication, makes "do X per dimension" a loop instead of copy-paste, and
  localises cross-dimension rules (the extend asymmetry becomes one obvious place
  to decide).
- **Leave it:** the duplication is shallow (two of each, not N) and readable; a
  `MethodTable` adds an indirection for a system that may never grow a third
  dimension.
- **Call: medium — do it *if* you touch dimensions again** (e.g. to fix the extend
  asymmetry); not worth a standalone refactor.

### 2.3 Hardcoded idiom tables with no extension point — the real accuracy ceiling

`ATTR_MACROS`, `DYNAMIC_DISPATCH`, `MIXIN_METHODS`, `RUNTIME_HOOKS`, etc. encode a
fixed view of Ruby/Rails. But a Rails app defines methods through `delegate`,
`enum`, `attribute`, `has_many`, `scope`, and a hundred gem DSLs — none of which
Thanatos models. Today that mostly causes *false positives* (a method that exists
only via `delegate` looks undefined; a `before_action :x` callback only weakly
downgrades). On the 3,468-candidate monolith run, a chunk of the noise is precisely
this. The assumption "the list is small and stable" is false for Rails.

- **Refactor** (a config/registry: declare extra method-defining macros and
  callback-registering methods, à la RuboCop's extension model): raises real-world
  precision more than any algorithmic change, and turns "we don't model `delegate`"
  from a code change into a config line.
- **Leave it:** every addition is currently a one-line constant edit, which is cheap
  *if* you're the only user; a plugin surface is real design + maintenance weight
  for a tool that may stay personal.
- **Call: don't build the framework yet, but treat the tables as a known accuracy
  ceiling** — and if you ever push this at the monolith for real, `delegate`/`enum`/
  callbacks are the first things to add (as constants, not a framework).

**Update (`0822889`, `fab9318`) — extension point added, PARTIALLY.** There is now
a [plugin system](../docs/plugins.md): a plugin can teach Thanatos a gem macro's
meaning and attach a precise reason. Two caveats keep this "partial". First,
plugins are **reasons-only** — they *downgrade* a callback-reached method with a
better reason, but they do **not** define methods, so the other half of this
weakness (a method that exists only via `delegate` looks *undefined*) is still
unaddressed by design (defining methods would let a plugin manufacture false
negatives). Second, no plugins ship and there's no `Gemfile.lock` auto-loading
yet — the hardcoded idiom tables in `IndexBuilder` are untouched. So the accuracy
*ceiling* is unchanged; what's new is a safe, per-codebase way to explain the
framework-reached hedges.

### 2.4 Performance: the redundant work is re-parsing and per-class graph rebuilds (measured)

A `vernier` profile of a run over a Rails monolith's `app/` directory locates the
cost — and it is *not* the tree-traversals the earlier "O(classes × hierarchy)"
wording implied. Two redundancies dominate.

**(a) Cross-run: every invocation re-reads the world.** Parsing is ~39% of
wall-clock, the first AST walk (`IndexBuilder`) ~15%, and the second
(`LocalVariables`) ~7–8% — so about 60% of a run is reading and walking files,
almost all of which are unchanged between runs. Nothing is cached, so a pre-commit
hook or CI step pays the full cost every time.

- **Refactor** (persist the `Index` / per-file fact blobs keyed by digest or mtime;
  reparse only changed files): attacks the single biggest cost for the repeated-run
  case the tool will actually live in.
- **Leave it:** a one-off scan of a small tree doesn't care, and a cache adds an
  on-disk format plus invalidation logic to get wrong.
- **Call: the top performance lever *if* this becomes a CI/pre-commit step;**
  irrelevant for one-shot runs. Decide by how it is actually invoked.

**(b) Per-class: the reachability graph is rebuilt from scratch for every class.**
`candidates` iterates every `ClassFacts` and, per class, rebuilds the hierarchy,
re-unions `symbol_literals`/`dynamic_markers`/`explicit_calls`, and re-runs
`reachable_methods` per dimension — so classes in one hierarchy redo nearly
identical work. The analysis pass is ~⅓ of wall-clock, and about half of *that* is
`Set#add`/`merge`/`include?` + `Array#include?`/`uniq` + object allocation: the
merged adjacency map and the union/reached sets, rebuilt for each
`(facts, dimension)`. GC is ~9% of the run, fed by that churn. **Correcting my
earlier emphasis:** the cost is graph *construction*, not graph *traversal* —
`Index#transitive`/`ancestors` are only ~1–2%, so the "redundant tree-walk" angle
(and the `transitive` double-call) is a near-non-issue.

- **Refactor** (build the merged graph once per connected hierarchy-component and
  share it, or memoise on the exact contribution fingerprint): removes the rebuild
  churn and a chunk of the GC pressure.
- **Leave it:** it completes fine on a monolith today, and the "obvious" per-
  component share is *not* behaviour-preserving — contributions are per-class
  (self + ancestors + descendants), not the whole component — so a correct version
  needs care.
- **Call: real, and measured as the #2 cost — but behind (a),** and only with the
  golden corpus (2.7) in place, because it touches the hottest path.

The profile shows cost and *location*, not recompute *multiplicity*. Proving how
much is safely shareable needs the call-level tracer — it has to tell identical
contribution scopes (safe to memoise) from merely-overlapping ones.

### 2.5 Silent constant-resolution failure — no observability into incompleteness

`Index#resolve` falls back to the bare written name when a constant isn't in the
index, and `transitive` then silently `filter_map`s away names it can't find. So an
`include SomeVendoredThing` or a misresolved namespace just… contributes nothing,
with no signal. For a tool whose headline promise is *zero false negatives*, the
dangerous part is that **you can't tell how much of the graph it failed to
resolve** — incompleteness is invisible.

- **Refactor** (track unresolved references and surface a count / list, like
  `parse_errors`): turns "silently analysed 60% of the ancestry" into a reportable
  number; strengthens the zero-FN claim by making its gaps legible.
- **Leave it:** adds reporting plumbing and noise for references that are *expected*
  to be unresolved (every gem).
- **Call: worth a lightweight version** — at minimum a `--verbose` count of
  unresolved superclass/include/extend refs, because "the tool was confident but
  blind" is the worst failure mode for this product.

### 2.6 The confidence layer is honest but blunt (deliberately kept — fair)

The downgrade model is the honest choice and worth keeping. But as a critique of the
*implementation*: the signals are coarse. `markers.any?` is name-agnostic (one
`send` in scope taints every private in the hierarchy); the symbol-literal check is
hierarchy-wide (a `:foo` anywhere spares `foo`, callback or not); the `extend`
asymmetry is an inconsistency; and confidence is derived from `reasons.empty?`,
which couples the *decision* to the *human-readable explanation strings*.

- **Refactor** (compute structured signals, render strings separately; decide
  per-signal whether it taints by name or wholesale): lets you tighten individual
  signals (e.g. make `markers` name-aware where the dispatch target is partially
  known) without rewriting the verdict, and removes the strings-as-logic smell.
- **Leave it:** the current model is small, its semantics are endorsed, and "blunt
  but predictable" has real value.
- **Call: only the strings-as-decision coupling is worth fixing** (separate the
  signal from its sentence); the bluntness is a deliberate, defensible trade.

**Update (`fab9318`) — partially addressed.** `symbol_literals`, `dynamic_markers`,
and `call_sites` are now one [`ReferenceSignals`](../lib/thanatos/reference_signals.rb)
that owns both the signals *and* how they render as reasons — so the "compute
structured signals, render strings separately" split has landed, and `Reachability`
no longer assembles reason strings inline. `plugin_reasons` (a plugin's rendered
conclusion) and `explicit_calls` (a definite call gated on `:protected`) were
deliberately kept **out** of the model — a signal is not a conclusion, and folding
them back would re-mix the two (the signal-vs-conclusion boundary). What is **not**
fixed: confidence is still literally `reasons.empty? ? :high : :low`, so the
*verdict* remains coupled to the presence of explanation strings, and the signals
are still coarse (`markers.any?` name-agnostic, symbol-literal hierarchy-wide). The
model now makes tightening those a local change, but the tightening itself is
future work.

### 2.7 No regression corpus — refactors lean on a manual diff

The suite is excellent at *documenting behaviour on snippets* (`candidates_for`
heredocs), but almost nothing exercises representative Rails code. In practice the
real-input safety net has been a **manual byte-for-byte diff of the tool's output
over a Rails monolith's `app/`** before and after a change — used to land both the
`class << self` fix and the 2.1 refactor. It works, but it's ad hoc and depends on
a checkout that isn't in the repo.

- **Golden fixture corpus** (freeze a small app + expected output): would automate
  that diff. **Declined by the maintainer** — golden files are brittle and noisy,
  the snippet suite already pins the semantics, and the manual monolith diff covers
  the real-input case well enough for a single-maintainer tool.
- **Call: keep the manual `app/` diff as the real-input check.** Reconsider only if
  a second maintainer or a behaviour-regression-in-the-wild makes the ad-hoc step
  too easy to skip.

### 2.8 Minor smells (flagging, not recommending)

- **`Candidate` is overloaded:** for methods, `fqn` is a class; for locals
  (`LocalVariables`), `fqn` is a method/block label and `visibility` is `:local`.
  The CLI then groups locals' "fqns" alongside class fqns. One `Data` shape doing
  two jobs. Low stakes; splitting them is probably not worth the duplication.
- **Two full AST walks** (`IndexBuilder` then `LocalVariables` over the same tree):
  the parse is shared but the *walk* is duplicated — the second pass is ~7–8% of
  wall-clock on the monolith (see 2.4a). Clean SRP; I'd keep the separation unless a
  perf pass needs it.
- **Parse-error files still contribute partial facts** — a syntax error yields a
  best-effort AST and its (possibly spurious) candidates aren't quarantined. Rare;
  document rather than fix.

---

## 3. The changes I'd make next

With **2.1 done** (the `Scope`-frame refactor, `8484304`) and the **golden corpus
declined** (2.7), the forward priorities are:

1. **Surface unresolved-reference counts (2.5)** — makes the zero-FN promise honest
   about its own blind spots; the cheapest high-value win.
2. **Model the common method-defining idioms (2.3)** — `delegate`/`enum`/callbacks;
   the biggest lever on real-world precision, and the main source of the monolith's
   noise.
3. **Decouple confidence from its explanation strings (2.6)** — small, and unblocks
   tightening individual signals (e.g. the blunt `markers` check) later.

Deferred: the dimension `MethodTable` (2.2), and the performance work (2.4) — now
measured, so if this graduates to a pre-commit/CI step, **incremental parsing
(2.4a) is the biggest single lever** (~60% of wall-clock is re-reading unchanged
files), with the per-class graph rebuild (2.4b) a secondary win; for one-off scans,
neither matters.

**Honest summary:** the *algorithmic* core is in good shape and the assumptions are
mostly the right ones. With traversal fragility (2.1) now resolved and the
real-input check a deliberate manual diff rather than a gap, the remaining debt is
concentrated in **an accuracy ceiling from hardcoded idioms (2.3)** and **thin
observability into what the tool couldn't resolve (2.5)** — 2.5 is what I'd do
first. On performance, the profile relocates the cost from the tree-traversals the
design suggests to **re-parsing unchanged files and per-class graph
reconstruction** — worth attacking only once this is a repeated CI/pre-commit run.
