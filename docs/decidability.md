# What Thanatos can and can't decide

Thanatos is a *static* tool, so its scope is bounded by what static analysis can
prove. Almost every construct splits the same way:

> The **literal / lexical** fragment is decidable — often just graph reachability
> or a lexical read of the source. The **computed** fragment — where a name,
> constant, condition, or block is produced at runtime — is **undecidable**, by
> reduction from the halting problem (a corollary of Rice's theorem: no total
> algorithm decides a non-trivial semantic property of a program).

So the engineering follows the maths: **implement the lexical fragment; abstain
on the computed tail** — Thanatos still reports the computed cases, but downgrades
them to low confidence with a reason rather than claiming them dead.

## Decidable — implemented

| Case | Why it's decidable |
|------|--------------------|
| Unused local variables | per-scope write/read diff, lexical |
| Dead / self-recursive / transitively-dead methods | graph reachability from roots — an in-edge isn't a live root |
| `private_class_method` / `def self.x` visibility | literal visibility applied to a literal name |
| Absolute `::Foo` constant scoping | lexical constant path |
| `&:sym` block-pass precision | `sym` is called on elements, not `self` — lexical |
| De-duplicating a redefined method | trivial |
| Surfacing parse errors | Prism reports them |

## Decidable for literal input, undecidable when computed

Implemented on the literal fragment; a computed argument downgrades instead.

| Case | Literal (decided) | Computed (abstained) |
|------|-------------------|----------------------|
| `send(:x)` / `method(:x)` | a definite call — acquits the target | `send(name)` — the name is a runtime value |
| `attr_reader :x` / `define_method(:x)` | defines a literal method name | computed name → not knowable statically |
| `include` / `prepend` / `extend M` | a literal module joins the ancestry | a computed module argument |
| Visibility / methods inside `Class.new`/`Struct.new`/`class_eval` blocks | a literal block is that class's body | a computed/`eval`'d block |

`ActiveSupport::Concern` is the compound worst case: `included`/`class_methods`
blocks plus convention-computed names mean the effective method set isn't fixed
by the source — the same reduction as the rows above.

## Undecidable — out of scope

Not a missing feature; no static tool can be sound and complete here. These need
a runtime / coverage tier (boot the app, observe real invocations).

| Case | Why it's undecidable |
|------|----------------------|
| Public-method liveness | open call surface — routes, views, reflection, other gems — invisible to the source (also open-world) |
| Class / module liveness | constant references are computed at runtime (`constantize`, autoload, STI) |
| A computed `Class.new(superclass)` | the superclass is a runtime value |
| A conditional visibility modifier (`private if cond`) | a non-literal predicate is a runtime value |

## Where this lives in the tests

The decidable rows are exercised end-to-end in
[`test/behaviour_test.rb`](../test/behaviour_test.rb) (and at the unit level in
[`test/index_builder_test.rb`](../test/index_builder_test.rb)). The two
undecidable rows kept as executable-but-skipped boundary markers are in
[`test/out_of_scope_test.rb`](../test/out_of_scope_test.rb).

## Further reading

- [Rice's theorem](https://en.wikipedia.org/wiki/Rice%27s_theorem) — every
  non-trivial semantic property of programs is undecidable.
- Sipser, *Introduction to the Theory of Computation* — the standard text for
  decidability and reductions from the halting problem.
- Møller & Schwartzbach, [*Static Program Analysis*](https://cs.au.dk/~amoeller/spa/)
  (free) — how tools approximate soundly once they hit that wall.
