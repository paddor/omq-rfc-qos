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


    # Inproc DirectPipes deliver messages synchronously through a shared
    # in-memory queue, so there's nothing for at-least-once to protect
    # against. QoS hooks short-circuit when they see a DirectPipe.
    #
    # @param conn [Object]
    # @return [Boolean]
    #
    def self.reliable_transport?(conn)
      defined?(OMQ::Transport::Inproc::DirectPipe) &&
        conn.is_a?(OMQ::Transport::Inproc::DirectPipe)
    end


    # Picks a hash algorithm for a connection by intersecting our
    # preferences with the peer's advertised list.
    #
    # @param connection [Protocol::ZMTP::Connection]
    # @return [String] single-char algorithm identifier
    #
    def self.algo_for(connection)
      peer = connection.respond_to?(:peer_qos_hash) ? connection.peer_qos_hash : nil
      negotiate_hash(peer || "") || DEFAULT_HASH_ALGO
    end


    # Prepended onto Routing::RoundRobin. At QoS >= 1 we:
    #
    #   * track every successfully written message in a pending store,
    #     keyed by the 8-byte digest of its wire bytes,
    #   * disable the inproc DirectPipe bypass (no ACK flow possible),
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
        @pending_store = PendingStore.new if @engine.options.qos >= 1
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
        super
        ps = @pending_store
        return unless ps
        return if QoS.reliable_transport?(conn)
        algo = algo_for(conn)
        batch.each do |parts|
          wire_parts = transform_send(parts)
          ps.track(QoS.digest(wire_parts, algorithm: algo), parts, conn)
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


    # Sub/XSub/Dish helper: at QoS 0 or for DirectPipe peers, fall back
    # to the base implementation. Otherwise call the extended path via
    # a shared wrapper argument.



    # Prepended onto Routing::Pull. At QoS >= 1 every received message
    # is ACK'd back to the sender before it is enqueued to the
    # application.
    #
    module PullExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)
        algo = QoS.algo_for(conn)
        add_fair_recv_connection(conn) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end
      end
    end


    # Same pattern as PullExt — GATHER uses FairRecv too.
    #
    module GatherExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)
        algo = QoS.algo_for(conn)
        add_fair_recv_connection(conn) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end
      end
    end


    # Prepended onto Routing::FanOut. Extends the subscription listener
    # to also dispatch ACK commands into the pending store, and keeps
    # per-connection pending tracking so fan-out messages can be
    # requeued on connection loss.
    #
    module FanOutExt
      private

      def init_fan_out(engine)
        super
        @pending_store = nil
      end


      def pending_store
        return @pending_store if @pending_store
        @pending_store = PendingStore.new if @engine.options.qos >= 1
        @pending_store
      end


      def start_subscription_listener(conn)
        @tasks << @engine.spawn_conn_pump_task(conn, annotation: "subscription listener") do
          loop do
            frame = conn.read_frame
            next unless frame.command?

            cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)

            case cmd.name
            when "SUBSCRIBE"
              on_subscribe(conn, cmd.data)
            when "CANCEL"
              on_cancel(conn, cmd.data)
            when "ACK"
              _, hash = cmd.ack_data
              pending_store&.ack(hash)
            end
          end
        end
      end
    end


    # Prepended onto Routing::Sub. At QoS >= 1 each received message
    # is ACK'd before being enqueued to the application.
    #
    module SubExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)

        @connections << conn
        @subscriptions.each do |prefix|
          conn.send_command(Protocol::ZMTP::Codec::Command.subscribe(prefix))
        end

        algo      = QoS.algo_for(conn)
        conn_q    = Routing.build_queue(@engine.options.recv_hwm, @engine.options.on_mute)
        signaling = Routing::SignalingQueue.new(conn_q, @recv_queue)
        @recv_queue.add_queue(conn, conn_q)

        task = @engine.start_recv_pump(conn, signaling) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end

        @tasks << task if task
      end
    end


    # Prepended onto Routing::XSub. Same ACK-on-receive behavior as
    # SubExt, plus it leaves XSub's outbound subscription send pump
    # untouched.
    #
    module XSubExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)

        @connections << conn

        algo      = QoS.algo_for(conn)
        conn_q    = Routing.build_queue(@engine.options.recv_hwm, @engine.options.on_mute)
        signaling = Routing::SignalingQueue.new(conn_q, @recv_queue)
        @recv_queue.add_queue(conn, conn_q)

        task = @engine.start_recv_pump(conn, signaling) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end

        @tasks << task if task

        q = Routing.build_queue(@engine.options.send_hwm, :block)
        @conn_queues[conn] = q
        send(:start_conn_send_pump, conn, q)
      end
    end


    # Prepended onto Routing::Dish.
    #
    module DishExt
      def connection_added(conn)
        return super unless @engine.options.qos >= 1
        return super if QoS.reliable_transport?(conn)

        @connections << conn
        @groups.each do |group|
          conn.send_command(Protocol::ZMTP::Codec::Command.join(group))
        end

        algo      = QoS.algo_for(conn)
        conn_q    = Routing.build_queue(@engine.options.recv_hwm, @engine.options.on_mute)
        signaling = Routing::SignalingQueue.new(conn_q, @recv_queue)
        @recv_queue.add_queue(conn, conn_q)

        task = @engine.start_recv_pump(conn, signaling) do |msg|
          conn.send_command(QoS.ack_command(msg, algorithm: algo))
          msg
        end

        @tasks << task if task
      end
    end


    # Prepended onto Routing::Req. Stashes the last-sent request so it
    # can be re-enqueued to another peer when the first one drops
    # before the reply arrives.
    #
    module ReqExt
      def connection_removed(conn)
        super
        return unless @engine.options.qos >= 1
        return unless @state == :waiting_reply && @pending_request
        @state           = :ready
        @send_queue.enqueue(@pending_request)
        @pending_request = nil
      end


      def enqueue(parts)
        @pending_request = parts if @engine.options.qos >= 1
        super
      end
    end
  end
end
