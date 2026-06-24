# What is NOT Decidable — Reductions

> Companion to [decidable-cases.md](decidable-cases.md). The cases here are
> **not** statically solvable in general: each reduces from the halting problem.
> They share one engine, the *Computed-Token Lemma*, of which
> [concern-undecidability.md](concern-undecidability.md) is a worked instance.
> Model and notation: see [README.md](README.md).

The cause is always the same: Ruby decides a name, constant, condition, or block
**at runtime**, by executing arbitrary code. Whenever the answer to a dead-code
question depends on such a runtime token, the question inherits the
undecidability of the code that produces it.

---

## 1. The Computed-Token Lemma

> **Lemma.** There is a computable map sending each Turing machine $Q$ to a Ruby
> thunk $f_Q$ such that
> $$f_Q() \;=\; v \ \text{ if } Q \text{ halts}, \qquad f_Q() \text{ diverges otherwise,}$$
> for any chosen token value $v$ (a Symbol, String, constant name, or Boolean).
> Consequently, **any analysis whose output depends on the value $f_Q()$ produces
> is undecidable.**

**Proof.** Ruby is Turing-complete, so a faithful simulator `run_Q` of $Q$ on
empty input exists and is computable from $\langle Q\rangle$. Take
$f_Q \equiv \lambda().\,(\texttt{run\_Q();}\ v)$. If $Q$ halts, `run_Q` returns
and $f_Q()=v$; otherwise `run_Q` diverges and $f_Q()$ never returns. An algorithm
deciding a property $\Phi$ that differs between "$f_Q()=v$" and "$f_Q()$ never
yields $v$" would decide HALT. $\;\blacksquare$

Each section below instantiates the token at a different language position. In
every case there is a decidable **literal** fragment (substitute a constant for
$f_Q()$); the undecidability is exactly the gap between literal and computed.

---

## 2. Open-world liveness (a second, independent obstruction)

Before the computed-token reductions, one case fails for a different reason.

> **Proposition (open world).** For a public method $m$ of a *library* $P$,
> $\mathrm{Live}(P,m)$ is not a function of $P$ at all.

**Proof.** A client program $P'$ not present in $\ulcorner P\urcorner$ may call
$m$. Whether $m$ is "used" depends on the unknown set of clients, which is not
part of the input. Under a closed-world assumption (whole app, no external
callers) this collapses to §3; without it, the question is ill-posed for a tool
that sees only $P$. $\;\blacksquare$

