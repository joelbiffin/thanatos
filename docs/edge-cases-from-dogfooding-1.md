# Edge Cases from Dogfooding a Rails Monolith

A field report. The tool was run over the `app/` tree of a large Rails monolith
(~10,570 Ruby files): **3,543 candidates, 807 high-confidence, in ~6s**. I
reviewed the high-confidence private/protected findings against their source and
classified each *kind* of edge case by **why** it was flagged — because the
"why" is what tells you whether a finding is a tool bug, a tool limit, or the
tool being right.

(Examples below are minimal, generic reproductions, not the monolith's source.)

## The classification lens

Every flagged candidate falls into one of four buckets, which map directly onto
the decidability boundary in [README.md](README.md):

| Bucket | Meaning | Action |
|---|---|---|
| **Decidable gap** | A real false positive the tool *can* resolve statically | Fix the tool (write a failing spec) |
| **Out of architecture** | A false positive whose caller/root is outside the analysed code or computed at runtime | Needs the runtime / entry-point tier (M3); not a static bug |
| **Non-issue** | Looked like a gap, but the tool already handles it | Verify and move on |
| **True positive** | Genuinely dead; the tool is right | None |

## Summary

| # | Edge case | Why it was flagged | Bucket |
|---|-----------|--------------------|--------|
| 1 | Constructor hook (`initialize`, ×8) | invoked by `.new`, never by an explicit call | **Decidable gap** |
| 2 | Reflection hook (`method_added`) | invoked by the Ruby runtime | **Decidable gap** |
| 3 | A hook's private helper | its only caller is a (wrongly-dead) hook — transitive | **Decidable gap** (same root cause) |
| 4 | Framework callback (Rails `append_info_to_payload`) | Rails calls it; the caller is not in `app/` | **Out of architecture** |
| 5 | Convention dispatch (serializer `include_<assoc>?`, ×9 in one file) | the framework builds the name `"include_#{assoc}?"` | **Out of architecture** |
| 6 | Gem template method (`handle(event:)`) | the base class that calls it lives in a gem | **Out of architecture** |
| 7 | `super` to a same-named ancestor method | — | **Non-issue** |
| 8 | Unused accessor writer (`private attr_accessor`, ~173 setters) | the writer genuinely has no caller | **True positive** |

---

## Detail

### 1–3. Ruby runtime hooks and their helpers — *Decidable gap*

```ruby
class Foo
  private
  def initialize   # invoked by .new; the tool sees no explicit caller
    setup
  end
  def setup; end    # reached only from initialize -> also flagged (transitive)
end
```

`initialize` (8 occurrences) and `method_added` (1) are invoked **by the Ruby
runtime itself**, never by an explicit call, so they look unreferenced. Worse,
any private helper reached *only* from such a hook is flagged too (its sole
caller is itself considered dead) — so one missing root produces a small cluster
of false positives. Verified with a probe: the snippet above flags both
`initialize` and `setup`.

This is **decidable and language-level**: a fixed set of runtime-hook names
(`initialize`, `method_missing`, `respond_to_missing?`, `method_added`,
`inherited`, `included`, `extended`, `prepended`, `const_missing`, …) should be
seeded as always-reachable roots. Captured as failing specs
`test_initialize_is_a_reachable_root` and
`test_runtime_hook_methods_are_reachable_roots`.

### 4–6. Framework- and gem-invoked methods — *Out of architecture*

```ruby
class MyController < ApplicationController
  private
  def append_info_to_payload(payload)  # Rails calls this; the caller is in Rails
    super
    payload[:owner] = owner
  end
end
```

Three shapes, one root cause: the method's caller is **outside the analysed
`app/` tree, or its name is computed by the framework**.
- *Framework callbacks*: a controller hook (`append_info_to_payload`) invoked by
  Rails internals.
- *Convention dispatch*: a serializer's `include_<association>?` methods, which
  the serializer library calls by building the string `"include_#{name}?"` from
  the association name. The association symbol appears literally, but the method
  name never does.
- *Gem template methods*: an instrument's `handle(event:)`, called by a base
  class that lives in a gem rather than in `app/`.

None of these is a static bug. They are the **same open-call-surface problem as
public methods**: the root of reachability is not in the analysed code (or is
computed at runtime). This is exactly what the runtime/entry-point tier (M3)
exists to supply — boot the app and harvest the framework's real invocation
points — rather than something more static analysis can recover. Filed under the
existing public-method / class-liveness boundary, not as new static work.

### 7. `super` to a same-named ancestor — *Non-issue*

```ruby
class Base
  def run; setup; end
  private
  def setup; end           # reached via run -> setup
end
class Sub < Base
  private
  def setup; super; end    # NOT a false positive
end
```

I suspected `super` would be a false-positive source (the tool records no call
for `super`). It is not: reachability is name-based, and `super` invokes the
**same-named** method, which is already the same graph node. If `setup` is
reached at all, every `setup` definition in the hierarchy is reached. The probe
returned no candidates. No action — the design already covers it.

### 8. Unused accessor writers — *True positive*

```ruby
class Client
  private
  attr_accessor :account_id   # reader used via `{ account_id: }`; writer never called
end
```

~173 private setters (`name=`) were flagged. Reviewing them, the common shape is
an `attr_accessor` whose **reader is used but whose writer is never assigned via
`self.name =`** — the value is set straight into `@name`. That writer *is* dead
code (the accessor should be a reader). The tool is correct; these are not false
positives.

---

## Method and coverage

- Each classification was checked two ways: by **reading the source** of a sample
  of high-confidence findings, and by **reproducing the pattern** with a minimal
  synthetic snippet run against the built tool (so the verdict does not depend on
  any one file).
- I deep-inspected a *sample* of the 807 high-confidence findings, not all 3,543
  candidates. The long tail is expected to distribute across the families above
  plus genuine dead code; this report classifies the *kinds* encountered, not
  every instance.

## Takeaway

Of everything reviewed, exactly **one kind** is a statically-fixable false
positive — the runtime hooks (bucket 1–3) — and it is now a failing spec. The
rest is either the tool being correct (true positives), a gap already closed
(`super`), or the open-call-surface limit that belongs to the runtime tier
(framework-invoked). That ratio is the useful result: on a real monolith, the
static fragment's residual false positives are dominated by *framework
invocation it cannot see*, not by decidable bugs — which is precisely the
argument for M3.
