# frozen_string_literal: true

# OMQ QoS — per-hop delivery guarantees for OMQ sockets.
#
# Usage:
#   require "omq"
#   require "omq/rfc/qos"
#
#   push = OMQ::PUSH.new
#   push.qos = 1
#   push.connect("tcp://127.0.0.1:5555")
#   push << "guaranteed delivery"

require "omq"

require_relative "qos/version"
require_relative "qos/zmtp/command_ext"
require_relative "qos/hasher"
require_relative "qos/pending_store"
require_relative "qos/connection_ext"
require_relative "qos/lifecycle_ext"
require_relative "qos/routing_ext"
require_relative "qos/options_ext"
require_relative "qos/socket_ext"

# Wire up prepends.
Protocol::ZMTP::Codec::Command.singleton_class.prepend(OMQ::QoS::CommandClassExt)
Protocol::ZMTP::Codec::Command.prepend(OMQ::QoS::CommandExt)

OMQ::Routing::RoundRobin.prepend(OMQ::QoS::RoundRobinExt)
OMQ::Routing::Push.prepend(OMQ::QoS::PushExt)
OMQ::Routing::Pull.prepend(OMQ::QoS::PullExt)
OMQ::Routing::FanOut.prepend(OMQ::QoS::FanOutExt)
OMQ::Routing::Sub.prepend(OMQ::QoS::SubExt)
OMQ::Routing::XSub.prepend(OMQ::QoS::XSubExt)

# Draft socket types from optional extension gems.
OMQ::Routing::Scatter.prepend(OMQ::QoS::ScatterExt) if defined?(OMQ::Routing::Scatter)
OMQ::Routing::Gather.prepend(OMQ::QoS::GatherExt)   if defined?(OMQ::Routing::Gather)
OMQ::Routing::Dish.prepend(OMQ::QoS::DishExt)       if defined?(OMQ::Routing::Dish)
