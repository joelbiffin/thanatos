# Thanatos

[Thanatos](https://en.wikipedia.org/wiki/Thanatos) was the Ancient Greeks'
personification of death — here, put to helpful use.

Thanatos finds **unused private and protected methods** in Ruby code: methods
that are defined but never called anywhere they legally could be (their class,
its ancestors, or its subclasses). It is a purely static, deterministic tool —
it reads your source with [Prism](https://github.com/ruby/prism) and boots
nothing.

It reports **candidates for deletion, not proof**. Ruby is dynamic, so a method
that looks unreferenced may still be reached via a callback, `send`, or
metaprogramming. Thanatos surfaces those uncertain cases too, but flags them as
low confidence with a reason — see [Output](#output). It deliberately does
**not** look at public methods, classes/modules, or local variables; the
boundaries are documented as skipped specs in
[`test/known_limitations_test.rb`](test/known_limitations_test.rb).

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
```

The path may live in any project — Thanatos analyses whatever Ruby files it
finds under it. (Running the test suite needs the dev gems: `bundle install`
then `bundle exec rake test`. The CLI itself needs only Ruby 3.4+.)

## Output

Findings are grouped by the constant (class/module) they belong to, then listed
as one row each: **visibility**, **method name**, **confidence**, and the
**file:line** where it is defined. A summary line follows.

```
Base
  private   orphan                       high  app/models/base.rb:12
MyApp
  private   never_called                 high  app/services/my_app.rb:8

<<<<<<< HEAD
### Testing

The project just uses minitest and the test suite can be run via, `rake` or `rake test`.

To run a specific test method, you can use the `TEST` and `TESTOPTS` environment variables:

````
rake test TEST='test/thanatos_test.rb' TESTOPTS="--name=test_single_class_method_definitions_and_called_are_stored -v"
=======
2 candidate(s), 2 high-confidence.
>>>>>>> 77a7e86 (Rebuild Thanatos as a static dead-method finder)
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
`send` target), `send`/`define_method`/`method_missing` present in the class, or
a matching explicit call for a protected method.

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
[known limitations](test/known_limitations_test.rb): an empty report does not
mean everything else is used — only that no unused *private or protected*
methods were found within the analysed paths.
