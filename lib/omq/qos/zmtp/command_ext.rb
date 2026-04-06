# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto Protocol::ZMTP::Codec::Command's singleton class
    # to add ACK/NACK command builders.
    #
    module CommandClassExt
      # Builds an ACK command.
      #
      # @param hash_bytes [String] binary hash digest
      # @param algorithm [String] "x" (XXH64) or "s" (SHA-1 truncated)
      def ack(hash_bytes, algorithm: "x")
        new("ACK", "#{algorithm}#{hash_bytes}".b)
      end

      # Builds a NACK command.
      #
      # @param hash_bytes [String] binary hash digest
      # @param error [String] error description
      # @param algorithm [String] "x" (XXH64) or "s" (SHA-1 truncated)
      def nack(hash_bytes, error: "", algorithm: "x")
        new("NACK", "#{algorithm}#{hash_bytes}#{error}".b)
      end
    end

    # Prepended onto Protocol::ZMTP::Codec::Command to add
    # ACK/NACK data extraction methods.
    #
    module CommandExt
      # Extracts algorithm prefix and hash bytes from an ACK command's data.
      #
      # @return [Array(String, String)] [algorithm, hash_bytes]
      def ack_data
        algo      = @data.byteslice(0, 1)
        hash_size = Protocol::ZMTP::Codec::Command::ACK_HASH_SIZES.fetch(algo, 8)
        [algo, @data.byteslice(1, hash_size)]
      end

      # Extracts algorithm, hash bytes, and error info from a NACK command's data.
      #
      # @return [Array(String, String, String)] [algorithm, hash_bytes, error_info]
      def nack_data
        algo      = @data.byteslice(0, 1)
        hash_size = Protocol::ZMTP::Codec::Command::ACK_HASH_SIZES.fetch(algo, 8)
        hash      = @data.byteslice(1, hash_size)
        error     = @data.byteslice(1 + hash_size..) || "".b
        [algo, hash, error]
      end
    end
  end
end

# Known hash digest sizes by algorithm prefix.
Protocol::ZMTP::Codec::Command::ACK_HASH_SIZES = { "x" => 8, "s" => 8 }.freeze
