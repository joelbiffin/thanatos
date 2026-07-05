# Plugins — teaching Thanatos about gem macros

Thanatos only sees the files you point it at. But a private method is often
reached from code Thanatos never parses: a gem macro like `before_action`,
`delegate`, or `has_many` invokes it from *inside* the framework. Statically
that method looks unreached, so Thanatos hedges — it downgrades it to `:low`
with the generic "referenced as symbol literal" note. Accurate, but blunt: it
can't say *why*, or that the caller is vendored framework code.

A **plugin** teaches Thanatos what a specific macro means. Knowing that
`before_action :authenticate` genuinely sends `:authenticate` at request time
lets Thanatos record that the method is reached from vendored code and explain
it precisely — instead of guessing from a bare symbol. And a codebase with its
own tooling or in-house DSLs can describe *its* macros and keep the benefit of
Thanatos on its own stack, without changing Thanatos itself.

## The one rule that keeps plugins safe

A plugin can **only attach a reason** to a method, which downgrades that method's
candidate to `:low` confidence. It cannot add reachability edges, define methods,
or seed roots. So:

> A wrong or careless plugin can make a finding noisier, but can **never hide**
> genuinely dead code.

That is the deliberate difference from "acquittal" (marking the method reached,
which would remove the finding): acquittal on a bad assumption is a false
negative — the one thing Thanatos refuses. Downgrading is safe because the method
is still reported; only its confidence changes. This is why the reason text is
the product: it's printed next to the finding, so the human sees the plugin's
claim and can check it.

## Writing a plugin

Subclass `Thanatos::Plugin`. Two extension points.

### 1. Declare a macro with `reference_macro`

The common case: a gem macro whose symbol arguments name methods it will invoke.

```ruby
class ActionControllerPlugin < Thanatos::Plugin
  inherits_from "ActionController::Base", "ApplicationController"

  reference_macro :before_action, :after_action, :around_action,
    positional:    "invoked as a %{macro} callback",
    kwargs:        { if: "invoked as the %{macro} :if guard",
                     unless: "invoked as the %{macro} :unless guard" },
    default_kwarg: "referenced in %{macro} %{key}:"
end
```

- **`positional`** — the reason for each bare symbol argument
  (`before_action :authenticate` → `authenticate`).
- **`kwargs`** — a reason per named option whose value is a symbol
  (`if: :logged_out?` → `logged_out?`).
- **`default_kwarg`** — the reason for symbols under *any other* keyword. This
  keeps the net wide: an option you didn't name is still flagged, just with a
  generic reason. `%{macro}` and `%{key}` interpolate into the templates.

Every literal symbol in the call (positional and keyword, including symbols in
arrays like `only: %i[show edit]`) becomes a reason. Because a plugin only
*downgrades*, casting a wide net is safe: the worst case is a method shown as
`:low` instead of `:high`, never a hidden one. The named `kwargs` entries exist
only to make the *reason* accurate, not to decide *what* gets flagged.

### 2. Override `reasons_for_class` for anything else

When a gem's convention can't be expressed as "symbols in a call are methods",
override the method directly and return `[name, reason]` pairs:

```ruby
class SchedulerPlugin < Thanatos::Plugin
  inherits_from "ScheduledTask"

  def reasons_for_class(facts)
    [[:run, "invoked by the scheduler (convention)"]]
  end
end
```

Here `run` never appears as a symbol, so the core rules leave it `:high`; the
plugin alone drops it to `:low`. `facts.signals.call_sites` gives you the raw
call data if you need it.

## The gate: `inherits_from`

`before_action` only *means* the Rails callback because the class is a
controller — the macro exists only inside that hierarchy. So gating a plugin to
a base class isn't a precision tweak; it models the mechanism. `inherits_from`
matches against the **written** ancestry chain, so a gem base like
`ActionController::Base` still matches even though Thanatos never parsed it — as
long as an in-scope link (e.g. your `ApplicationController`) names it. Declare
both the gem base and your app base so the match holds whichever is in scope.

Omit `inherits_from` for a genuinely universal idiom. `delegate` is
`Module#delegate` — available on every object, tied to no base class — so its
plugin should be ungated and fire everywhere.

## Registering a plugin

There is no auto-discovery. You register a plugin by pointing `--plugins` at the
Ruby file(s) that define it:

```sh
./exe/thanatos app --plugins config/thanatos_plugins.rb
# several, comma-separated:
./exe/thanatos app --plugins config/controllers.rb,config/jobs.rb
```

Each file is `require`d, and the `Thanatos::Plugin` subclasses it defines
(registered the moment they're defined) are instantiated and applied to the run.
The file can assume Thanatos is already loaded, so `class MyPlugin <
Thanatos::Plugin` just works — no `require` at the top of your plugin file. If
you don't pass `--plugins`, no plugins run and output is unchanged.

Driving the library directly instead of the CLI:

```ruby
Thanatos.analyze("app", plugins: [MyPlugin.new])
# or, for the full candidate list:
Thanatos::Analyzer.new(paths: ["app"], plugins: [MyPlugin.new]).call
```

## Assumptions a callback plugin makes

Worth knowing, because they're where a plugin's reasons can be wrong. Most fail
*safe* (you lose a reason, you don't gain a false one):

| Assumption | If wrong | Direction |
|---|---|---|
| A symbol argument is `send`-ed at runtime | — | the core case |
| `if:`/`unless:`/other kwargs also name methods | over-flags | safe (only ever a `:low` reason) |
| The macro is the framework's, not an app method of the same name | wrong reason | the gate makes this rare |
| The chain reaches a declared base | plugin doesn't fire | safe — candidate kept, ungraded by the plugin |
| Only literal symbols count | computed args skipped | safe — candidate kept |

Because plugins downgrade rather than hide, the dangerous direction —
*under*-flagging (leaving a dynamically-reached method at `:high`) — is the one
to guard, which is why the net over arguments is deliberately wide.

## Why plugins produce reasons, not signals

Thanatos separates a *signal* (a raw observation from the source — a symbol
literal, a dynamic-dispatch marker, a call site; see
[`ReferenceSignals`](architecture.md)) from a *conclusion* (an already-rendered
reason). A plugin author writes the reason string, so a plugin contributes
conclusions. That's why `plugin_reasons` is kept out of `ReferenceSignals` and
layered on afterward — the boundary is discussed in
[design-critique.md](design-critique.md) §2.6.

## Where this is tested

- [test/plugin_test.rb](../test/plugin_test.rb) — the contract end-to-end, with
  plugins synthesised inline (a declarative `reference_macro` plugin and a
  `reasons_for_class` override), including the gate holding on a non-descendant.
- [test/reference_signals_test.rb](../test/reference_signals_test.rb) — the
  signal model the plugin call-site data lives in.
- [test/index_test.rb](../test/index_test.rb) — `inherits_from?` and the
  written-chain gate.
- [test/cli_test.rb](../test/cli_test.rb) — `--plugins` loading a file and
  applying its plugin end-to-end.
