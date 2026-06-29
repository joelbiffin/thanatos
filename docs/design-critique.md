# Thanatos — Design Critique

A formal design review of the codebase: where the dependencies and load-bearing
assumptions sit, the weak points, and for each potential change the pros and cons
of refactoring versus leaving it. The emphasis is deliberately on weaknesses, not
strengths. References are to the code as it stands on branch `VIBE_cli`
(through commit `ad20321`). Performance figures (§1, §2.4) come from a `vernier`
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

### 2.1 `IndexBuilder`'s six hand-balanced stacks — the highest-risk structure

`@scope`, `@visibility`, `@facts`, `@method`, `@singleton_context`,
`@singleton_class` must be pushed and popped in lockstep, but the balancing is
spread across `push_scope`/`leave`, `visit_def_node`, and
`visit_singleton_class_node` (which manages four of them by hand). The
`class << self` bug we fixed *was exactly this*: a scope construct that forgot a
frame. Every future construct (refinements, `instance_eval` with a block,
pattern-matching binders) is a chance to reintroduce it.

- **Refactor** (one `@scopes` stack of `Scope` structs bundling
  fqn/visibility/facts/method/dimension): makes the balance invariant *structural*
  instead of a manual discipline; the next construct pushes one object or it
  doesn't compile. Directly prevents the most likely class of future bug.
- **Leave it:** the six stacks work today and are covered by tests; a refactor
  touches the most central, most-tested file with no behavioural payoff, and risks
  introducing the very bug it's meant to prevent.
- **Call: worth doing** — correctness-of-traversal is the foundation everything
  else trusts — but only with the current suite green as a harness. It's the one
  structural refactor I'd actually prioritise.

### 2.2 `ClassFacts` doubles everything by dimension instead of owning a `MethodTable`

Instance and singleton are modelled as parallel fields and parallel methods
(`add_definition`/`add_singleton_definition`, `call_edges`/`singleton_call_edges`,
`definitions`/`singleton_definitions`, …), and that doubling leaks outward:
`Reachability` has `definitions_for`/`edges_for` switches, `IndexBuilder` threads
`@singleton_context`. The "dimension" is a real concept that exists nowhere as an
object — and the `extend`-marker asymmetry is a *symptom*: the marker union walks
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

### 2.7 No regression corpus — refactors fly blind on real input

The suite is excellent at *documenting behaviour on snippets* (`candidates_for`
heredocs), but almost nothing exercises representative Rails code, and the
dogfooding that found every real bug this session was **manual**. Nothing stops a
refactor from silently shifting the real-world output — which, for a tool whose
entire value is the accuracy of that output, is the biggest process gap.

- **Refactor** (freeze a small fixture app + golden expected-output test): every
  refactor above gets a safety net that snippet tests can't provide; the
  `class << self` and `markers` regressions would have been caught automatically.
- **Leave it:** golden-file tests are brittle and noisy to maintain, and the snippet
  suite already pins the semantics precisely.
- **Call: worth it before any of 2.1–2.6** — a golden corpus is the prerequisite
  that makes the structural refactors safe rather than scary.

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

## 3. If I could make only three changes

1. **A golden regression corpus (2.7)** — the enabler for everything else.
2. **Collapse the six stacks into one `Scope` object (2.1)** — kills the most likely
   future bug class.
3. **Surface unresolved-reference counts (2.5)** — makes the zero-FN promise honest
   about its own blind spots.

Everything else — the dimension `MethodTable`, the idiom registry — I'd **defer**.
The performance work (2.4) is now measured, not hypothetical: if this graduates to
a pre-commit/CI step, **incremental parsing (2.4a) is the biggest single lever** —
it attacks the ~60% of wall-clock spent re-reading unchanged files — with the
per-class graph rebuild (2.4b) a secondary win; for one-off scans, neither matters.

**Honest summary:** the *algorithmic* core is in good shape and the assumptions are
mostly the right ones for the problem; the debt is concentrated in **traversal
fragility, an accuracy ceiling from hardcoded idioms, and the absence of a
real-input safety net** — and the last of those is what I'd fix first. On
performance, the profile relocates the cost from the tree-traversals the design
suggests to **re-parsing unchanged files and per-class graph reconstruction** —
worth attacking only once this is a repeated CI/pre-commit run.
