# frozen_string_literal: true

require_relative "lib/omq/qos/version"

Gem::Specification.new do |s|
  s.name     = "omq-qos"
  s.version  = OMQ::QoS::VERSION
  s.authors  = ["Patrik Wenger"]
  s.email    = ["paddor@gmail.com"]
  s.summary  = "QoS delivery guarantees for OMQ — at-least-once with ACK/NACK"
  s.description = "Quality of Service plugin for the OMQ pure-Ruby ZeroMQ library. " \
                  "Adds per-hop delivery guarantees (QoS 1: at-least-once) using " \
                  "ACK/NACK command frames and xxHash message identification."
  s.homepage = "https://github.com/paddor/omq-qos"
  s.license  = "ISC"

  s.required_ruby_version = ">= 3.3"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]

  s.add_dependency "omq", "~> 0.21"
  s.add_dependency "xxhash"
end
