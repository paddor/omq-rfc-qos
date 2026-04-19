# frozen_string_literal: true

module OMQ
  module QoS
    # Adds the +qos+ and +qos_hash+ accessors to {OMQ::Socket}, with a
    # validating setter for +qos+ that rejects fan-out socket types per
    # the RFC: at-least-once is meaningless for fan-out, so PUB/SUB,
    # XPUB/XSUB, and RADIO/DISH MUST refuse any QoS level above 0.
    #
    module SocketExt
      FAN_OUT_TYPES = %i[PUB XPUB RADIO SUB XSUB DISH].freeze


      def qos
        @options.qos
      end


      def qos=(level)
        if level > 0 && FAN_OUT_TYPES.include?(@engine.socket_type)
          raise ArgumentError,
                "QoS > 0 is not supported for fan-out socket type #{@engine.socket_type}; " \
                "use a broker (e.g. Malamute) for reliable fan-out"
        end
        @options.qos = level
      end


      def qos_hash
        @options.qos_hash
      end


      def qos_hash=(value)
        @options.qos_hash = value
      end
    end
  end
end


OMQ::Socket.include(OMQ::QoS::SocketExt)