This is why public-method liveness (#2) needs a *runtime/coverage* tier:
observation supplies the client behaviour that source cannot.

---

## 3. Computed dispatch — public methods (#2), `send`/`method` (#8, #19)

> **Theorem 1.** Deciding whether method $m$ is ever invoked is undecidable.

**Proof.** Instantiate the Lemma with token $v=\texttt{:m}$ at a `send` position:

```ruby
class Host
  def run
    send(callback())      # callback() == :m  iff  Q halts
  end
  def m; end              # no literal reference to `m` anywhere else
end
```

with `callback ≡ f_Q` returning `:m`. Then `Host#m` is invoked iff $Q$ halts, so
$\mathrm{Live}$ of $m$ decides HALT. $\;\blacksquare$

Because `:m` never appears literally, a syntactic analyser sees a defined method
with no caller and would call it dead — **unsound** exactly when $Q$ halts. This
is the dangerous direction (false "dead" on live code). It subsumes #8/#19: a
literal `send(:m)` is decidable (decidable-cases §2); a computed one is Theorem 1.

---

## 4. Computed constants — class/module liveness (#3), `Class.new` super (#5), mixins (#4)

> **Theorem 2.** Deciding whether constant (class/module) $K$ is referenced is
> undecidable.

**Proof.** Instantiate the Lemma with token $v=\texttt{"K"}$ at a `constantize`
position:

```ruby
Object.const_get(name())   # name() == "K"  iff  Q halts
```

with `name ≡ f_Q`. $K$ is reachable iff $Q$ halts. $\;\blacksquare$

Three Rails mechanisms are direct corollaries — each supplies the computed
constant name from a non-source channel:

- **`constantize` from data** — `record.type.constantize` (STI) reads a class
  name from a *database row*. The reference set depends on runtime data, not
  source.
- **Zeitwerk autoload** — a constant is loaded when its *name* is first
  referenced; the name can be built as a string (`"#{prefix}Service".constantize`).
- **Computed superclass (#5)** — `Class.new(parent())` makes the inheritance edge
  depend on `parent()`; which class is the parent (hence which inherited methods
  are reachable) is undecidable. Literal `Class.new(Base)` is decidable.

**Mixins (#4)** are the same theorem with the token at an `include` position;
the fully worked treatment, including `ActiveSupport::Concern`'s `included`/
`class_methods`/dependency machinery, is
[concern-undecidability.md](concern-undecidability.md). Literal `include Const`
is decidable (decidable-cases §1).

---

## 5. Computed definition — `define_method`, `attr_*(*computed)`, `class_eval` (#6, #14, #12, #13, #15)

> **Theorem 3.** The defined set $\mathcal{D}(P)$ is uncomputable.

**Proof.** Instantiate the Lemma with token $v=\texttt{:phantom}$ at a definition
position:

```ruby
define_method(name()) { }     # name() == :phantom  iff  Q halts
```

with `name ≡ f_Q`. Then $\texttt{:phantom}\in\mathcal{D}(P)$ iff $Q$ halts.
$\;\blacksquare$

This is the general statement of Theorem A in the concern document. Corollaries:

- **`attr_reader(*fields)` (#14)** with `fields` computed at boot — the generated
  accessor names are runtime values; literal `attr_reader :a` is decidable.
- **`klass.class_eval(&block)` with a computed receiver/block (#12, #13, #15)** —
  the definee, hence the attribution and visibility of methods defined inside, is
  a runtime value; literal `Struct.new do…end` is decidable
  (decidable-cases §3.3).

Because the tool's *output domain* is $\mathcal{D}(P)$, an uncomputable
$\mathcal{D}(P)$ means it cannot even enumerate its candidates — the deepest form
of the limitation.

---

## 6. Computed conditions — conditional visibility (#17)

> **Theorem 4.** Deciding the visibility of a method guarded by a runtime
> condition is undecidable.

**Proof.** Instantiate the Lemma with a Boolean token at an `if` position:

```ruby
class Foo
  private if guard()      # guard() == true  iff  Q halts
  def m; end
end
```

with `guard ≡ f_Q` returning `true`. Then `Foo#m` is private iff $Q$ halts. Since
the dead-code analysis is conditioned on visibility (only private/protected are
in scope, and visibility fixes the legal call surface), $m$'s classification
depends on $Q$ halting. $\;\blacksquare$

Literal conditions (`private if true`) are decidable by constant folding; the
undecidability is intrinsic to runtime guards.

---

## 7. What this licenses the tool to do

Undecidability of the general case forbids a **sound and complete** analyser; it
does not forbid a **sound, incomplete** one. The disciplined response, uniform
across §§3–6:

- **Resolve the literal fragment** (decidable-cases) precisely.
- **Detect the computed token** — an unresolved `send`/`const_get`/`define_method`/
  guarded modifier/dynamic `include` — and **over-approximate**: treat the
  affected methods as *possibly live* (report at low confidence with a reason, or
  not at all), never as confidently dead.

In model terms, the tool computes a sound under-approximation
$\hat S \subseteq \mathrm{Dead}(P)$ on the literal fragment and **abstains** on
the computed fragment. It never claims the undecidable. For the genuinely
runtime-shaped questions — public-method and class liveness (§§2–4) — the honest
answer is a different instrument entirely: a runtime/coverage tier that
*observes* the behaviour source cannot reveal.

---

## References

This is **computability theory** (recursion theory): the Computed-Token Lemma is
a halting-problem reduction, and §7's response is **abstract interpretation**.
See [README.md](README.md) for the branch-of-mathematics overview and full
bibliography.

- Turing, A. M. (1936). *On Computable Numbers…* Proc. London Math. Society. —
  the halting problem the Lemma reduces from.
- Rice, H. G. (1953). *Classes of Recursively Enumerable Sets and Their Decision
  Problems.* Trans. AMS. — Theorems 1–4 are all instances; Rice gives the
  one-line "non-trivial semantic property ⇒ undecidable."
- Davis, M. (1958). *Computability and Unsolvability*; Rogers, H. (1967).
  *Theory of Recursive Functions…* — many-one reductions in full rigour, if you
  want the Lemma stated at the level of $\le_m$.
- Sipser, M.; Hopcroft, Motwani & Ullman. — textbook treatments of reducibility
  and the halting problem.
- Landi, W. (1992). *Undecidability of Static Analysis.* ACM LOPLAS; Ramalingam,
  G. (1994). *The Undecidability of Aliasing.* ACM TOPLAS; Reps, T. (2000).
  *Undecidability of context-sensitive data-dependence analysis.* ACM TOPLAS. —
  the canonical "static analysis X is undecidable" results; §§3–5 are the
  dead-code analogues.
- Cousot, P. & Cousot, R. (1977). *Abstract interpretation…* POPL; Rival, X. &
  Yi, K. (2020). *Introduction to Static Analysis: An Abstract Interpretation
  Perspective.* MIT Press. — the theory of the sound under-approximation
  $\hat S \subseteq \mathrm{Dead}(P)$ that §7 prescribes.
- Møller, A. & Schwartzbach, M. *Static Program Analysis* (Aarhus lecture notes,
  free online). — gentle, rigorous bridge from "it's undecidable" to "so here is
  what we soundly compute instead."
