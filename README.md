# Thanatos

[Thanatos](https://en.wikipedia.org/wiki/Thanatos) was the Ancient Greeks'
personification of death — here, put to helpful use.

Thanatos finds **unused private and protected methods**, and **unused local
variables**, in Ruby code: definitions that are never reached anywhere they
legally could be — for a method, that is its class, its ancestors and
subclasses, and any module mixed into them. It is a purely static, deterministic
tool — it reads your source with [Prism](https://github.com/ruby/prism) and
boots nothing.

It reports **candidates for deletion, not proof**. Ruby is dynamic, so a method
that looks unreferenced may still be reached via a callback, `send`, or
metaprogramming. Thanatos surfaces those uncertain cases too, but flags them as
low confidence with a reason — see [Output](#output). It deliberately does
**not** chase public-method or whole-class/module liveness: their call surface
is open (routes, views, reflection), which needs a runtime/coverage tier, not
static analysis. Where that boundary falls, and why, is in
[`docs/decidability.md`](docs/decidability.md).

## Usage

Requires **Ruby 3.4+** (Prism ships in the standard library). This is not a
released gem, so clone the repo and call the executable directly, pointing it
at the code you want to analyse:

```sh
# A whole project (recurses into every *.rb file, sorted)
./exe/thanatos ~/code/my-app

# A single directory or file
./exe/thanatos ~/code/my-app/app/models
./exe/thanatos ~/code/my-app/app/models/user.rb

# No argument analyses the current directory
./exe/thanatos

# Only report high-confidence findings (default is low, i.e. show everything)
./exe/thanatos ~/code/my-app --min-confidence high

# Load Ruby files that register plugins via Thanatos.configure (see Plugins below)
./exe/thanatos ~/code/my-app --plugins config/thanatos.rb
```

The path may live in any project — Thanatos analyses whatever Ruby files it
finds under it. (Running the test suite needs the dev gems: `bundle install`
then `bundle exec rake test`. The CLI itself needs only Ruby 3.4+.)

## Output

Findings are grouped by where they live (the constant for a method, the method
for a local), then listed as one row each: **visibility** (`private`,
`protected`, or `local`), **name**, **confidence**, and the **file:line** where
it is defined. A summary line follows.

```
Base
  private   orphan                       high  app/models/base.rb:12
MyApp
  private   never_called                 high  app/services/my_app.rb:8

2 candidate(s), 2 high-confidence.
```

When nothing is found:

```
No unused private/protected methods found.
```

### Confidence

- **`high`** — no dynamic signals were seen. These are the strongest deletion
  candidates: start here.
- **`low`** — the method looks unreferenced, but something in scope could be
  reaching it dynamically, so Thanatos is hedging. Each low-confidence finding
  prints the reason(s) on an indented `↳` line. Read the reason before acting —
  it is usually a real escape hatch:

```
PaymentsController
  private   verify_signature             low   app/controllers/payments_controller.rb:42
    ↳ referenced as symbol literal :verify_signature (callback/delegate/send?)

1 candidate(s), 0 high-confidence.
```

Common reasons: a matching symbol literal (likely a `before_action`/`delegate`/
`send` target), `send`/`define_method`/`method_missing` present in the class, a
matching explicit call for a protected method, or a [plugin](#plugins)
recognising a framework macro that reaches the method.

### Exit code

- **`0`** — no *high-confidence* candidates. (Low-confidence findings are still
  printed for your information, but do not fail the run.)
- **`1`** — at least one high-confidence candidate.

This makes it usable as a CI gate: the build fails only on the findings Thanatos
is confident about, while low-confidence ones stay advisory.

### How to act on it

Treat the list as a worklist, not a verdict. Delete high-confidence findings
after a quick sanity check; for low-confidence ones, confirm the printed reason
does not apply before removing anything. And remember the
[boundary](docs/decidability.md): an empty report does not mean everything else
is used — only that nothing unused was found among private/protected methods and
local variables in the analysed paths. Public methods and whole-class liveness
are out of scope; they need a runtime tier.

### Why you might see a false positive

A high-confidence finding is a strong candidate, but on a framework-heavy app a
few families recur — worth recognising before you delete:

- **Truly dead** — the common case, and the point of the tool (e.g. an
  `attr_accessor` whose writer is never assigned). Delete it.
- **Out of architecture** — the caller is outside the analysed paths (a gem base
  class, a Rails callback), or the framework builds the method name at runtime
  (`"include_#{assoc}?"`). Widen the scan to include the caller, or leave it: it
  is the same open call surface as a public method.
- **A gap in the tool** — a real bug it should fix. Rare, and each becomes a
  failing test when found.

## Plugins

Thanatos only sees the files you point it at, so a private method reached by a
gem macro — a `before_action` callback, a `delegate` target — looks unreferenced
even though the framework calls it. A **plugin** teaches Thanatos what such a
macro means, so instead of a blunt low-confidence hedge the finding carries a
specific reason (`↳ invoked as a before_action callback`). Codebases with their
own DSLs can write a plugin for them and keep the benefit of Thanatos on their
own stack.

You **register** plugins in Ruby via `Thanatos.configure` — natural when
embedding Thanatos as a gem:

```ruby
Thanatos.configure { |config| config.register_plugin(MyControllerPlugin) }
```

From the CLI, `--plugins a.rb,b.rb` loads Ruby files that are expected to call
`configure`. Defining a `Thanatos::Plugin` subclass does nothing on its own —
only registering it does. No plugins ship by default, and with no `--plugins`
nothing changes.

Plugins are deliberately weak — they can only **attach a reason** (which
downgrades a finding to `low`), never mark a method reachable — so a wrong plugin
adds noise but can never hide dead code. The full authoring guide, the ancestry
gate, and the assumptions are in [`docs/plugins.md`](docs/plugins.md).

## Testing

The project uses minitest; run the suite with `rake` or `rake test`.

To run a single file or filter by test name, use the `TEST` and `TESTOPTS`
environment variables:

```sh
rake test TEST='test/analyzer_test.rb'
rake test TEST='test/analyzer_test.rb' TESTOPTS="--name=/dead private method/ -v"
```

## Docs

- [architecture.md](docs/architecture.md) — how it works inside.
- [decidability.md](docs/decidability.md) — what it can and can't decide, and why.
- [plugins.md](docs/plugins.md) — teaching Thanatos about gem macros, and how to write a plugin.
- [design-critique.md](docs/design-critique.md) — known weaknesses and what's next.
