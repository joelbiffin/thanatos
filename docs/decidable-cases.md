# What IS Decidable — Constructive Proofs

> Companion to [undecidable-cases.md](undecidable-cases.md). The cases here are
> **statically solvable**: for each we exhibit an algorithm computable from the
> source text alone. Where a case has a computed fragment that escapes (e.g.
> `send(x)` for runtime `x`), that fragment is treated in the reductions doc;
> here we prove the **literal / lexical fragment** decidable. Model and notation:
> see [README.md](README.md).

A property is **decidable** for our purposes if there is a total computable
function from $\ulcorner P \urcorner$ to the answer. "Constructive proof" = we
give that function (an algorithm) and argue it is total and correct on the stated
fragment.

---

## 1. The lexical fragment, defined

Let the **lexical fragment** $L \subseteq \mathcal{M}$-programs be those where
every definition is a syntactic `def`/`attr_*`/`define_method`/`include` with
**literal** names/constants, every call site is a syntactic send with a
**literal** selector, and visibility modifiers take literal arguments. On $L$,
the parse tree determines $\mathcal{D}(P)$, $G(P)$, and $R(P)$ exactly:

$$\mathcal{D}, G, R \ :\ \ulcorner P \urcorner \to (\text{finite data}) \quad\text{are computable on } L.$$

This is immediate — each is a finite fold over AST nodes with no semantic
evaluation. Everything in this document is a corollary of *staying inside $L$*.

---

## 2. Syntactic-by-construction cases (decidable, trivially)

Each of these is a computable function of the AST; the proof is the procedure.

