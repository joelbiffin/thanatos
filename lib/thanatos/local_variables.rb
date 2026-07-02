module Thanatos
  # Reports a local variable that is assigned but never read in its scope. This
  # is lexical and decidable (see docs/decidability.md): per scope we
  # diff writes against reads. We abstain on a scope that uses eval/binding
  # (the name could be read dynamically) and ignore _-prefixed names, which are
  # conventionally intentional. `depth` resolves a read/write to the scope that
  # owns the variable, so a closure reading an outer local counts as a use.
  class LocalVariables < Prism::Visitor
    DYNAMIC = %i[binding eval instance_eval class_eval module_eval].freeze

    Frame = Struct.new(:label, :writes, :reads, :dynamic)

    def initialize(file:)
      super()
      @file = file
      @frames = []
      @candidates = []
    end

    def candidates(node)
      visit(node)
      @candidates
    end

    def visit_def_node(node)
      with_frame(node.name.to_s) { super }
    end

    def visit_block_node(node)
      with_frame("(block)") { super }
    end

    def visit_lambda_node(node)
      with_frame("(lambda)") { super }
    end

    def visit_local_variable_write_node(node)
      record_write(node)
      super
    end

    def visit_local_variable_target_node(node)
      record_write(node)
      super
    end

    def visit_local_variable_read_node(node)
      record_read(node)
      super
    end

    def visit_local_variable_operator_write_node(node)
      record_read(node)
      super
    end

    def visit_local_variable_and_write_node(node)
      record_read(node)
      super
    end

    def visit_local_variable_or_write_node(node)
      record_read(node)
      super
    end

    def visit_call_node(node)
      @frames.last.dynamic = true if DYNAMIC.include?(node.name) && @frames.any?
      super
    end

    private

    def record_write(node)
      frame = @frames[-1 - node.depth]
      frame.writes[node.name] ||= location(node) if frame
    end

    def record_read(node)
      frame = @frames[-1 - node.depth]
      frame.reads << node.name if frame
    end

    def with_frame(label)
      @frames << Frame.new(label, {}, Set.new, false)
      yield
      frame = @frames.pop
      emit(frame) unless frame.dynamic
    end

    def emit(frame)
      frame.writes.each do |name, location|
        next if frame.reads.include?(name)
        next if name.to_s.start_with?("_")

        @candidates << Candidate.new(
          fqn: frame.label,
          name: name,
          visibility: :local,
          location: location,
          confidence: :high,
          reasons: []
        )
      end
    end

    def location(node)
      "#{@file}:#{node.location.start_line}"
    end
  end
end
