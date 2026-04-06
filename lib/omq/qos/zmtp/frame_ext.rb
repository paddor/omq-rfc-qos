# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto Protocol::ZMTP::Codec::Frame's singleton class
    # to add multi-part message encoding.
    #
    module FrameExt
      # Encodes a multi-part message into a single wire-format string.
      # The result can be written to multiple connections without
      # re-encoding each time (useful for fan-out patterns like PUB).
      #
      # @param parts [Array<String>] message frames
      # @return [String] frozen binary wire representation
      #
      def encode_message(parts)
        buf = +""
        parts.each_with_index do |part, i|
          buf << new(part, more: i < parts.size - 1).to_wire
        end
        buf.freeze
      end
    end
  end
end
