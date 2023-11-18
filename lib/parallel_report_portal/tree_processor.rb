require 'tree'

module ParallelReportPortal
  class TreeProcessor
    def initialize(hierarchy_tree)
      @tree = hierarchy_tree
    end

    def results_hash

    end
  end

  class ConsoleProcessor < TreeProcessor
    def initialize(hierarchy_tree)
      super
    end


  end
end
