# frozen_string_literal: true

module OMQ
  module QoS
    # Installs an ACK command handler on a connection's QoS hook.
    # The installed callback reaches into +pending_store+ to delete
    # the entry keyed by the 8-byte digest embedded in the ACK.
    #
    # @param conn [Protocol::ZMTP::Connection]
    # @param pending_store [PendingStore]
    # @return [void]
    #
    def self.install_command_handler(conn, pending_store)
      conn.qos_on_command = lambda do |cmd|
        next unless cmd.name == "ACK"
        _, hash = cmd.ack_data
        pending_store.ack(hash)
      end
    end


    # Inproc Pipes deliver messages synchronously through a shared
    # in-memory queue, so there's nothing for at-least-once to protect
    # against. QoS hooks short-circuit when they see a Pipe.
    #
    # @param conn [Object]
    # @return [Boolean]
    #
    def self.reliable_transport?(conn)
      defined?(OMQ::Transport::Inproc::Pipe) &&
        conn.is_a?(OMQ::Transport::Inproc::Pipe)
    end


    # Picks a hash algorithm for a connection by intersecting our
    # preferences with the peer's advertised list (read from the peer's
    # READY properties).
    #
    # @param connection [Protocol::ZMTP::Connection]
    # @return [String] single-char algorithm identifier
    #
    def self.algo_for(connection)
      peer = connection.respond_to?(:peer_properties) ? connection.peer_properties : nil
      negotiate_hash(peer&.fetch("X-QoS-Hash", "") || "") || DEFAULT_HASH_ALGO
    end


    # Prepended onto Routing::RoundRobin. At QoS >= 1 we:
    #
    #   * track every successfully written message in a pending store,
    #     keyed by the 8-byte digest of its wire bytes,
    #   * disable the inproc Pipe bypass (no ACK flow possible),
    #   * requeue any unacknowledged messages for a connection when
    #     that connection is removed.
    #
    module RoundRobinExt
      private


      def init_round_robin(engine)
        super
        @pending_store = nil
        @conn_algos    = {}
      end


      def pending_store
        return @pending_store if @pending_store
        @pending_store = PendingStore.new(capacity: @engine.options.send_hwm) if @engine.options.qos >= 1
        @pending_store
      end


      def algo_for(conn)
        @conn_algos[conn] ||= QoS.algo_for(conn)
      end


      def remove_round_robin_send_connection(conn)
        super
        ps = @pending_store
        return unless ps
        ps.messages_for(conn).each { |entry| @send_queue.enqueue(entry.parts) }
        @conn_algos.delete(conn)
      end


      def write_batch(conn, batch)
        ps = @pending_store
        if ps && !QoS.reliable_transport?(conn)
          ps.wait_for_slot
          super
          algo = algo_for(conn)
          batch.each do |parts|
            wire_parts = transform_send(parts)
            ps.track(QoS.digest(wire_parts, algorithm: algo), parts, conn)
          end
        else
          super
        end
      end
    end


    # Prepended onto Routing::Push. Installs the ACK command handler
    # on every new connection at QoS >= 1. The existing reaper fiber
    # keeps blocking on {Connection#receive_message}, which dispatches
    # incoming command frames through {ConnectionExt} to our handler.
    #
    module PushExt
      def connection_added(conn)
        super
        return unless @engine.options.qos >= 1
        return if QoS.reliable_transport?(conn)
        QoS.install_command_handler(conn, pending_store)
      end
    end


    # Same pattern as PushExt — SCATTER uses RoundRobin too.
    #
    module ScatterExt
      def connection_added(conn)
        super
        return unless @engine.options.qos >= 1
        return if QoS.reliable_transport?(conn)
        QoS.install_command_handler(conn, pending_store)
      end
    end


    # Prepended onto Routing::Pull. At QoS >= 1 every received message
    # is ACK'd back to the sender before it is enqueued to the
    # application.
    #
    module PullExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)
        algo = QoS.algo_for(conn)
        @engine.start_recv_pump(conn, @recv_queue) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end
      end
    end


    # Same pattern as PullExt — GATHER uses fair-recv too.
    #
    module GatherExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)
        algo = QoS.algo_for(conn)
        @engine.start_recv_pump(conn, @recv_queue) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end
      end
    end


    # Routing::Req needs no QoS-specific override. Re-enqueueing a
    # mid-flight request on connection loss is already handled by
    # {RoundRobinExt#remove_round_robin_send_connection} through the
    # pending store. REQ's `@state` must remain `:waiting_reply` until
    # the retried request is actually answered, so flipping it back to
    # `:ready` would be wrong.
  end
end
