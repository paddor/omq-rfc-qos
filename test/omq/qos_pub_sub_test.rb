# frozen_string_literal: true

require_relative "../test_helper"

describe "QoS 1 PUB/SUB" do
  before { OMQ::Transport::Inproc.reset! }

  it "sends and receives with ACK over inproc" do
    Async do
      pub = OMQ::PUB.new(nil, linger: 1)
      pub.qos = 1
      pub.bind("inproc://qos1-ps-1")

      sub = OMQ::SUB.new(nil, linger: 1)
      sub.qos = 1
      sub.connect("inproc://qos1-ps-1", subscribe: "")

      # Wait for subscription to propagate
      pub.subscriber_joined.wait

      pub.send("hello-pub")
      msg = sub.receive
      assert_equal ["hello-pub"], msg
    ensure
      pub&.close
      sub&.close
    end
  end

  it "sends and receives with ACK over TCP" do
    Async do
      pub = OMQ::PUB.new(nil, linger: 1)
      pub.qos = 1
      pub.bind("tcp://127.0.0.1:0")
      port = pub.last_tcp_port

      sub = OMQ::SUB.new(nil, linger: 1)
      sub.qos                = 1
      sub.reconnect_interval = RECONNECT_INTERVAL
      sub.connect("tcp://127.0.0.1:#{port}", subscribe: "")

      pub.subscriber_joined.wait

      pub.send("hello-tcp-pub")
      msg = sub.receive
      assert_equal ["hello-tcp-pub"], msg
    ensure
      pub&.close
      sub&.close
    end
  end
end
