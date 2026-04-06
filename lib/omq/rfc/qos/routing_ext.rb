# frozen_string_literal: true

module OMQ
  module QoS
    # Negotiates hash algorithm for a connection.
    # For ZMTP connections: use peer's preference list.
    # For inproc DirectPipe: use our own (same process).
    #
    def self.algo_for(connection, engine)
      if connection.respond_to?(:peer_qos_hash)
        negotiate_hash(connection.peer_qos_hash) || DEFAULT_HASH_ALGO
      else
        DEFAULT_HASH_ALGO
      end
    end


    # Prepended onto Routing::RoundRobin to track sent messages and
    # disable the DirectPipe bypass at QoS >= 1.
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
      end

      def algo_for(conn)
        @conn_algos[conn] ||= QoS.algo_for(conn, @engine)
      end

      def update_direct_pipe
        if pending_store
          @direct_pipe = nil
        else
          super
        end
      end

      def send_with_retry(parts)
        conn       = next_connection
        wire_parts = transform_send(parts)
        conn.send_message(wire_parts)
        pending_store&.track(QoS.digest(wire_parts, algorithm: algo_for(conn)), parts, conn)
      rescue *CONNECTION_LOST
        @engine.connection_lost(conn)
        retry
      end

      def send_batch(batch)
        ps            = pending_store
        pending_pairs = ps ? [] : nil

        @written.clear
        batch.each_with_index do |parts, i|
          conn = next_connection
          begin
            wire_parts = transform_send(parts)
            conn.write_message(wire_parts)
            @written << conn
            pending_pairs << [QoS.digest(wire_parts, algorithm: algo_for(conn)), parts, conn] if pending_pairs
          rescue *CONNECTION_LOST
            @engine.connection_lost(conn)
            @written.each do |c|
              c.flush
            rescue *CONNECTION_LOST
            end
            @written.clear
            pending_pairs&.each { |hash, p, c| ps.track(hash, p, c) }
            pending_pairs&.clear
            send_with_retry(parts)
            batch[(i + 1)..].each { |p| send_with_retry(p) }
            return
          end
        end
        @written.each do |conn|
          conn.flush
        rescue *CONNECTION_LOST
        end
        pending_pairs&.each { |hash, parts, conn| ps.track(hash, parts, conn) }
      end
    end


    # Prepended onto Routing::Push to start an ACK listener at QoS >= 1.
    #
    module PushExt
      def connection_added(connection)
        @connections << connection
        signal_connection_available
        update_direct_pipe
        start_send_pump unless @send_pump_started
        if pending_store
          start_ack_listener(connection)
        else
          start_reaper(connection)
        end
      end

      private

      def start_ack_listener(conn)
        @tasks << @engine.spawn_pump_task(annotation: "ack listener") do
          loop do
            frame = conn.read_frame
            next unless frame.command?
            cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)
            pending_store.ack(cmd.ack_data[1]) if cmd.name == "ACK"
          end
        rescue *CONNECTION_LOST
          pending_store.messages_for(conn).each { |entry| @send_queue.enqueue(entry.parts) }
          @conn_algos.delete(conn)
          @engine.connection_lost(conn)
        end
      end
    end


    # Prepended onto Routing::Pull to send ACK after receive at QoS >= 1.
    #
    module PullExt
      def connection_added(connection)
        if @engine.options.qos >= 1
          algo = QoS.algo_for(connection, @engine) # negotiated hash family
          task = @engine.start_recv_pump(connection, @recv_queue) do |msg|
            connection.send_command(QoS.ack_command(msg, algorithm: algo))
            msg
          end
        else
          task = @engine.start_recv_pump(connection, @recv_queue)
        end
        @tasks << task if task
      end
    end


    # Prepended onto Routing::Scatter — same pattern as Push.
    #
    module ScatterExt
      def connection_added(connection)
        @connections << connection
        signal_connection_available
        update_direct_pipe
        start_send_pump unless @send_pump_started
        if pending_store
          start_ack_listener(connection)
        else
          start_reaper(connection)
        end
      end

      private

      def start_ack_listener(conn)
        @tasks << @engine.spawn_pump_task(annotation: "ack listener") do
          loop do
            frame = conn.read_frame
            next unless frame.command?
            cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)
            pending_store.ack(cmd.ack_data[1]) if cmd.name == "ACK"
          end
        rescue *CONNECTION_LOST
          pending_store.messages_for(conn).each { |entry| @send_queue.enqueue(entry.parts) }
          @conn_algos.delete(conn)
          @engine.connection_lost(conn)
        end
      end
    end


    # Prepended onto Routing::Gather — same pattern as Pull.
    #
    module GatherExt
      def connection_added(connection)
        if @engine.options.qos >= 1
          algo = QoS.algo_for(connection, @engine) # negotiated hash family
          task = @engine.start_recv_pump(connection, @recv_queue) do |msg|
            connection.send_command(QoS.ack_command(msg, algorithm: algo))
            msg
          end
        else
          task = @engine.start_recv_pump(connection, @recv_queue)
        end
        @tasks << task if task
      end
    end


    # Prepended onto Routing::FanOut to handle ACK in the subscription listener.
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
      end

      def start_subscription_listener(conn)
        @tasks << @engine.spawn_pump_task(annotation: "subscription listener") do
          loop do
            frame = conn.read_frame
            next unless frame.command?
            cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)
            case cmd.name
            when "SUBSCRIBE" then on_subscribe(conn, cmd.data)
            when "CANCEL"    then on_cancel(conn, cmd.data)
            when "ACK"       then pending_store&.ack(cmd.ack_data[1])
            end
          end
        rescue *CONNECTION_LOST
          @engine.connection_lost(conn)
        end
      end
    end


    # Prepended onto Routing::Sub to send ACK at QoS >= 1.
    #
    module SubExt
      def connection_added(connection)
        @connections << connection
        @subscriptions.each do |prefix|
          connection.send_command(Protocol::ZMTP::Codec::Command.subscribe(prefix))
        end
        if @engine.options.qos >= 1
          algo = QoS.algo_for(connection, @engine) # negotiated hash family
          task = @engine.start_recv_pump(connection, @recv_queue) do |msg|
            connection.send_command(QoS.ack_command(msg, algorithm: algo))
            msg
          end
        else
          task = @engine.start_recv_pump(connection, @recv_queue)
        end
        @tasks << task if task
      end
    end


    # Prepended onto Routing::XSub to send ACK at QoS >= 1.
    #
    module XSubExt
      def connection_added(connection)
        @connections << connection
        if @engine.options.qos >= 1
          algo = QoS.algo_for(connection, @engine) # negotiated hash family
          task = @engine.start_recv_pump(connection, @recv_queue) do |msg|
            connection.send_command(QoS.ack_command(msg, algorithm: algo))
            msg
          end
        else
          task = @engine.start_recv_pump(connection, @recv_queue)
        end
        @tasks << task if task
        start_send_pump unless @send_pump_started
      end
    end


    # Prepended onto Routing::Dish to send ACK at QoS >= 1.
    #
    module DishExt
      def connection_added(connection)
        @connections << connection
        @groups.each do |group|
          connection.send_command(Protocol::ZMTP::Codec::Command.join(group))
        end
        if @engine.options.qos >= 1
          algo = QoS.algo_for(connection, @engine) # negotiated hash family
          task = @engine.start_recv_pump(connection, @recv_queue) do |msg|
            connection.send_command(QoS.ack_command(msg, algorithm: algo))
            msg
          end
        else
          task = @engine.start_recv_pump(connection, @recv_queue)
        end
        @tasks << task if task
      end
    end


    # Prepended onto Routing::Req to stash pending request for QoS 1 retry.
    #
    module ReqExt
      def connection_removed(connection)
        super
        if @engine.options.qos >= 1 && @state == :waiting_reply && @pending_request
          @state           = :ready
          @send_queue.enqueue(@pending_request)
          @pending_request = nil
        end
      end

      def enqueue(parts)
        @pending_request = parts if @engine.options.qos >= 1
        super
      end
    end
  end
end
