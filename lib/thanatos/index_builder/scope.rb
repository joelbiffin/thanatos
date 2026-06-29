module Thanatos
  class IndexBuilder
    # A frame on the lexical scope stack. `Scope` is the base; each kind is a
    # subclass that says what the frame is, so callers read `scope.singleton?` /
    # `scope.class_self?` (and `#inspect` shows the kind) rather than a raw flag.
    # Frames are values: a visibility change returns a new frame, never mutates.
    class Scope
      class << self
        # The frame for a namespace (class/module/anonymous/class_eval body).
        def root(fqn:, facts:)
          Namespace.new(fqn:, facts:, visibility: :public)
        end

        # The frame opened by a `def`: a class method when written `def self.x`
        # or when it sits directly inside a `class << self`, otherwise an
        # instance method. Inherits the enclosing namespace, facts, visibility.
        def method_for(parent, name:, on_self:)
          kind = on_self || parent&.class_self? ? SingletonMethod : InstanceMethod
          kind.new(fqn: parent&.fqn, facts: parent&.facts, visibility: parent&.visibility, method_name: name)
        end

        # A define_method block always defines an instance method.
        def define_method_for(parent, name:)
          InstanceMethod.new(fqn: parent.fqn, facts: parent.facts, visibility: parent.visibility, method_name: name)
        end

        # The frame opened by `class << self`, with a fresh public visibility.
        def singleton_class_for(parent)
          SingletonClass.new(fqn: parent.fqn, facts: parent.facts, visibility: :public)
        end
      end

      attr_reader :fqn, :facts, :visibility, :method_name

      def initialize(fqn:, facts:, visibility:, method_name: nil)
        @fqn = fqn
        @facts = facts
        @visibility = visibility
        @method_name = method_name
      end

      # Read by IndexBuilder and by the factories above, so both stay public.
      def singleton? = false
      def class_self? = false

      def with_visibility(new_visibility)
        self.class.new(fqn: fqn, facts: facts, visibility: new_visibility, method_name: method_name)
      end
    end

    # A class/module body: receiverless defs are instance methods.
    class Namespace < Scope
    end

    # An instance-method body: a `def x`, or a define_method block.
    class InstanceMethod < Scope
    end

    # A class-method body: a `def self.x`, or a `def` inside `class << self`.
    class SingletonMethod < Scope
      def singleton? = true
    end

    # A `class << self` region: its receiverless defs are class methods, and it
    # carries its own visibility so a `private` there cannot leak outward.
    class SingletonClass < Scope
      def singleton? = true
      def class_self? = true
    end
  end
end
