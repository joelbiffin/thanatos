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

## The levers, and what keeps them safe

A plugin has three levers:

- **reason** (`reference_macro`) — attaches a reason, which downgrades the finding
  to `:low`. A wrong reason only adds noise; the method is still reported.
- **acquit** (`invokes`) — declares that a DSL *definitely* invokes a method, so it
  is reached and removed from the candidate list entirely. For the case a reason
  can't express: a state-machine guard (`transitions guard: :may_run?`) that is
  genuinely called, not merely maybe-referenced.
- **account** (`accounts_for_dispatch`) — declares what a dynamic construct
  (`send`, `method_missing`) *reaches*, so methods it provably can't touch stop
  being wholesale-downgraded. A method left clean this way is graded **`medium`**
  (dead as far as we and the plugin can tell, but resting on the plugin's claim),
  not `low`.

Two of these can go wrong in ways worth knowing. **acquit** can *hide* a finding,
so a wrong `invokes` is a false negative -- mitigated by acquittals never being
silent (a count always, the detail under `--show-acquittals`, naming the plugin
and macro that vouched). **account** can *promote* a finding, so a wrong
`accounts_for_dispatch` puts a live method in `medium` -- bounded because `medium`
never gates CI (that's `high` only) and each `medium` names the plugin that
vouched. The invariant across all three: no plugin action is invisible — a reason
shows as `:low`, an acquittal shows in the acquittals report, an account shows as
`:medium` with its provenance.

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

### 3. Acquit definitely-invoked methods with `invokes`

When a DSL *definitely* calls a method — a state-machine guard, a callback that
genuinely fires — declare it with `invokes`, and the method is treated as reached
(not a candidate). It mirrors `reference_macro`'s slots, so you name only the ones
that carry invoked method symbols:

```ruby
class AASMPlugin < Thanatos::Plugin
  inherits_from "AASM"
  invokes :transitions, kwargs: %i[guard if unless]   # from:/to: are states, not methods
  invokes :before, :after                              # event callback symbols are invoked
end
```

Given `transitions from: :sleeping, to: :running, guard: :may_run?`, `may_run?`
drops out of the candidate list and appears in the acquittals report
(`--show-acquittals`) as vouched-for by this plugin. Use `invokes` only where the
call is genuinely definite; where it's merely *possible*, use `reference_macro`
(which downgrades rather than removes).

### 4. Un-taint dynamic dispatch with `accounts_for_dispatch`

A `send`/`method_missing` anywhere in a hierarchy currently downgrades *every*
private in it to `low`, wholesale. If you know what a construct actually reaches,
`accounts_for_dispatch` says so, and methods it can't touch are reclaimed to
`medium` instead of drowning in `low`:

```ruby
class ServiceObjectPlugin < Thanatos::Plugin
  inherits_from "Service"                 # a base whose plumbing does public_send(name)
  accounts_for_dispatch reaches: :public  # ...to the public entry, never a private
end
```

`reaches:` takes `:public`/`:none` (reaches nothing a private candidate could be),
a `Regexp` (reaches names matching it — a `send("on_#{e}")` dispatcher hits
`/\Aon_/`, so unrelated privates are reclaimed while `on_*` stay `low`), or a name
list. For a reach derived from the class itself — a serializer's declared
`attributes`, say — override `account_for(facts)` and return the reach.

Unlike the other two levers, this one can *promote*: a wrong account puts a live
method in `medium`. That's why it's `medium`, not `high` — it never gates CI, and
the finding names the plugin that vouched, so a bad account is traceable.

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

Registration is explicit — defining a `Thanatos::Plugin` subclass does nothing
on its own; you opt it in via `Thanatos.configure`:

```ruby
Thanatos.configure do |config|
  config.register_plugin(MyControllerPlugin)   # a class (instantiated for you)
  config.register_plugin(MyJobPlugin.new)      # or an already-built instance
end
```

This is the natural path when embedding Thanatos as a gem: configure once (e.g.
in an initializer or a rake task), then `Thanatos.analyze("app")` picks the
plugins up.

```ruby
Thanatos.configure { |c| c.register_plugin(MyControllerPlugin) }
Thanatos.analyze("app")   # applies the configured plugins
```

From the CLI, `--plugins` loads Ruby files that are expected to call
`configure`. A complete file defines the plugin *and* registers it:

```ruby
# config/thanatos.rb
class ControllerCallbacks < Thanatos::Plugin
  inherits_from "ApplicationController"
  reference_macro :before_action, positional: "invoked as a %{macro} callback"
end

Thanatos.configure { |config| config.register_plugin(ControllerCallbacks) }
```

```sh
./exe/thanatos app --plugins config/thanatos.rb
# several, comma-separated:
./exe/thanatos app --plugins config/controllers.rb,config/jobs.rb
```

Each file is `require`d (it can assume Thanatos is already loaded, so no
`require` at the top), and the plugins it registers are applied. There is no
auto-discovery: a subclass that is defined but never registered is inert, and
with no `--plugins` nothing changes.

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

## Why a reason is a conclusion, not a signal

Thanatos separates a *signal* (a raw observation from the source — a symbol
literal, a dynamic-dispatch marker, a call site; see
[`ReferenceSignals`](architecture.md)) from a *conclusion* (an already-rendered
reason). A plugin author writes the reason string, so the reason lever
contributes conclusions. That's why `plugin_reasons` is kept out of
`ReferenceSignals` and layered on afterward — the boundary is discussed in
[design-critique.md](design-critique.md) §2.6. (The other two levers are different
again: acquit contributes a call *edge*, and account *narrows a marker* — neither
is a reason or a signal.)

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
