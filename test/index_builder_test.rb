require 'test_helper'

# IndexBuilder walks a Prism AST and records, per constant scope, the facts
# Reachability needs: method definitions (instance and class, with visibility),
# the call graph, bare symbol literals, dynamic-dispatch markers, and
# superclass / include / extend references. It makes no deadness decisions.
class IndexBuilderTest < Minitest::Test
  test "records a receiverless call's symbol arguments as a call site, split by slot" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        guard :authenticate, if: :logged_out?, only: %i[show edit]
      end
    RUBY

    site = facts.call_sites.find { |call_site| call_site.name == :guard }
    assert_equal [:authenticate], site.positional
    assert_equal({ if: [:logged_out?], only: %i[show edit] }, site.kwargs)
  end

  test "a receiverless call with no symbol arguments records no call site" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        log("started", level: 3)
      end
    RUBY

    assert_empty facts.call_sites
  end

  test "partitions definitions by ambient visibility" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a; end
        protected
        def b; end
        private
        def c; end
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal({ a: :public, b: :protected, c: :private }, visibilities)
  end

  test "private with a symbol argument marks only that method" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a; end
        def b; end
        private :b
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :public, visibilities[:a]
    assert_equal :private, visibilities[:b]
  end

  test "private def x marks one method without flipping ambient visibility" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        private def a; end
        def b; end
      end
    RUBY

    visibilities = facts.definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :private, visibilities[:a]
    assert_equal :public, visibilities[:b]
  end

  # A symbol passed to a visibility modifier is bookkeeping, not a usage, so it
  # must not pollute the symbol-literal set (a dynamic-reach hint for Reachability).
  test "a symbol argument to a visibility modifier is not recorded as a literal" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def b; end
        private :b
      end
    RUBY

    refute_includes facts.symbol_literals, :b
  end

  test "separates implicit self-calls from explicit-receiver calls" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a
          helper
          self.thing
          collaborator.external
        end
      end
    RUBY

    assert_includes facts.implicit_calls, :helper
    assert_includes facts.implicit_calls, :thing
    assert_includes facts.explicit_calls, :external
    refute_includes facts.implicit_calls, :external
  end

  # A literal selector resolves (acquits); a computed one stays a marker, so this
  # uses a variable selector to exercise the dynamic-dispatch path.
  test "records a computed selector as a dynamic-dispatch marker" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a(name); send(name); end
      end
    RUBY

    assert_includes facts.dynamic_markers, :send
  end

  # Both alias forms count as a use of the original: `alias_method` (a call) and
  # the `alias` keyword (an AliasMethodNode).
  test "an alias counts as a use of the original method" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def original; end
        def other; end
        alias_method :renamed, :original
        alias aliased other
      end
    RUBY

    assert_includes facts.implicit_calls, :original
    assert_includes facts.implicit_calls, :other
  end

  test "builds fully-qualified names for nested namespaces" do
    index = index_for(<<~RUBY)
      module Outer
        class Inner
          def a; end
        end
      end
    RUBY

    refute_nil index["Outer::Inner"]
    assert_equal [:a], index["Outer::Inner"].definitions.map(&:name)
  end

  test "resolves a superclass within its enclosing namespace" do
    index = index_for(<<~RUBY)
      module M
        class Base; end
        class Child < Base; end
      end
    RUBY
    index.resolve_inheritance!

    assert_equal "M::Base", index["M::Child"].superclass_fqn
    assert_equal ["M::Child"], index.descendants("M::Base").map(&:fqn)
  end

  # `::Foo` inside a module is top-level, not rescoped under the module.
  test "an absolute constant path is not rescoped under a module" do
    index = index_for(<<~RUBY)
      module A
        class ::Foo
          def a; end
        end
      end
    RUBY

    refute_nil index["Foo"]
    assert_nil index["A::Foo"]
  end

  test "attr macros and a literal define_method are recorded as definitions" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        attr_reader :a
        attr_accessor :b
        define_method(:c) { 1 }
      end
    RUBY

    assert_equal %i[a b b= c], facts.definitions.map(&:name).sort
  end

  test "class methods are recorded in the singleton dimension" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def instance_m; end
        def self.build; end
        private_class_method def self.secret; end
      end
    RUBY

    assert_equal [:instance_m], facts.definitions.map(&:name)
    assert_equal %i[build secret], facts.singleton_definitions.map(&:name).sort
    visibilities = facts.singleton_definitions.to_h { |d| [d.name, d.visibility] }
    assert_equal :public, visibilities[:build]
    assert_equal :private, visibilities[:secret]
  end

  # A literal send/method selector is a definite call - not a symbol-literal hint,
  # and not a dynamic-dispatch marker.
  test "a literal send/method selector is recorded as a definite call" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a
          send(:helper)
          method(:other)
        end
      end
    RUBY

    assert_includes facts.implicit_calls, :helper
    assert_includes facts.implicit_calls, :other
    refute_includes facts.symbol_literals, :helper
    refute_includes facts.dynamic_markers, :send
  end

  # `&:sym` calls sym on each element, not on self, so it is not a usage hint.
  test "a block-pass symbol is not recorded as a symbol literal" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        def a
          [1].map(&:process)
        end
      end
    RUBY

    refute_includes facts.symbol_literals, :process
  end

  test "include and extend are recorded as constant refs" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        include Greeting
        extend Helpers
      end
    RUBY

    assert_includes facts.include_refs, [:Greeting]
    assert_includes facts.extend_refs, [:Helpers]
  end

  test "class_eval reopens the receiver constant" do
    index = index_for(<<~RUBY)
      class Widget; end

      Widget.class_eval do
        def added; end
      end
    RUBY

    assert_includes index["Widget"].definitions.map(&:name), :added
  end

  # A Struct.new / Class.new / Data.define block defines a new class, so its
  # `def`s and `private` stay contained.
  test "a private inside a class-defining block does not leak out" do
    facts = facts_for(<<~RUBY, "Outer")
      class Outer
        def a; end

        Thing = Struct.new(:x) do
          private
          def helper; end
        end

        def b; end
      end
    RUBY

    assert_equal :public, facts.definitions.to_h { |d| [d.name, d.visibility] }[:b]
  end

  test "methods in a class-defining block are not attributed to the outer class" do
    facts = facts_for(<<~RUBY, "Outer")
      class Outer
        Thing = Struct.new(:x) do
          def helper; end
        end
      end
    RUBY

    refute_includes facts.definitions.map(&:name), :helper
  end

  # A guarded modifier (`private if false`) has a non-literal predicate, so it is
  # not applied - the following def stays public.
  test "a conditional visibility modifier is not applied unconditionally" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        private if false

        def still_public; end
      end
    RUBY

    assert_equal :public, facts.definitions.to_h { |d| [d.name, d.visibility] }[:still_public]
  end

  # `class << self` opens the singleton class: its defs are class methods and its
  # `private` is independent of the enclosing instance visibility.
  test "class self defines singleton methods without leaking visibility" do
    facts = facts_for(<<~RUBY, "Foo")
      class Foo
        class << self
          private
          def cm; end
        end

        def run; end
      end
    RUBY

    instance = facts.definitions.to_h { |d| [d.name, d.visibility] }
    singleton = facts.singleton_definitions.to_h { |d| [d.name, d.visibility] }

    assert_equal :public, instance[:run]
    refute_includes facts.definitions.map(&:name), :cm
    assert_equal :private, singleton[:cm]
  end
end
