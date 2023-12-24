require 'faraday'
require 'tree'
require 'digest'

module ParallelReportPortal
  module Cucumber
    # Report object. This handles the management of the state hierarchy and
    # the issuing of the requests to the HTTP module. 
    class Report

      attr_reader :launch_id

      Feature = Struct.new(:feature, :id)

      LOG_LEVELS = {
        error: 'ERROR',
        warn: 'WARN',
        info: 'INFO',
        debug: 'DEBUG',
        trace: 'TRACE',
        fatal: 'FATAL',
        unknown: 'UNKNOWN'
      }


      # Create a new instance of the report
      def initialize(ast_lookup = nil)
        @feature = nil
        @tree = Tree::TreeNode.new( 'root' )
        @ast_lookup = ast_lookup
        ParallelReportPortal.set_debug_level
      end

      # Issued to start a launch. It is possilbe that this method could be called
      # from multiple processes for the same launch if this is being run with
      # parallel tests enabled. A temporary launch file will be created (using
      # exclusive locking). The first time this method is called it will write the
      # launch id to the launch file, subsequent calls by other processes will read
      # this launch id and use that.
      # 
      # @param start_time [Integer] the millis from the epoch 
      # @return [String] the UUID of this launch
      def launch_started(start_time)
        ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.launch_id_file, 'a+' ) do |file|
          if file.size == 0
            @launch_id = ParallelReportPortal.configuration.output_type == 'rp' ? ParallelReportPortal.req_launch_started(start_time) : 9999
            file.write(@launch_id)
            file.flush
          else
            @launch_id = file.readline
          end
          @launch_id
        end
      end

      # Called to finish a launch. Any open children items will be closed in the process.
      # 
      # @param clock [Integer] the millis from the epoch
      def launch_finished(clock)
        @tree.postordered_each do |node|
          ParallelReportPortal.req_feature_finished(node.content, clock) if ParallelReportPortal.configuration.output_type == 'rp' and !node.is_root?
        end
        ParallelReportPortal.req_launch_finished(launch_id, clock) unless ParallelReportPortal.configuration.output_type != 'rp'
      end

      # Called to indicate that a feature has started.
      # 
      # @param 
      def feature_started(feature, clock)

        if ParallelReportPortal.configuration.output_type == 'rp'
          parent_id = hierarchy(feature, clock)
          feature = feature.feature if using_cucumber_messages?
          ParallelReportPortal.req_feature_started(launch_id, parent_id, feature, clock)
        end
      end

      def feature_finished(clock)
        if @feature and ParallelReportPortal.configuration.output_type == 'rp'
          resp = ParallelReportPortal.req_feature_finished(@feature.id, clock)
        end
      end

      def test_case_started(event, clock)
        uuid, test_case = lookup_test_case(event.test_case)
        feature = lookup_feature(event.test_case)

        if ParallelReportPortal.configuration.output_type == 'rp'
          feature = current_feature(feature, clock)
          @test_case_id = ParallelReportPortal.req_test_case_started(launch_id, feature.id, test_case, clock, uuid)
        else
          ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.hierarchy_file, 'a+b' ) do |file|
            @tree = Marshal.load(File.read(file)) if file.size > 0
            root_node = @tree.root

            feature_node = look_up_node_in_tree(generate_id_for_feature(feature))

            if feature_node.nil? or (feature_node.is_a? Array and feature_node.empty?)
              feature_node = Tree::TreeNode.new(
                name= generate_id_for_feature(feature),
                content= {
                  unique_id: generate_id_for_feature(feature),
                  type: "Feature",
                  name:feature.uri
                }
              )
              root_node.add(feature_node, -1)
            end

            is_outline = test_case.keyword.upcase.include? "OUTLINE"

            new_node = look_up_node_in_tree(generate_id_for_scenario(test_case))
            is_already_added = new_node.instance_of? Tree::TreeNode
            unless is_already_added
              new_node = Tree::TreeNode.new(
                name= generate_id_for_scenario(test_case),
                content= {
                  unique_id: generate_id_for_scenario(test_case),
                  type: is_outline ? "TestCaseWithExamples" : "TestCase",
                  name:test_case.name
                }
              )
            end

            if is_outline and not is_already_added
              test_case.examples.each do |example|
                example.table_body.each do |row|
                  example_node = new_node.add(
                    Tree::TreeNode.new(
                      name= generate_id(feature.uri + row.location.line.to_s),
                      content= {
                        type: "Example",
                        values: row.cells.map(&:value)
                      }), -1
                  )

                  test_case.steps.each do |step|
                    example_node.add(
                        Tree::TreeNode.new(
                          name= generate_id_for_step(feature.uri, row.location.line.to_s + step.location.line.to_s), #need these attributes to make it unique and be traceable for both Core and Message classes
                          content= {
                            unique_id: step.id,
                            type: "TestStep",
                            name: step.text
                          }), -1
                      )
                    end
                  end
              end
            elsif is_outline and is_already_added #Is a retry, do nothing
            else
              test_case.steps.each do |step|
                new_node.add(
                  Tree::TreeNode.new(
                  name= generate_id_for_step(feature.uri, step.location.line.to_s), #need these attributes to make it unique and be traceable for both Core and Message classes, locatiuon is step line + used example line
                  content= {
                    unique_id: step.id,
                    type: "TestStep",
                    name: step.text
                  }), -1
                )
              end
            end

            unless is_outline and is_already_added #do nothing, it's already added by a previous example
              if feature_node and not is_already_added
                feature_node.add(new_node, -1)
              else
                #Orphan test case?
                root_node.add(new_node, -1)
              end
            end

            file.truncate(0)
            file.write(Marshal.dump(@tree))
            file.flush
          end
        end
      end

      def test_case_finished(event, clock)
        result = event.result
        status = result.to_sym
        failure_message = nil
        if [:undefined, :pending].include?(status)
          status = :failed
          failure_message = result.message
        end

        if ParallelReportPortal.configuration.output_type == 'rp'
          resp = ParallelReportPortal.req_test_case_finished(@test_case_id, status, clock)
        else
          ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.hierarchy_file, 'a+b' ) do |file|
            @tree = Marshal.load(File.read(file)) if file.size > 0
            root_node = @tree.root
            uuid, test_case = lookup_test_case(event.test_case)

            scenario_tree_name = generate_id_for_scenario(test_case)
            test_case_tree_node = look_up_node_in_tree(scenario_tree_name)


            test_case_tree_node.content = {
              unique_id: scenario_tree_name,
              type: test_case_tree_node.content[:type],
              name: test_case_tree_node.content[:name],
              result: event.result,
              status: status,
              failure_message: failure_message
            }

            file.truncate(0)
            file.write(Marshal.dump(@tree))
            file.flush
          end
        end
      end

      def test_step_started(event, clock)
        test_step = event.test_step
        if !hook?(test_step)
          step_source = lookup_step_source(test_step)
          detail = "#{step_source.keyword} #{step_source.text}"
          if (using_cucumber_messages? ? test_step : step_source).multiline_arg.doc_string?
            detail << %(\n"""\n#{(using_cucumber_messages? ? test_step : step_source).multiline_arg.content}\n""")
          elsif (using_cucumber_messages? ? test_step : step_source).multiline_arg.data_table?
            detail << (using_cucumber_messages? ? test_step : step_source).multiline_arg.raw.reduce("\n") {|acc, row| acc << "| #{row.join(' | ')} |\n"}
          end

          if ParallelReportPortal.configuration.output_type == 'rp'
            ParallelReportPortal.req_log(@test_case_id, detail, status_to_level(:trace), clock)
          end
        end
      end

      def test_step_finished(event, clock)
        test_step = event.test_step
        result = event.result
        status = result.to_sym
        detail = nil
        if [:failed, :pending, :undefined].include?(status)
          if [:failed, :pending].include?(status)
            ex = result.exception
            detail = sprintf("%s: %s\n  %s", ex.class.name, ex.message, ex.backtrace.join("\n  "))
          elsif !hook?(test_step)
            step_source = lookup_step_source(test_step)
            begin
              back_line = step_source.source.last.backtrace_line
            rescue NoMethodError
              back_line = ""
            end
            detail = sprintf("Undefined step: #{step_source.text}:\n#{back_line}")
          end
        elsif !hook?(test_step)
          step_source = lookup_step_source(test_step)
          detail = "#{step_source.keyword} #{test_step}"
        end

        if detail and ParallelReportPortal.configuration.output_type == 'rp'
          ParallelReportPortal.req_log(@test_case_id, detail, status_to_level(status), clock)
        elsif !hook?(test_step)
          ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.hierarchy_file, 'a+b' ) do |file|
            @tree = Marshal.load(File.read(file)) if file.size > 0
            root_node = @tree.root

            if test_step.location.lines.to_s.include? ":" #meaning it has 2 line reference the example and the actual line where the step is
              lines = test_step.location.lines.to_s.split(":")
              step_node = look_up_node_in_tree(generate_id_for_step(test_step.location.file, lines[0].to_s + lines[1].to_s))
            else
              step_node = look_up_node_in_tree(generate_id_for_step(test_step.location.file, test_step.location.line.to_s))
            end

            step_node.content.merge!({
                                       result:result,
                                       status:status,
                                       detail: detail
                                     })

            file.truncate(0)
            file.write(Marshal.dump(@tree))
            file.flush
          end
        end
      end

      private

      def using_cucumber_messages?
        @ast_lookup != nil
      end

      def hierarchy(feature, clock)
        node = nil
        path_components = if using_cucumber_messages?
                            feature.uri.split(File::SEPARATOR)
                          else
                            feature.location.file.split(File::SEPARATOR)
                          end
        ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.hierarchy_file, 'a+b' ) do |file|
          @tree = Marshal.load(File.read(file)) if file.size > 0
          node = @tree.root
          path_components[0..-2].each do |component|
            next_node = node[component]
            unless next_node
              id = ParallelReportPortal.req_hierarchy(launch_id, "Folder: #{component}", node.content, 'SUITE', [], nil, clock )
              next_node = Tree::TreeNode.new(component, id)
              node << next_node
              node = next_node
            else
              node = next_node
            end
          end
          file.truncate(0)
          file.write(Marshal.dump(@tree))
          file.flush
        end

        node.content
      end

      def lookup_feature(test_case)
        if using_cucumber_messages?
          @ast_lookup.gherkin_document(test_case.location.file)
        else
          test_case.feature
        end
      end

      def lookup_test_case(test_case)
        if using_cucumber_messages?
          sc = @ast_lookup.scenario_source(test_case)
          if sc.respond_to?(:scenario)
            [nil, @ast_lookup.scenario_source(test_case).scenario]
          else
            [generate_id_for_scenario_example(test_case), @ast_lookup.scenario_source(test_case).scenario_outline]
          end
        else
          [nil, test_case]
        end
      end

      def lookup_step_source(step)
        if using_cucumber_messages?
          @ast_lookup.step_source(step).step
        else
          step.source.last
        end
      end

      def current_feature(feature, clock)
        if @feature&.feature == feature
          @feature
        else
          feature_finished(clock)
          @feature = Feature.new(feature, feature_started(feature, clock))
        end
      end

      def hook?(test_step)
        if using_cucumber_messages?
          test_step.hook?
        else
          ! test_step.source.last.respond_to?(:keyword)
        end
      end

      def status_to_level(status)
        case status
        when :passed
          LOG_LEVELS[:info]
        when :failed, :undefined, :pending, :error
          LOG_LEVELS[:error]
        when :skipped
          LOG_LEVELS[:warn]
        else
          LOG_LEVELS.fetch(status, LOG_LEVELS[:info])
        end
      end


      def generate_id_for_feature(feature)
        feature_as_text = feature.uri + feature.feature.location.line.to_s + feature.feature.location.column.to_s
        Digest::SHA1.hexdigest(feature_as_text)
      end

      def generate_id_for_scenario(test_case)
        scenario_as_txt = test_case.name + test_case.location.line.to_s + test_case.location.column.to_s +  test_case.steps.map(&:text).join('. ')
        return Digest::SHA1.hexdigest(scenario_as_txt)
      end

      def generate_id_for_scenario_example(test_case)
        steps_as_txt = test_case.test_steps.map(&:text).join('. ')
        generate_id(steps_as_txt)
      end

      def generate_id(txt)
        Digest::SHA1.hexdigest(txt)
      end

      def generate_id_for_step(feature_file_as_string, feature_file_line_location)
        step_as_txt = feature_file_as_string + feature_file_line_location
        generate_id(step_as_txt)
      end

      def look_up_node_in_tree(unique_id)
        return nil unless @tree.root.children?
        to_discover = @tree.root.children

        until to_discover.empty?
          node = to_discover.shift
          if node.name == unique_id
            return node
          else
            (to_discover << node.children).flatten!
          end
        end

        to_discover
      end

    end
  end
end