require 'logger'
require 'tempfile'

module ParallelReportPortal
  # A collection of methods for communicating with the ReportPortal 
  # REST interface.
  module HTTP

    # Creating class level logger and setting log level
    @@logger = Logger.new(STDOUT)

    def set_debug_level
      @@logger.level = case ParallelReportPortal.configuration.verbose
                       when 0, '0', nil
                         Logger::ERROR
                       when 2, '2'
                         Logger::DEBUG
                       else
                         Logger::INFO
      end
    end
    # Construct the Report Portal project URL (as a string) based
    # on the config settings.

    # @return [String] URL the report portal base URL
    def url
      "#{ParallelReportPortal.configuration.endpoint}/#{ParallelReportPortal.configuration.project}"
    end

    # Helper method for constructing the +Bearer+ header
    # 
    # @return [String] header the bearer header value
    def authorization_header
      "Bearer #{ParallelReportPortal.configuration.uuid}"
    end

    # Get a preconstructed Faraday HTTP connection
    # which has the endpont and headers ready populated.
    # This object is memoized.
    # 
    # @return [Faraday::Connection] connection the HTTP connection object
    def http_connection
      @http_connection ||= Faraday.new(
        url: url,
        headers: {
          'Content-Type' => 'application/json',
          'Authorization' => authorization_header
        }
      ) do |f|
        f.adapter :net_http_persistent, pool_size: 5 do |http|
          http.idle_timeout = ParallelReportPortal.configuration.fetch(:idle_timeout, 100)
          http.open_timeout = ParallelReportPortal.configuration.fetch(:open_timeout, 60)
          http.read_timeout = ParallelReportPortal.configuration.fetch(:read_timeout, 60)
        end
      end
    end

    # Get a preconstructed Faraday HTTP multipart connection
    # which has the endpont and headers ready populated.
    # This object is memoized.
    # 
    # @return [Faraday::Connection] connection the HTTP connection object
    def http_multipart_connection
      @http_multipart_connection ||= Faraday.new(
        url: url,
        headers: {
          'Authorization' => authorization_header
        }
      ) do |conn|
        conn.request :multipart
        conn.request :url_encoded
        conn.adapter :net_http_persistent, pool_size: 5 do |http|
          # yields Net::HTTP::Persistent
          http.idle_timeout = ParallelReportPortal.configuration.fetch(:idle_timeout, 100)
          http.open_timeout = ParallelReportPortal.configuration.fetch(:open_timeout, 60)
          http.read_timeout = ParallelReportPortal.configuration.fetch(:read_timeout, 60)
        end
      end
    end

    # Send a request to ReportPortal to start a launch.
    # It will bubble up any Faraday connection exceptions.
    def req_launch_started(time)
      resp = http_connection.post('launch') do |req|
              req.body = {
                name: ParallelReportPortal.configuration.launch, 
                start_time: time, 
                tags: ParallelReportPortal.configuration.tags, 
                description: ParallelReportPortal.configuration.description, 
                mode: (ParallelReportPortal.configuration.debug ? 'DEBUG' : 'DEFAULT' ),
                attributes: ParallelReportPortal.configuration.attributes
              }.to_json
            end
      if resp.success?
        @@logger.info("HTTP200 | Launch started")
        @@logger.debug("Launch name"" #{ParallelReportPortal.configuration.launch}\nTags: #{ParallelReportPortal.configuration.tags}\nDescription: #{ParallelReportPortal.configuration.description}\nMode: #{ParallelReportPortal.configuration.debug}\nAttributes: #{ParallelReportPortal.configuration.attributes}")
        JSON.parse(resp.body)['id']
      else
        @@logger.error("Launch failed with response code #{resp.status} -- message #{resp.body}")
      end
    end
    
    # Send a request to Report Portal to finish a launch.
    # It will bubble up any Faraday connection exceptions.
    def req_launch_finished(launch_id, time)
      resp = ParallelReportPortal.http_connection.put("launch/#{launch_id}/finish") do |req|
        req.body = { end_time: time }.to_json
      end
      @@logger.info("HTTP200 | Launch finished #{launch_id}") if resp.success?
      resp
    end
    
    # Send a request to ReportPortal to start a feature.
    # It will bubble up any Faraday connection exceptions.
    # 
    # @return [String] id the UUID of the feature
    def req_feature_started(launch_id, parent_id, feature, time)
      description = if feature.description
                      feature.description.split("\n").map(&:strip).join(' ')
                    else
                      feature.file
                    end

        req_hierarchy(launch_id,
                      "#{feature.keyword}: #{feature.name}",
                      parent_id,
                      'TEST',
                      feature.tags.map(&:name),
                      description,
                      time )
    end
    
    # Sends a request to Report Portal to add an item into its hierarchy.
    # 
    # @return [String] uuid the UUID of the newly created child
    def req_hierarchy(launch_id, name, parent, type, tags, description, time )
      resource = 'item'
      resource += "/#{parent}" if parent
      resp = ParallelReportPortal.http_connection.post(resource) do |req|
        req.body = {
          start_time: time,
          name: name,
          type: type,
          launch_id: launch_id,
          tags: tags,
          description: description,
          attributes: tags
        }.to_json
      end
      
      if resp.success?
        @@logger.info("HTTP200 | Added item hierarchy #{type}")
        @@logger.debug("Parent: #{parent}\nName: #{name}\nTags: #{tags}")
        JSON.parse(resp.body)['id']
      else
        @@logger.warn("Starting a heirarchy failed with response code #{resp.status} -- message #{resp.body}")
      end
    end
  
    # Send a request to Report Portal that a feature has completed.
    def req_feature_finished(feature_id, time)
      resp = ParallelReportPortal.http_connection.put("item/#{feature_id}") do |req|
        req.body = { end_time: time }.to_json
      end
      @@logger.info("HTTP200 | Feature finished #{feature_id}") if resp.success?
      resp
    end
  
    # Send a request to ReportPortal to start a test case.
    # 
    # @return [String] uuid the UUID of the test case
    def req_test_case_started(launch_id, feature_id, test_case, time, uuid = nil)
      resp = ParallelReportPortal.http_connection.post("item/#{feature_id}") do |req|

        keyword = if test_case.respond_to?(:feature)
                    test_case.feature.keyword
                  else
                    test_case.keyword
                  end

        req.body = if uuid
                     {
                       uniqueId: uuid,
                       start_time: time,
                       tags: test_case.tags.map(&:name),
                       name: "#{keyword}: #{test_case.name}",
                       type: 'STEP',
                       launch_id: launch_id,
                       description: test_case.description,
                       attributes: test_case.tags.map(&:name),
                       retry: true
                     }.to_json
                   else
                     {
                       start_time: time,
                       tags: test_case.tags.map(&:name),
                       name: "#{keyword}: #{test_case.name}",
                       type: 'STEP',
                       launch_id: launch_id,
                       description: test_case.description,
                       attributes: test_case.tags.map(&:name),
                       retry: true
                     }.to_json
                   end
      end
      if resp.success?
        @test_case_id = JSON.parse(resp.body)['id']
        @@logger.info("HTTP200 | Test case started #{@test_case_id}")
        @@logger.debug("Feature ID: #{feature_id}\nName: #{test_case.name}\n Attributes/Tags: #{test_case.tags.map(&:name)}")
        begin
          #@@logger.warn(test_case.iteration_value) if test_case.name == '[3198] Prices in PDP should be available in the correct currency depending on the region'
        rescue NoMethodError
        end
        @test_case_id
      else
        @@logger.warn("Starting a test case failed with response code #{resp.status} -- message #{resp.body}")
      end
    end
    
    # Request that the test case be finished
    def req_test_case_finished(test_case_id, status, time)
      resp = ParallelReportPortal.http_connection.put("item/#{test_case_id}") do |req|
        req.body = {
          end_time: time,
          status: status
        }.to_json
      end
      @@logger.info("HTTP200 | Test case finished #{@test_case_id}") if resp.success?
      resp
    end
    
    
    # Request that Report Portal records a log record
    def req_log(test_case_id, detail, level, time)
      resp = ParallelReportPortal.http_connection.post('log') do |req|
        req.body = {
          item_id: test_case_id,
          message: detail,
          level: level,
          time: time,
        }.to_json
      end
      @@logger.debug("HTTP200 | Log posted for test case #{test_case_id}") if resp.success?
      resp
    end


    # Request that Report Portal attach a file to the test case.
    # 
    # @param status [String] the status level of the log, e.g. info, warn
    # @param path [String] the fully qualified path of the file to attach
    # @param label [String] a label to add to the attachment, defaults to the filename
    # @param time [Integer] the time in milliseconds for the attachment
    # @param mime_type [String] the mimetype of the attachment
    def send_file(status, path, label = nil, time = ParallelReportPortal.clock, mime_type = 'image/png')
      File.open(File.realpath(path), 'rb') do |file|
        label ||= File.basename(file)

        # where did @test_case_id come from? ok, I know where it came from but this 
        # really should be factored out of here and state handled better
        json = { level: status, message: label, item_id: @test_case_id, time: time, file: { name: File.basename(file) } }

        json_file = Tempfile.new
        json_file << [json].to_json
        json_file.rewind

        resp = http_multipart_connection.post("log") do |req|
          req.body = {
            json_request_part: Faraday::UploadIO.new(json_file, 'application/json'),
            file: Faraday::UploadIO.new(file, mime_type)
          }
        end
        @@logger.info("HTTP200 | File attached to Test case #{@test_case_id}") if resp.success?
        resp
      end
    end

    # Requests Report Portal a launch
    #
    # @param uuid [string] UUID of the launch to get
    def req_launch_info(uuid)
      resp = ParallelReportPortal.http_connection.get("launch/uuid/#{uuid}")

      if resp.success?
        JSON.parse(resp.body)
      else
        @@logger.error("Failed fetching information for report #{uuid}")
      end
    end
  end
end
