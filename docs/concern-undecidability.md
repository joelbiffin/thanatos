# Why `ActiveSupport::Concern` Defeats Static Dead-Code Analysis

> A note on a fundamental limit. The claim is **not** "concerns are hard to
> parse." It is that the two objects a dead-code analyser must compute — the set
> of defined methods and the call graph over them — are **uncomputable from the
> source text** once `ActiveSupport::Concern` is in play, because inclusion runs
> arbitrary code. We make this precise and prove it by reduction from the halting
> problem.
>
> (Terminology: the module is `ActiveSupport::Concern`. Concerns are commonly
> mixed into `ActiveRecord` models, which is likely the source of the name
> `ActiveRecord::Concern`; no such constant exists.)

---

## 1. Setup

Fix a Turing-complete language $L$ (Ruby). Loading a program $P \in L$ may
execute arbitrary code: class bodies run, `include` is a method call, and hooks
fire.

Let $\mathcal{M}$ be the universe of qualified method identifiers. For a program
$P$ define:

- **Defined set** $\mathcal{D}(P) \subseteq \mathcal{M}$ — the methods that exist
  in some reachable state of $P$ (defined during load or execution).
- **Call graph** $G(P) = (\mathcal{D}(P), E)$, where $(u,v) \in E$ iff invoking
  $u$ may invoke $v$ in some execution.
- **Roots** $R(P) \subseteq \mathcal{D}(P)$ — externally reachable entry points
  (public API, framework callbacks, jobs, …).
- **Live / dead:**

$$\mathrm{Live}(P) = \mathrm{Reach}_{G(P)}\big(R(P)\big), \qquad \mathrm{Dead}(P) = \mathcal{D}(P) \setminus \mathrm{Live}(P).$$

A **static dead-code analyser** is a *total computable* function

$$\mathcal{A} : \ulcorner P \urcorner \longmapsto S \subseteq \mathcal{M}$$

taking only the source text $\ulcorner P \urcorner$. We want $\mathcal{A}$ to be
**sound** ($S \subseteq \mathrm{Dead}(P)$ — never call a live method dead) and
**complete** ($S \supseteq \mathrm{Dead}(P)$ — find all dead methods).

The results below show that for $P$ using `ActiveSupport::Concern`, neither
$\mathcal{D}(P)$ nor $G(P)$ is computable from $\ulcorner P \urcorner$, so no
$\mathcal{A}$ can be both sound and complete.

---

## 2. Lemma (inclusion executes arbitrary code)

`ActiveSupport::Concern` overrides the inclusion mechanism. In essence:

```ruby
module ActiveSupport::Concern
  def included(base = nil, &block)
    @_included_block = block      # stash the block...
  end

  def append_features(base)       # ...Ruby calls this on `include`
    super
    base.class_eval(&@_included_block) if @_included_block   # run it, self = base
  end
end
```

Consequently, for a concern `C` and class `H`:

1. **`included do … end`** runs its block via `base.class_eval`, with
   `self == H` (the *class*), at include time. The block is arbitrary code.
2. **`class_methods do … end`** synthesises a `ClassMethods` module and
   `extend`s the includer with it, so methods land on `H`'s singleton.
3. **Dependency replay** — a concern that includes other concerns defers and
   replays their inclusion, so the *order and set* of hooks that fire is computed
   at runtime.

The operative fact for everything below: **`include C` evaluates arbitrary Ruby
whose effect on `H`'s methods and wiring is a runtime output, not a syntactic
property of $\ulcorner P \urcorner$.** $\quad\blacksquare$

---

## 3. Theorem A — the defined set is uncomputable

> **Theorem A.** The map $P \mapsto \mathcal{D}(P)$ is not computable. Indeed,
> membership "$m \in \mathcal{D}(P)$?" is undecidable for programs $P$ that use
> `ActiveSupport::Concern`.

**Proof (reduction from HALT).** Ruby is Turing-complete, so for any Turing
machine $Q$ there is a method `run_Q` that terminates iff $Q$ halts on empty
input. Given $\langle Q \rangle$, construct $P_Q$:

```ruby
module Gadget
  extend ActiveSupport::Concern

  included do
    run_Q()                       # terminates  <=>  Q halts
    define_method(:phantom) { }   # reached only if run_Q returns
  end
end

class Host
  include Gadget                  # runs the included block now
end
```

By the Lemma, `include Gadget` executes the block on `Host`. The
`define_method(:phantom)` line is reached iff `run_Q()` returns. Hence

$$\texttt{:phantom} \in \mathcal{D}(P_Q) \iff Q \text{ halts}.$$

If some algorithm decided membership in $\mathcal{D}(P)$ from source text, it
would decide HALT. No such algorithm exists. $\quad\blacksquare$

**Why this is fatal for a dead-code tool specifically:** the tool's *output
domain* is $\mathcal{D}(P)$ — it can only classify methods it can enumerate. If
$\mathcal{D}(P)$ is uncomputable, the tool cannot even produce the list of
candidates it is meant to triage.

---

## 4. Theorem B — the call graph is uncomputable, and unsoundness is forced

