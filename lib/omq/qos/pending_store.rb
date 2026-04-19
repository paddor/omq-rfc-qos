# frozen_string_literal: true

require "async/notification"

module OMQ
  module QoS
    # Tracks sent-but-unacknowledged messages for QoS >= 1.
    #
    # Keyed by 8-byte XXH3 digest of the raw ZMTP wire bytes.
    #
    # Bounded: the store caps at a configurable size (typically the
    # socket's `send_hwm`). When full, {#wait_for_slot} suspends the
    # calling fiber until an ACK or connection-loss requeue frees a
    # slot, giving the QoS path the same backpressure semantics that
    # the send queue has at QoS 0.
    #
    class PendingStore
      Entry = Data.define(:parts, :connection, :sent_at)

      # Creates a new empty pending store.
      #
      # @param capacity [Integer] max pending entries before senders block
      #
      def initialize(capacity:)
        @entries  = {}
        @capacity = capacity
        @drained  = Async::Notification.new
      end


      # Blocks until the store has fewer than `capacity` entries.
      #
      # Must be called from an Async fiber. Signaled on every
      # successful {#ack} and whenever {#messages_for} drains
      # entries on connection loss.
      #
      def wait_for_slot
        while @entries.size >= @capacity
          @drained.wait
        end
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
        entry = @entries.delete(hash)
        @drained.signal if entry
        entry
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
        @drained.signal unless removed.empty?
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
