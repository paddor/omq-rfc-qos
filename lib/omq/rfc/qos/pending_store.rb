# frozen_string_literal: true

module OMQ
  module QoS
    # Tracks sent-but-unacknowledged messages for QoS >= 1.
    #
    # Keyed by 8-byte XXH3 digest of the raw ZMTP wire bytes.
    #
    class PendingStore
      Entry = Data.define(:parts, :connection, :sent_at)

      # Creates a new empty pending store.
      def initialize
        @entries = {}
      end


      # Registers a message as pending.
      #
      # @param hash [String] 8-byte digest
      # @param parts [Array<String>] frozen message frames
      # @param connection [Connection] the connection it was sent on
      #
      def track(hash, parts, connection)
        @entries[hash] = Entry.new(
          parts:      parts,
          connection: connection,
          sent_at:    Process.clock_gettime(Process::CLOCK_MONOTONIC),
        )
      end


      # Acknowledges a message. Returns the entry or nil if unknown.
      #
      # @param hash [String] 8-byte digest
      # @return [Entry, nil]
      #
      def ack(hash)
        @entries.delete(hash)
      end


      # Returns and removes all pending entries for a connection.
      #
      # @param connection [Connection]
      # @return [Array<Entry>]
      #
      def messages_for(connection)
        removed = []
        @entries.delete_if do |_hash, entry|
          if entry.connection.equal?(connection)
            removed << entry
            true
          end
        end
        removed
      end


      # @return [Integer] number of pending messages
      #
      def size
        @entries.size
      end


      # @return [Boolean]
      #
      def empty?
        @entries.empty?
      end
    end
  end
end
