# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto Protocol::ZMTP::Connection to add fan-out
    # and encryption-query helpers.
    #
    module ConnectionExt
      # Writes pre-encoded wire bytes to the buffer without flushing.
      # Used for fan-out: encode once, write to many connections.
      #
      # @param wire_bytes [String] ZMTP wire-format bytes
      # @return [void]
      def write_wire(wire_bytes)
        @mutex.synchronize do
          @io.write(wire_bytes)
        end
      end

      # Returns true if the ZMTP mechanism encrypts at the frame level
      # (e.g. CURVE, BLAKE3ZMQ).
      #
      # @return [Boolean]
      def encrypted?
        @mechanism.encrypted?
      end
    end
  end
end