- **Absolute constant paths `::Foo` (#16).** FQN is a pure function of a
  constant-path node and its lexical nesting stack $\nu$:
  $\mathrm{fqn}(n) = \mathrm{path}(n)$ if $n$ is absolute (leading `::`), else
  $\nu \mathbin{+\!+} \mathrm{path}(n)$. Total, deterministic. The current bug is
  prepending $\nu$ unconditionally; the fix is one case split. **Decidable.**

- **De-duplication (#18).** Candidates form a finite set; output the quotient by
  identity. **Decidable.**

- **Block-pass symbols `&:foo` (#20).** "`&:foo` is a self-call" is false by
  Ruby's semantics; recognising the `BlockArgument(Symbol)` node and *not*
  recording a self-reference is a syntactic predicate. **Decidable.**

- **Parse-error surfacing (#21).** Not even an analysis: the parser returns the
  error set as data; test non-emptiness. **Decidable.**

- **Literal `send`/`method`/`public_send` (#8, #19).** A literal-symbol argument
  *is* the selector. Recognise `send(:foo)` / `method(:foo)` and record a
  reference to `foo`. **Decidable on $L$.** (Computed selector → reductions §3.)

- **Literal `define_method` / `attr_*` (#6, #14).** `define_method(:foo){…}`,
  `attr_reader :a, :b` name their methods literally; add `foo`, `a`, `b` (and
  `a=`, `b=` for writers) to $\mathcal{D}(P)$ with the ambient visibility.
  **Decidable on $L$.** (Computed names / splats → reductions §5.)

---

## 3. Lexical-scope cases

### 3.1 Unused local variables (#1) — Theorem L

> **Theorem L.** On the fragment free of `eval`/`binding`, unused-local detection
> is decidable.

**Proof.** Ruby local scope is lexical: the parser resolves every local read to
the binding that introduces it (Prism exposes `locals` per scope; a read carries
its scope depth). For each scope $s$ form $W_s$ (assigned names) and $U_s$ (names
read in $s$ or any nested closure — all lexically visible). A local is unused iff
it lies in $W_s \setminus U_s$. Both sets are finite folds over the AST; the
decision is their set difference. Total and correct on the fragment. $\;\blacksquare$

**Boundary.** `eval(str)` / `binding.local_variable_get(x)` can read a local
named by a runtime value; deciding "is `x` read?" then reduces to HALT
(reductions §3). Sound handling: any scope containing `eval`/`binding`
over-approximates $U_s$ to "all locals," abstaining. Ruby's own `-w` warning is
exactly Theorem L's algorithm. **The tool not doing this is a choice, not a
wall.**

### 3.2 Class-method visibility (#7) — Theorem CM

> **Theorem CM.** Detecting unused private class methods is decidable on $L$.

**Proof.** Class methods (`def self.m`, `private_class_method :m`) are defined and
called by the same syntactic rules as instance methods, with one substitution: a
class-method call site is `self.m` / `Const.m` / a bare `m` inside another class
method, all syntactic on $L$. Run the identical reachability analysis (§4) over
the singleton-method graph. Decidability transfers verbatim from the
instance-method tier. $\;\blacksquare$

This is purely an *unmodelled dimension*, not a hard one.

### 3.3 Definee scope of class-defining blocks (#12, #13, #15) — Theorem B

> **Theorem B.** For a class-defining block with a **literal** receiver —
> `Struct.new do…end`, `Class.new do…end`, `Foo.class_eval do…end`,
> `K = Class.new do…end` — the methods defined in the block and the visibility in
> effect inside it are computable.

**Proof.** Ruby evaluates such a block in the context of a statically identifiable
class object: the new (anonymous, or constant-bound `K`) class for
`Class.new`/`Struct.new`, or the literal receiver for `Foo.class_eval`.
Introduce a scope node for that definee when the block is entered. Then (a)
`def`s inside attach to the block's class, not the enclosing one (fixes
misattribution #13/#15), and (b) `private` inside mutates only the block's
visibility (fixes the leak #12). Both are syntactic scope-stack operations on a
statically known definee. $\;\blacksquare$

**Boundary.** `klass.class_eval(&computed_block)` or `Class.new(computed)` with a
runtime receiver/block escapes to reductions §5. The *common* literal forms do
not.

---

## 4. Dead code = unreachable code — Theorem R (the central result)

The recursion / cluster / transitive-dead cases (#9, #10, #11) are one theorem.

> **Theorem R.** Given a finite call graph $G=(V,E)$ and roots $R$, the dead set
> $\mathrm{Dead} = V \setminus \mathrm{Reach}_G(R)$ is computable in
> $O(|V|+|E|)$.

**Proof.** $\mathrm{Reach}_G(R)$ is the least fixed point of
$X \mapsto R \cup \{\, v : \exists u \in X,\ (u,v)\in E\,\}$, computed by one
BFS/DFS from $R$; its complement is $\mathrm{Dead}$. Linear time, total. $\;\blacksquare$

**Why the tool is wrong today, precisely.** The current check marks $m$ alive iff
*some* call names $m$ anywhere in the hierarchy — essentially
$\{v : \mathrm{indeg}(v) > 0\}$ is treated as live. But

$$\{v : \mathrm{indeg}(v) > 0\} \;\neq\; \mathrm{Reach}_G(R).$$

A node fed only by edges from *within an unreachable region* has positive
in-degree yet is unreachable. Two mutually-recursive privates $\{a,b\}$ with
$a\to b$, $b\to a$ and no edge from $R$ satisfy $\mathrm{indeg}>0$ for both, so
both are called "alive," though $\{a,b\}\cap\mathrm{Reach}_G(R)=\varnothing$.
Self-recursion ($a\to a$) and dead chains ($a\to b$, $a\notin\mathrm{Reach}$) are
the same error. **Replacing the in-degree predicate with reachability from $R$
decides all three — it is an algorithm choice, not a theoretical limit.**

**Hypothesis discharged.** Theorem R presupposes the true $G,R$. On the lexical
fragment $L$, §1 gives computable $G,R$, so dead-code detection over $L$ is
decidable. Off $L$ (computed dispatch building unknown edges) is the reductions
doc — but that limits the *inputs* to Theorem R, not Theorem R itself.

---

## 5. Summary

On the lexical fragment, $\mathcal{D}, G, R$ are computable folds over the AST
(§1), and every case above is then either a syntactic predicate (§2), a
scope-stack discipline (§3), or reachability over a finite graph (§4, in P).

$$\textbf{On } L:\quad \mathrm{Dead}(P) \text{ is computable.}$$

None of these is blocked by undecidability, and each is now implemented and
covered by a passing spec (each was, as promised, a finite amount of
engineering). The wall begins exactly where $L$ ends — see
[undecidable-cases.md](undecidable-cases.md).

---

## References

The decidable side draws on **graph theory / complexity theory** (reachability,
fixed points) and classical **dataflow analysis**. See [README.md](README.md)
for the branch-of-mathematics overview and full bibliography.

- Aho, Lam, Sethi & Ullman. *Compilers: Principles, Techniques, and Tools* (the
  "Dragon Book"). — **live-variable analysis** is Theorem L exactly; this is its
  textbook home. Also the standard reference for dataflow as a decidable
  fixpoint computation.
- Cormen, Leiserson, Rivest & Stein. *Introduction to Algorithms.* — graph
  reachability by BFS/DFS in $O(V+E)$; the algorithm behind Theorem R.
- Kildall, G. (1973). *A Unified Approach to Global Program Optimization.* POPL.
  — the monotone-dataflow framework: these analyses are least fixed points over
  a finite lattice, hence computable.
- Tarski, A. (1955). *A lattice-theoretical fixpoint theorem and its
  applications.* Pacific J. Math. — why those least fixed points exist and
  terminate (finite height ⇒ Kleene iteration converges).
- Reps, Horwitz & Sagiv (1995). *Precise Interprocedural Dataflow Analysis via
  Graph Reachability.* POPL. — formalises "the analysis *is* reachability," the
  view Theorem R takes of dead code.
- Grove, D. & Chambers, C. (2001). *A Framework for Call Graph Construction
  Algorithms.* ACM TOPLAS. — how to build the $G(P)$ that §4 assumes, and the
  precision/cost trade-offs when you leave the literal fragment.
- Nielson, Nielson & Hankin. *Principles of Program Analysis.* — ties the above
  together (live variables, call graphs, lattices) in one framework.
