# Decidability of Static Dead-Code Analysis — Proof Index

This directory works through every documented limitation of the tool and asks a
single question of each: **can a purely static, single-run CLI decide it?** The
answer for almost every case is the same shape:

> The **literal / lexical** fragment of the construct is decidable (often
> trivially). The **computed** fragment — where a name, constant, condition, or
> block is produced at runtime — is undecidable, by reduction from the halting
> problem.

So the engineering conclusion falls out of the maths: *implement the lexical
fragment; abstain, audibly, on the computed tail.*

## The documents

1. **[decidable-cases.md](decidable-cases.md)** — constructive proofs that a case
   IS statically solvable (an algorithm exists). These limitations are
   implementation gaps, not theoretical walls.
2. **[undecidable-cases.md](undecidable-cases.md)** — reductions from HALT proving
   a case is NOT solvable in general, via one master *Computed-Token Lemma*.
3. **[concern-undecidability.md](concern-undecidability.md)** — the worked
   instance: why `ActiveSupport::Concern` defeats analysis. A specialisation of
   the lemma in (2).

## Shared formal model (used by all three)

Fix a Turing-complete language $L$ (Ruby). For a program $P \in L$:

- $\mathcal{D}(P) \subseteq \mathcal{M}$ — the methods/constants **defined** in
  some reachable state of $P$.
- $G(P) = (\mathcal{D}(P), E)$ — the **call graph**; $(u,v)\in E$ iff invoking
  $u$ may invoke $v$.
- $R(P) \subseteq \mathcal{D}(P)$ — **roots** (externally reachable entry points).
- $\mathrm{Dead}(P) = \mathcal{D}(P) \setminus \mathrm{Reach}_{G(P)}(R(P))$.

A **static analyser** is a *total computable* $\mathcal{A}:\ulcorner P\urcorner \mapsto S\subseteq\mathcal{M}$,
wanted **sound** ($S\subseteq\mathrm{Dead}(P)$) and **complete** ($S\supseteq\mathrm{Dead}(P)$).

## Classification of all documented limitations

`L` = literal/lexical fragment, `C` = computed fragment. Spec names are the
`test_*` methods in `test/supported_behaviour_test.rb` (the decidable rows,
now passing) and `test/out_of_scope_test.rb` (the two undecidable rows).

| # | Case | Verdict | Proof |
|---|------|---------|-------|
| 1 | local variables | **Decidable** (eval-free) | decidable §3.1 (Thm L) |
| 7 | `private_class_method` / `def self.x` | **Decidable** | decidable §3.2 (Thm CM) |
| 9 | mutually-recursive dead methods | **Decidable** | decidable §4 (Thm R) |
| 10 | self-recursive dead method | **Decidable** | decidable §4 (Thm R) |
| 11 | transitively-dead method | **Decidable** | decidable §4 (Thm R) |
| 16 | absolute `::Foo` scoping | **Decidable** (trivial) | decidable §2 |
| 18 | de-duplicate candidates | **Decidable** (trivial) | decidable §2 |
| 20 | `&:sym` block-pass precision | **Decidable** (trivial) | decidable §2 |
| 21 | surface parse errors | **Decidable** (given) | decidable §2 |
| 8 | `send(:literal)` | **Decidable** (L) / undecidable (C) | decidable §2 / undecidable §3 |
| 19 | `method(:literal)` | **Decidable** (L) / undecidable (C) | decidable §2 / undecidable §3 |
| 14 | `attr_reader`/etc. | **Decidable** (L) / undecidable (C) | decidable §2 / undecidable §5 |
| 6 | `define_method` | **Decidable** (L) / undecidable (C) | decidable §2 / undecidable §5 |
| 12 | visibility leak from blocks | **Decidable** (L) / undecidable (C) | decidable §3.3 / undecidable §5 |
| 13 | method misattribution in blocks | **Decidable** (L) / undecidable (C) | decidable §3.3 / undecidable §5 |
| 15 | methods in anonymous classes | **Decidable** (L) / undecidable (C) | decidable §3.3 / undecidable §5 |
| 4 | `include`/`prepend` mixin | **Decidable** (L) / undecidable (C) | concern doc / undecidable §4 |
| 5 | computed `Class.new` superclass | **Undecidable** (L-case trivial) | undecidable §4 |
| 17 | conditional visibility | **Undecidable** | undecidable §6 |
| 3 | class / module liveness | **Undecidable** | undecidable §4 |
| 2 | public-method liveness | **Undecidable** (also open-world) | undecidable §3 |

**Reading the duality:** the cases with both an `L` and a `C` entry are the
interesting ones. The reductions doc does not contradict the constructive doc —
they prove different *fragments* of the same construct. Resolving the `L` fragment
and abstaining on the `C` fragment is exactly the sound-but-incomplete strategy.

> **Status.** These notes prove what is *possible*, independent of what is
> *built* — but the gap is now closed. Every row above is implemented on its
> decidable fragment and covered by a passing spec, including the literal
> sub-cases of #5 and #17 whose general form stays Undecidable. The only specs
> still skipped are #2 (public-method liveness) and #3 (class/module liveness):
> both need a runtime / coverage tier rather than more static analysis.

---

## The branch of mathematics

The core is **computability theory** (a.k.a. **recursion theory**) — a branch of
**mathematical logic** and **theoretical computer science**. Undecidability, the
halting problem, reductions, and Rice's theorem are its staples; they govern the
undecidable-cases and concern documents. Two adjacent areas appear:

| Side of the argument | Branch | Key tools | Where |
|---|---|---|---|
| "This *cannot* be decided" | Computability theory | halting problem, many-one reductions, Rice's theorem | undecidable, concern |
| "This *can* be decided efficiently" | Graph theory + complexity theory | graph reachability, least fixed points, $O(V+E)$ | decidable (Thm R) |
| "What to do despite undecidability" | Abstract interpretation, built on order/lattice theory | Galois connections, Tarski fixed points, sound over-approximation | undecidable §7 |

