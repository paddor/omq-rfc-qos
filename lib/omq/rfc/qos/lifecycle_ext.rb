# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto OMQ::Engine::ConnectionLifecycle so that the
    # Protocol::ZMTP::Connection is built with this socket's +qos+ /
    # +qos_hash+ options, and the peer's QoS properties are validated
    # after the handshake.
    #
    module LifecycleExt
      def handshake!(io, as_server:)
        transition!(:handshaking)
        conn = Protocol::ZMTP::Connection.new io,
          socket_type:      @engine.socket_type.to_s,
          identity:         @engine.options.identity,
          as_server:        as_server,
          mechanism:        @engine.options.mechanism&.dup,
          max_message_size: @engine.options.max_message_size,
          qos:              @engine.options.qos,
          qos_hash:         @engine.options.qos_hash

        Async::Task.current.with_timeout(handshake_timeout) do
          conn.handshake!
        end

        QoS.validate_handshake!(@engine.options, conn)

        OMQ::Engine::Heartbeat.start(@barrier, conn, @engine.options, @engine.tasks)
        ready!(conn)
        @conn
      rescue Protocol::ZMTP::Error, *OMQ::CONNECTION_LOST, Async::TimeoutError => error
        @engine.emit_monitor_event :handshake_failed,
          endpoint: @endpoint, detail: { error: error }

        conn&.close

        tear_down!(reconnect: true)
        raise
      end

    end


    def self.validate_handshake!(options, conn)
      local_qos = options.qos
      peer_qos  = conn.peer_qos || 0

      if local_qos != peer_qos
        raise Protocol::ZMTP::Error,
              "QoS mismatch: local=#{local_qos} peer=#{peer_qos}"
      end

      return unless local_qos >= 1

      local_hash = options.qos_hash
      peer_hash  = conn.peer_qos_hash || ""
      return if local_hash.empty? || peer_hash.empty?

      algo = local_hash.each_char.find { |c| peer_hash.include?(c) }
      return if algo

      raise Protocol::ZMTP::Error,
            "QoS hash algorithm mismatch: local=#{local_hash.inspect} peer=#{peer_hash.inspect}"
    end
  end
end


OMQ::Engine::ConnectionLifecycle.prepend(OMQ::QoS::LifecycleExt)