Theorem A produces a *false negative* (a method the tool can't see), which is the
safe direction. The dangerous direction — a *false positive*, calling live code
dead — is also forced, and with **no syntactic trace** for the tool to catch.

> **Theorem B.** There is a family $P_Q$ using `ActiveSupport::Concern` and a
> method `m` such that (i) `m` is live in $P_Q$ iff $Q$ halts, and (ii)
> $\ulcorner P_Q \urcorner$ contains **no syntactic reference** to `m` other than
> its definition. Deciding `m`'s deadness therefore decides HALT.

**Proof (reduction from HALT).** Construct $P_Q$:

```ruby
module Callbacker
  extend ActiveSupport::Concern

  included do
    before_save callback_name()   # callback_name returns :persist or not,
  end                             #   via run_Q-style arbitrary computation

  def persist; end                # defined; ZERO literal references elsewhere
end

class Host < ApplicationRecord
  include Callbacker
end
```

`callback_name()` performs arbitrary computation (e.g. `run_Q(); :persist`) and
returns the symbol `:persist` exactly when $Q$ halts. The framework then invokes
`Host#persist` on every save. Thus

$$\texttt{persist} \in \mathrm{Live}(P_Q) \iff Q \text{ halts}.$$

Crucially, the symbol `:persist` is **produced at runtime**, so it never appears
literally in the source: there is no `:persist` token, no `persist` call site for
a syntactic analyser to find. An analyser that marks "no visible caller" as dead
will report `persist` dead — *unsound* exactly when $Q$ halts. An analyser that
refuses to ever conclude this is *incomplete*. Deciding correctly decides HALT.
$\quad\blacksquare$

This is the practically alarming result: ordinary concern callback wiring, once
the symbol is computed, makes confident deletion advice provably impossible.

---

## 5. Corollary — exact dead-method detection is undecidable

> **Corollary (Rice).** "$m \in \mathrm{Dead}(P)$" is a non-trivial *semantic*
> property of the program $P$ computes, hence undecidable.

It is non-trivial (some programs have dead methods, some do not) and extensional
(it depends on $P$'s behaviour, not its syntax — Theorems A and B exhibit
behaviour-dependence directly). Rice's theorem gives undecidability immediately;
the reductions above make the dependence concrete. $\quad\blacksquare$

---

## 6. This is not a pathological corner

The proofs use halting gadgets for rigour, but **no adversary is required** — the
same uncomputability arises in ordinary, well-intentioned concerns:

```ruby
module Searchable
  extend ActiveSupport::Concern

  included do
    SEARCH_FIELDS.each do |field|              # loaded from config / schema / DB
      define_method("by_#{field}") { |v| where(field => v) }
    end
  end
end
```

The set $\{\texttt{by\_name}, \texttt{by\_email}, \dots\}$ defined on the
includer is a function of `SEARCH_FIELDS`, whose value is known only at boot.
The method *names* are string-built at runtime, so they are not in
$\ulcorner P \urcorner$ at all. $\mathcal{D}(P)$ depends on runtime data —
Theorem A's conclusion, reached by everyday metaprogramming rather than by a
constructed halting reduction.

---

## 7. The honest boundary — what a tool *can* still do

Undecidability of the *general* case does not forbid a *useful* tool; it forbids
a *complete and sound* one. The standard escape is to be **sound but incomplete**
on the dynamic part:

- **Lexical skeleton is decidable.** A literal `include LiteralConst` with the
  concern's methods written as plain `def`s, and call sites written literally, is
  a syntactic fact and can be resolved precisely. Most hand-written concerns have
  such a skeleton.
- **Over-approximate the rest.** When a concern's wiring is not statically
  resolvable — a computed `define_method`, a callback whose symbol is computed,
  an `included` block calling code we cannot evaluate — treat the affected
  methods as **possibly reached** (low confidence, with a stated reason) rather
  than asserting deadness. This preserves soundness (no false "dead") at the cost
  of completeness (we stay silent where we cannot prove deletion safe).

In the language of §1: a practical analyser computes a sound under-approximation
$\hat{S} \subseteq \mathrm{Dead}(P)$ over the lexical fragment, and explicitly
abstains elsewhere. It never claims the undecidable.

### Bottom line

`ActiveSupport::Concern` turns method definition and call wiring into outputs of
code that runs at include time. By Theorems A and B those outputs are
uncomputable from source, and exact dead-method detection over them is
undecidable — a limit shared by **every** purely static analyser (Sorbet,
`debride`, this tool), not an artefact of one design. The correct response is not
to attempt the impossible but to resolve the decidable lexical fragment and
abstain, audibly, on the rest.

---

## References

This is **computability theory** (recursion theory). The reductions here are the
halting problem and Rice's theorem applied to a program-analysis question; see
[README.md](README.md) for the branch-of-mathematics overview and full
bibliography.

- Turing, A. M. (1936). *On Computable Numbers, with an Application to the
  Entscheidungsproblem.* Proc. London Math. Society. — the halting argument
  behind Theorems A and B.
- Rice, H. G. (1953). *Classes of Recursively Enumerable Sets and Their Decision
  Problems.* Trans. AMS. — §5's corollary verbatim: deadness is a non-trivial
  semantic property, hence undecidable.
- Sipser, M. *Introduction to the Theory of Computation.* — accessible coverage
  of reductions and Rice if the proofs above feel terse.
- Landi, W. (1992). *Undecidability of Static Analysis.* ACM LOPLAS; Ramalingam,
  G. (1994). *The Undecidability of Aliasing.* ACM TOPLAS. — the same phenomenon
  for alias analysis; evidence this is a property of static analysis in general,
  not of concerns specifically.
- Cousot, P. & Cousot, R. (1977). *Abstract interpretation…* POPL. — the
  principled basis for §7's "resolve the lexical fragment, over-approximate the
  rest."
- For the Ruby-specific context, Stripe's *Sorbet* hits exactly this wall with
  `ActiveSupport::Concern` and resolves it by generating RBI for the
  metaprogrammed methods (Tapioca) rather than analysing the `included` block.