The applied umbrella is **static program analysis** (equivalently, the theory of
sound approximation of program behaviour without execution). If you read one
thing to place this work: a static-analysis text that opens with "all
non-trivial semantic properties are undecidable (Rice), so we approximate
soundly (abstract interpretation)" — that sentence is the entire arc of these
documents.

## Computability resources

Free, well-regarded courses and texts for the mathematics behind these proofs —
computability theory and its bridge to program analysis.

- **MIT 18.404J *Theory of Computation* — Prof. Michael Sipser (Fall 2020), on
  MIT OpenCourseWare (`ocw.mit.edu`).** Full video lectures by the author of the
  standard textbook. Its decidability block — the halting problem, mapping
  reducibility, and Rice's theorem — is exactly the machinery the undecidable and
  concern documents use. The single best match; start with the lectures from
  "Decidability" through "Reducibility."
- **Boaz Barak, *Introduction to Theoretical Computer Science* (Harvard CS121) —
  free online at `introtcs.org`.** A modern, free textbook with exercises that
  frames Turing machines and undecidability for a CS audience. The best
  self-paced companion to the videos.
- **NPTEL *Theory of Computation* (the IITs) — free on YouTube / `nptel.ac.in`.**
  Many paced hours of video and worked examples, if you prefer that format.
- **Møller & Schwartzbach, *Static Program Analysis* (Aarhus, free online).** The
  continuation into program analysis, where "everything interesting is
  undecidable (Rice), so approximate soundly (abstract interpretation)" becomes
  the actual engineering — the §7 strategy of the undecidable doc.

**Suggested path:** Sipser's decidability/reducibility lectures (*why it is
impossible*) → Møller & Schwartzbach (*what we compute instead*). That sequence
is the whole arc of these documents, in two free courses.

## Further reading (master bibliography)

Each proof document repeats the subset most relevant to it; this is the union.

**Foundations — computability & logic**
- Turing, A. M. (1936). *On Computable Numbers, with an Application to the
  Entscheidungsproblem.* Proc. London Mathematical Society. — undecidability of
  the *Entscheidungsproblem*; the halting argument every reduction here uses.
- Rice, H. G. (1953). *Classes of Recursively Enumerable Sets and Their Decision
  Problems.* Transactions of the AMS. — every non-trivial semantic property is
  undecidable; our Corollary in each doc.
- Sipser, M. *Introduction to the Theory of Computation.* — the accessible
  textbook entry point: Turing machines, decidability, reducibility, Rice.
- Hopcroft, Motwani & Ullman. *Introduction to Automata Theory, Languages, and
  Computation.* — alternative standard text.
- Davis, M. (1958). *Computability and Unsolvability*; Rogers, H. (1967).
  *Theory of Recursive Functions and Effective Computability.* — the classic
  monographs, if you want depth.

**Undecidability of static analysis specifically**
- Landi, W. (1992). *Undecidability of Static Analysis.* ACM LOPLAS. — the result
  that "may-alias" (and friends) are undecidable; the template we reuse.
- Ramalingam, G. (1994). *The Undecidability of Aliasing.* ACM TOPLAS.
- Reps, T. (2000). *Undecidability of context-sensitive data-dependence
  analysis.* ACM TOPLAS. — undecidability persists even for restricted analyses.

**Sound approximation — abstract interpretation & lattice theory**
- Tarski, A. (1955). *A lattice-theoretical fixpoint theorem and its
  applications.* Pacific J. Mathematics. — least fixed points exist; the formal
  basis of both reachability (Thm R) and abstract interpretation.
- Cousot, P. & Cousot, R. (1977). *Abstract interpretation: a unified lattice
  model for static analysis of programs…* POPL. — the foundational paper for the
  §7 "resolve-the-literal-fragment, over-approximate-the-rest" strategy.
- Nielson, Nielson & Hankin. *Principles of Program Analysis.* — the standard
  graduate text tying dataflow, control-flow, and abstract interpretation
  together.
- Rival, X. & Yi, K. (2020). *Introduction to Static Analysis: An Abstract
  Interpretation Perspective.* MIT Press. — modern, readable.
- Møller, A. & Schwartzbach, M. *Static Program Analysis.* Aarhus University
  lecture notes — freely available online; the gentlest rigorous start.

**Reachability, dataflow & call graphs (the decidable machinery)**
- Kildall, G. (1973). *A Unified Approach to Global Program Optimization.* POPL.
  — the dataflow-as-fixpoint framework.
- Aho, Lam, Sethi & Ullman. *Compilers: Principles, Techniques, and Tools* (the
  "Dragon Book"). — **live-variable analysis** is exactly our locals case
  (Thm L); the canonical treatment.
- Reps, Horwitz & Sagiv (1995). *Precise Interprocedural Dataflow Analysis via
  Graph Reachability.* POPL. — dataflow *is* reachability; the spirit of Thm R.
- Grove, D. & Chambers, C. (2001). *A Framework for Call Graph Construction
  Algorithms.* ACM TOPLAS. — building $G(P)$, the input Thm R assumes.
- Cormen, Leiserson, Rivest & Stein. *Introduction to Algorithms.* — BFS/DFS
  reachability in $O(V+E)$.

**Dynamic languages in practice (the same wall, applied)**
- The *Diamondback Ruby (DRuby)* project and Stripe's *Sorbet* type checker both
  confront precisely the metaprogramming barrier proved here, and both respond
  the abstract-interpretation way: analyse the static fragment, fall back to
  `T.untyped` / dynamic checks on the rest.
