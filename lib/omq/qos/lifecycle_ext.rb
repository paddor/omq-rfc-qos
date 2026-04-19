# frozen_string_literal: true

module OMQ
  module QoS
    # Prepended onto OMQ::Engine::ConnectionLifecycle so that the
    # Protocol::ZMTP::Connection is built with this socket's QoS
    # metadata, and the peer's QoS properties are validated after the
    # handshake.
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
          **QoS.handshake_metadata(@engine.options)

        Async::Task.current.with_timeout(handshake_timeout) do
          conn.handshake!
        end

        QoS.validate_handshake!(@engine.options, conn)

        OMQ::Engine::Heartbeat.start(@barrier, conn, @engine.options)
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


    # Builds the READY-property metadata hash this socket should
    # advertise based on its QoS configuration. Empty hash at QoS 0
    # so the Connection sees no extras.
    #
    # @param options [OMQ::Options]
    # @return [Hash{String => String}]
    def self.handshake_metadata(options)
      return {} unless options.qos > 0
      meta = { "X-QoS" => options.qos.to_s }
      meta["X-QoS-Hash"] = options.qos_hash unless options.qos_hash.empty?
      meta
    end


    def self.validate_handshake!(options, conn)
      props     = conn.peer_properties || {}
      local_qos = options.qos
      peer_qos  = (props["X-QoS"] || "0").to_i

      if local_qos != peer_qos
        raise Protocol::ZMTP::Error,
              "QoS mismatch: local=#{local_qos} peer=#{peer_qos}"
      end

      return unless local_qos >= 1

      local_hash = options.qos_hash
      peer_hash  = props["X-QoS-Hash"] || ""
      return if local_hash.empty? || peer_hash.empty?

      algo = local_hash.each_char.find { |c| peer_hash.include?(c) }
      return if algo

      raise Protocol::ZMTP::Error,
            "QoS hash algorithm mismatch: local=#{local_hash.inspect} peer=#{peer_hash.inspect}"
    end
  end
end


OMQ::Engine::ConnectionLifecycle.prepend(OMQ::QoS::LifecycleExt)
