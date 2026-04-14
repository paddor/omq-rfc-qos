# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto Protocol::ZMTP::Connection so that command frames
    # received during a normal {Connection#receive_message} loop are
    # dispatched to a per-connection QoS handler. Without this, ACK
    # commands sent by the peer would be silently dropped by the recv
    # pump (which skips command frames).
    #
    module ConnectionExt
      attr_accessor :qos_on_command


      def receive_message(&block)
        handler = @qos_on_command
        return super unless handler

        super() do |frame|
          cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)
          handler.call(cmd)
          block&.call(frame)
        end
      end

    end
  end
end


Protocol::ZMTP::Connection.prepend(OMQ::QoS::ConnectionExt)
