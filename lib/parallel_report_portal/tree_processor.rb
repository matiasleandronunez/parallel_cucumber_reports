require 'tree'
require 'colorize'

module ParallelReportPortal
  class TreeProcessor
    def initialize(hierarchy_tree)
      @tree = hierarchy_tree
    end

    def results_hash
      return @tree.to_h
    end

    def collect_tree_information
      root_node = @tree.root
      results = {:passed => [], :failed => [], :skipped => [], :pending => [], :other => []}

      #depth-first and L-to-R pre-ordered traversal
      root_node.each do |node|
        next if node.name == "root" or node.content[:type] == "TestStep" or node.content[:type] == "Feature"
        if node.content[:type] == "TestCase"
          case node.content[:result].to_s
          when "P"
            results[:pending].append(node.content)
          when "✓"
            results[:passed].append(node.content)
          when "✗"
            results[:failed].append(node.content)
          when "S"
            results[:skipped].append(node.content)
          else
            results[:other].append(node.content)
          end
        elsif node.content[:type] == "TestCaseWithExamples"
          node.children.select { |x| x.content[:type] == "Example"}.each do |example|
            steps_status = example.children.map{|x| x.content[:status]}
            if steps_status.all? {|s| s == :passed}
              example.content.merge!(status: :passed, :name => node.content[:name])
              results[:passed].append(example.content)
            elsif steps_status.any? {|s| s == :failed}
              example.content.merge!(status: :failed, :name => node.content[:name], :steps => example.children.map{|e| {:name => e.content[:name],:detail=> e.content[:detail], :status => e.content[:status]}})
              results[:failed].append(example.content)
            elsif steps_status.all? {|s| s == :passed or s == :skipped}
              example.content.merge!(status: :skipped)
              results[:skipped].append(example.content)
            elsif steps_status.all? {|s| s == :passed or s == :pending or s == :skipped}
              example.content.merge!(status: :pending)
              results[:pending].append(example.content)
            else
              example.content.merge!(status: :other)
              results[:other].append(example.content)
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

    def results_as_string
      results = self.collect_tree_information
      if results[:failed].size > 0
        failed_scenarios = ''
        results[:failed].each do |failed_scenario|
          failed_scenarios += "#{failed_scenario[:name]}\n".red
        end
      end
      "Scenarios Executed:#{results.map{|k,v| v.size}.sum.to_s} \nPassed: #{results[:passed].size.to_s}\nFailed: #{results[:failed].size.to_s}\nSkipped: #{results[:skipped].size.to_s}\nPending: #{results[:pending].size.to_s}\nOther: #{results[:other].size.to_s}\n" + failed_scenarios
    end

    def detailed_results_as_string
      def get_detail(content_array)
        detail_s=""
        content_array.each do |content_item|
          detail_s+="  #{content_item[:name]}#{content_item[:type] == 'Example' ? content_item[:values].to_s : ''}\n"
          if content_item[:status] == :failed
            content_item[:steps].each do |step|
              case step[:status]
              when :passed
                detail_s+="    #{step[:name]}\n".green
              when :pending
                detail_s+="    #{step[:name]}\n".yellow
              when :skipped
                detail_s+="    #{step[:name]}\n".light_blue
              when :other
                detail_s+="    #{step[:name]}\n".magenta
              when :failed
                detail_s+="    #{step[:name]}\n#{step[:detail]}\n".red
              end
            end
          end
        end
        detail_s
      end

      results = self.collect_tree_information

      "Scenarios Executed:#{results.map{|k,v| v.size}.sum.to_s}\nPassed: #{results[:passed].size.to_s}\n#{get_detail(results[:passed]).green}\nFailed: #{results[:failed].size.to_s}\n#{get_detail(results[:failed]).red}\nSkipped: #{results[:skipped].size.to_s}\n#{get_detail(results[:skipped]).light_blue}\nPending: #{results[:pending].size.to_s}\n#{get_detail(results[:pending]).yellow}\nOther: #{results[:other].size.to_s}\n#{get_detail(results[:other]).magenta}"
    end
  end
end
