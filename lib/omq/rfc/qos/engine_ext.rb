# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto OMQ::Engine to pass QoS options through the ZMTP
    # handshake and validate QoS compatibility after connection.
    #
    module EngineExt
      private

      def setup_connection(io, as_server:, endpoint: nil, done: nil)
        conn = Protocol::ZMTP::Connection.new(
          io,
          socket_type:      @socket_type.to_s,
          identity:         @options.identity,
          as_server:        as_server,
          mechanism:        @options.mechanism&.dup,
          max_message_size: @options.max_message_size,
          qos:              @options.qos,
          qos_hash:         @options.qos_hash,
        )
        conn.handshake!
        validate_qos!(conn, endpoint)
        start_heartbeat(conn)
        conn = @connection_wrapper.call(conn) if @connection_wrapper
        @connections << conn
        @connection_endpoints[conn] = endpoint if endpoint
        @connection_promises[conn]  = done if done
        @routing.connection_added(conn)
        @peer_connected.resolve(conn)
        emit_monitor_event(:handshake_succeeded, endpoint: endpoint)
        conn
      rescue Protocol::ZMTP::Error, *CONNECTION_LOST => error
        emit_monitor_event(:handshake_failed, endpoint: endpoint, detail: { error: error })
        conn&.close
        raise
      end

      def validate_qos!(conn, endpoint)
        local_qos = @options.qos
        peer_qos  = conn.peer_qos

        if local_qos != peer_qos
          raise Protocol::ZMTP::Error,
                "QoS mismatch: local=#{local_qos} peer=#{peer_qos}"
        end

        return unless local_qos >= 1

        local_hash = @options.qos_hash
        peer_hash  = conn.peer_qos_hash
        if !local_hash.empty? && !peer_hash.empty?
          algo = local_hash.each_char.find { |c| peer_hash.include?(c) }
          unless algo
            raise Protocol::ZMTP::Error,
                  "QoS hash algorithm mismatch: local=#{local_hash.inspect} peer=#{peer_hash.inspect}"
          end
        end
      end
    end
  end
end
