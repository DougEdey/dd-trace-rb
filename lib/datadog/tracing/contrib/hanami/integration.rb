# typed: ignore

require_relative '../integration'
require_relative 'configuration/settings'
require_relative 'patcher'

module Datadog
  module Tracing
    module Contrib
      module Hanami
        # Description of Hanami integration
        class Integration
          include Contrib::Integration

          MINIMUM_VERSION = Gem::Version.new('1.0.0')
          MAXIMUM_VERSION = Gem::Version.new('2.0.0')

          register_as :hanami

          def self.version
            Gem.loaded_specs['hanami'] && Gem.loaded_specs['hanami'].version
          end

          def self.loaded?
            !defined?(::Hanami).nil?
          end

          def self.compatible?
            # Tested with version larger than 1.x, but not 2.x version
            super && version >= MINIMUM_VERSION && version < MAXIMUM_VERSION
          end

          def new_configuration
            Configuration::Settings.new
          end

          def patcher
            Patcher
          end
        end
      end
    end
  end
end
