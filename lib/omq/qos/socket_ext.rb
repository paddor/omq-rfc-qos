# frozen_string_literal: true

OMQ::Socket.def_delegators :@options, :qos, :qos=, :qos_hash, :qos_hash=
