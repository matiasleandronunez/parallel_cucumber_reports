require "parallel_report_portal/clock"
require "parallel_report_portal/configuration"
require "parallel_report_portal/file_utils"
require "parallel_report_portal/http"
require "parallel_report_portal/version"
require 'parallel_tests'
require 'fileutils'

module ParallelReportPortal
  class Error < StandardError; end

  extend ParallelReportPortal::HTTP
  extend ParallelReportPortal::FileUtils
  extend ParallelReportPortal::Clock

  # Returns the configuration object, initializing it if necessary.
  # 
  # @return [Configuration] the configuration object
  def self.configuration
    @configuration ||= Configuration.new
  end

  # Configures the Report Portal environment.
  # 
  # @yieldparam [Configuration] config the configuration object yielded to the block
  def self.configure(&block)
    yield configuration
  end

  at_exit do
    if ParallelReportPortal.parallel?
      if ParallelTests.first_process?
        ParallelTests.wait_for_other_processes_to_finish
        ParallelReportPortal.file_open_exlock_and_block(ParallelReportPortal.launch_id_file, 'r') do |file|
          launch_id = file.readline
          launch_info = ParallelReportPortal.req_launch_info(launch_id) if configuration.output_type == 'rp'

          if launch_info
            launch_info['uri'] = "#{configuration.endpoint.gsub("api/v1", "ui")}/##{configuration.project}/launches/all/#{launch_info['id']}/"
            begin
              File.open(configuration.tempfile, "w") { |f| f.write launch_info.to_s.gsub("=>", ":").gsub("nil","null") }
            rescue Errno::ENOENT
            end

            puts "\n----------------------------------------\n"
            puts "Execution completed, find the report at: \n"
            puts "\n#{launch_info['uri']}"
            puts "\n----------------------------------------\nSummary:\n"
          end
        end
        delete_file(launch_id_file)
        delete_file(hierarchy_file)
      end
    else
      delete_file(launch_id_file)
      delete_file(hierarchy_file)
    end
  end
end
