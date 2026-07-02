require 'test_helper'

# The end-to-end catalogue: what Thanatos finds, and how confident it is. Each
# test runs the full pipeline (parse -> index -> reachability + locals) via
# candidates_for, so reading this file tells you what the tool supports. Tests
# are grouped into nested classes by theme. What the tool deliberately does NOT
# support is in out_of_scope_test.rb; the confidence rules for mixed-in modules
# are explored in depth in mixin_confidence_test.rb.
class BehaviourTest < Minitest::Test
  class LocalVariables < Minitest::Test
    test "unused local variables are reported" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call
            unused = compute_something
            42
          end
        end
      RUBY
      assert_includes candidate_names(candidates), :unused
    end
  end

  class ReachabilityBasics < Minitest::Test
    test "an unused private method is a high-confidence candidate" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; end
          private
          def dead; end
        end
      RUBY

      assert_equal 1, candidates.length
      candidate = candidates.first
      assert_equal "Foo", candidate.fqn
      assert_equal :dead, candidate.name
      assert_equal :private, candidate.visibility
      assert_equal :high, candidate.confidence
      assert_empty candidate.reasons
    end

    test "a private method called from within its class is not a candidate" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; helper; end
          private
          def helper; end
        end
      RUBY
      assert_empty candidates
    end

    test "public methods are out of scope" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def maybe_unused; end
        end
      RUBY
      assert_empty candidates
    end

    test "an unused protected method is a candidate" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          protected
          def dead; end
        end
      RUBY
      assert_equal [:dead], candidate_names(candidates)
      assert_equal :protected, candidates.first.visibility
    end
  end

  class InheritanceAndMixins < Minitest::Test
    test "a private method from an included module is alive" do
      candidates = candidates_for(<<~RUBY)
        module Greeting
          private
          def hello; "hi"; end
        end

        class Person
          include Greeting
          def greet; hello; end
        end
      RUBY
      assert_empty candidates
    end

    test "a private method called from a subclass is alive, and a dead sibling is reported" do
      candidates = candidates_for(<<~RUBY)
        class Base
          private
          def used_by_child; end
          def truly_dead; end
        end

        class Child < Base
          def go; used_by_child; end
        end
      RUBY
      assert_equal [:truly_dead], candidate_names(candidates)
      assert_equal "Base", candidates.first.fqn
    end

    test "a Class.new superclass keeps the inheritance chain linked" do
      candidates = candidates_for(<<~RUBY)
        class Animal
          private
          def heartbeat; "thump"; end
        end

        Reptile = Class.new(Animal)

        class Snake < Reptile
          def alive?; heartbeat; end
        end
      RUBY
      assert_empty candidates
    end

    # `extend M` mixes M's INSTANCE methods into the extender's SINGLETON table,
    # so a method of M reached from a class-method context is alive.
    test "a method in an extended module used by a class method is alive" do
      candidates = candidates_for(<<~RUBY)
        module Helpers
          private
          def helper; end
        end

        class Foo
          extend Helpers
          def self.run; helper; end
        end
      RUBY
      assert_empty candidates
    end

    test "a genuinely dead method in an extended module is reported" do
      candidates = candidates_for(<<~RUBY)
        module Helpers
          private
          def unused_helper; end
        end

        class Foo
          extend Helpers
          def self.run; something_else; end
        end
      RUBY
      assert_equal [:unused_helper], candidate_names(candidates)
    end

    test "extend self keeps module-function helpers alive" do
      candidates = candidates_for(<<~RUBY)
        module Toolkit
          extend self
          def run; helper; end
          private
          def helper; end
        end
      RUBY
      assert_empty candidates
    end
  end

  class ClassMethodsAndDimensions < Minitest::Test
    test "private class methods are analysed" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def self.build; new; end
          private_class_method def self.secret_helper; end
        end
      RUBY
      assert_equal [:secret_helper], candidate_names(candidates)
    end

    # Instance and class methods are separate tables: one must not keep a
    # same-named method of the other dimension alive.
    test "a public class method does not keep a dead private instance method alive" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          def helper; end
          def self.helper; end
        end
      RUBY
      assert_equal [:helper], candidate_names(candidates)
    end

    test "a public instance method does not keep a dead private class method alive" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private_class_method def self.helper; end
          def helper; end
        end
      RUBY
      assert_equal [:helper], candidate_names(candidates)
    end

    # A `private` inside `class << self` sets class-method visibility, not the
    # enclosing instance visibility, so the public instance method stays a root.
    test "a private inside class self does not leak to instance visibility" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          class << self
            private
            def cm; end
          end

          def run; helper; end

          private
          def helper; end
        end
      RUBY
      assert_equal [:cm], candidate_names(candidates)
    end
  end

  class GeneratedMethods < Minitest::Test
    test "an unused private attr_reader is reported" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          attr_reader :secret
        end
      RUBY
      assert_equal [:secret], candidate_names(candidates)
    end

    test "methods defined via define_method are tracked" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          define_method(:dynamic) { 1 }
          private :dynamic
        end
      RUBY
      assert_equal [:dynamic], candidate_names(candidates)
    end

    test "methods defined inside an anonymous class are tracked" do
      candidates = candidates_for(<<~RUBY)
        Widget = Class.new do
          def call; helper; end
          private
          def helper; end
          def unused; end
        end
      RUBY
      assert_equal [:unused], candidate_names(candidates)
    end

    test "a private method added via class_eval is analysed on the receiver" do
      candidates = candidates_for(<<~RUBY)
        class Widget; end

        Widget.class_eval do
          private
          def helper; end
        end
      RUBY
      assert_equal [:helper], candidate_names(candidates)
    end

    test "a redefined method is reported only once" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          def dup_me; end
          def dup_me; end
        end
      RUBY
      assert_equal [:dup_me], candidate_names(candidates)
    end
  end

  class DispatchPrecision < Minitest::Test
    test "send with a literal symbol acquits rather than downgrades" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; send(:helper); end
          private
          def helper; end
        end
      RUBY
      assert_empty candidates
    end

    test "a method(:sym) reference acquits rather than downgrades" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; method(:helper); end
          private
          def helper; end
        end
      RUBY
      assert_empty candidates
    end

    # `&:sym` calls sym on each element, not on self, so it is not a usage hint.
    test "a block-pass symbol does not downgrade an unrelated method" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; [1, 2].map(&:process); end
          private
          def process; end
        end
      RUBY
      assert_equal :high, candidates.find { |c| c.name == :process }.confidence
    end
  end

  # Reachability runs from roots through the call graph, so code that only calls
  # itself (or only other dead code) is still reported: it has an in-edge, but no
  # path from a live root.
  class DeadClustersAndRecursion < Minitest::Test
    test "mutually recursive dead private methods are reported" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          def ping; pong; end
          def pong; ping; end
        end
      RUBY
      assert_equal [:ping, :pong], candidate_names(candidates)
    end

    test "a self-recursive dead private method is reported" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          def recurse; recurse; end
        end
      RUBY
      assert_equal [:recurse], candidate_names(candidates)
    end

    test "a private method reachable only through dead code is reported" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def entry_point; end
          private
          def dead_a; dead_b; end
          def dead_b; end
        end
      RUBY
      assert_equal [:dead_a, :dead_b], candidate_names(candidates)
    end
  end

  # The Ruby runtime invokes these directly, so a defined hook (and any private
  # helper it reaches) is a root, not dead.
  class RuntimeHooks < Minitest::Test
    test "initialize is a reachable root" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          private
          def initialize; setup; end
          def setup; end
        end
      RUBY
      assert_empty candidates
    end

    test "runtime hook methods are reachable roots" do
      candidates = candidates_for(<<~RUBY)
        module M
          private
          def method_added(name); track(name); end
          def track(name); end
        end
      RUBY
      assert_empty candidates
    end
  end

  # A dynamic signal never suppresses a candidate; it downgrades it to :low with a
  # reason, because in a standalone static tool that is the only guard against the
  # false positives that callbacks / send / metaprogramming would cause.
  class ConfidenceGrading < Minitest::Test
    test "a matching symbol literal downgrades to low confidence with a reason" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          before_action :guard
          private
          def guard; end
        end
      RUBY

      candidate = candidates.first
      assert_equal :guard, candidate.name
      assert_equal :low, candidate.confidence
      assert_includes candidate.reasons.first, "symbol literal"
    end

    test "dynamic dispatch in the class downgrades to low confidence" do
      candidates = candidates_for(<<~RUBY)
        class Foo
          def call; send(some_name); end
          private
          def maybe_used; end
        end
      RUBY

      candidate = candidates.find { |c| c.name == :maybe_used }
      assert_equal :low, candidate.confidence
      assert(candidate.reasons.any? { |r| r.include?("dynamic dispatch") })
    end

    # A protected method is legally callable with an explicit receiver from within
    # the hierarchy; we can't prove the receiver's type, so a matching explicit
    # call downgrades rather than confirms.
    test "a protected method with a matching explicit call in the hierarchy is downgraded" do
      candidates = candidates_for(<<~RUBY)
        class Measured
          protected
          def score; end
        end

        class Caller < Measured
          def compare(other); other.score; end
        end
      RUBY

      candidate = candidates.find { |c| c.name == :score }
      assert_equal :low, candidate.confidence
      assert(candidate.reasons.any? { |r| r.include?("explicit call") })
    end

    # ...but an explicit call from an UNRELATED class is not a legitimate use of a
    # protected method, so it must not downgrade.
    test "an unrelated explicit call does not downgrade a protected method" do
      candidates = candidates_for(<<~RUBY)
        class Measured
          protected
          def score; end
        end

        class Unrelated
          def rank(other); other.score; end
        end
      RUBY

      assert_equal :high, candidates.find { |c| c.name == :score }.confidence
    end
  end
end
