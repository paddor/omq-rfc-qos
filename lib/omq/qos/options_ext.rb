# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto OMQ::Options to add the +qos_hash+ attribute.
    #
    module OptionsExt
      def initialize(**kwargs)
        super
        @qos_hash = OMQ::QoS::SUPPORTED_HASH_ALGOS
      end
    end
  end
end

OMQ::Options.prepend(OMQ::QoS::OptionsExt)
OMQ::Options.attr_accessor :qos_hash
