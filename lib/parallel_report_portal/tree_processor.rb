require 'tree'

module ParallelReportPortal
  class TreeProcessor
    def initialize(hierarchy_tree)
      @tree = hierarchy_tree
    end

    def results_hash
      return @tree.to_h
    end

    def execution_summary
      root_node = @tree.root
      results = {:passed => 0, :failed => 0, :skipped => 0, :pending => 0, :other => 0}

      #depth-first and L-to-R pre-ordered traversal
      root_node.each do |node|
        next if node.name == "root" or node.content[:type] == "TestStep" or node.content[:type] == "Feature"
        if node.content[:type] == "TestCase"
          case node.content[:result].to_s
          when "P"
            results[:pending] += 1
          end
        elsif node.content[:type] == "TestCaseWithExamples"
          node.children.select { |x| x.content[:type] == "Example"}.each do |example|
            steps_status = example.children.map{|x| x.content[:status]}
            if steps_status.all? {|s| s == :passed}
              example.content.merge!(status: :passed)
              results[:passed] += 1
            elsif steps_status.any? {|s| s == :failed}
              example.content.merge!(status: :failed)
              results[:failed] += 1
            elsif steps_status.all? {|s| s == :passed or s == :skipped}
              example.content.merge!(status: :skipped)
              results[:skipped] += 1
            elsif steps_status.all? {|s| s == :passed or s == :pending or s == :skipped}
              example.content.merge!(status: :pending)
              results[:pending] += 1
            else
              example.content.merge!(status: :other)
              results[:other] += 1
            end
          end
        end
      end

      results
    end
  end

  class ConsoleProcessor < TreeProcessor
    def initialize(hierarchy_tree)
      super
    end
  end
end
