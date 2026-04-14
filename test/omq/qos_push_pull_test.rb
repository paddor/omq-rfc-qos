# frozen_string_literal: true

require_relative "../test_helper"

describe "QoS 1 PUSH/PULL" do
  before { OMQ::Transport::Inproc.reset! }

  describe "over inproc" do
    it "sends and receives with ACK" do
      Sync do
        pull = OMQ::PULL.new
        pull.qos = 1
        pull.bind("inproc://qos1-pp-1")

        push = OMQ::PUSH.new
        push.qos    = 1
        push.linger = 1
        push.connect("inproc://qos1-pp-1")
        wait_connected(push)

        push.send("hello")
        assert_equal ["hello"], pull.receive

        push.send(["multi", "part"])
        assert_equal ["multi", "part"], pull.receive
      ensure
        push&.close
        pull&.close
      end
    end


    it "delivers many messages reliably" do
      Sync do
        pull = OMQ::PULL.new
        pull.qos = 1
        pull.bind("inproc://qos1-pp-many")

        push = OMQ::PUSH.new
        push.qos    = 1
        push.linger = 1
        push.connect("inproc://qos1-pp-many")
        wait_connected(push)

        n = 100
        n.times { |i| push.send("msg-#{i}") }

        received = Array.new(n) { pull.receive.first }

        assert_equal n, received.size
        assert_equal "msg-0", received.first
        assert_equal "msg-#{n - 1}", received.last
      ensure
        push&.close
        pull&.close
      end
    end
  end


  describe "over TCP" do
    it "sends and receives with ACK" do
      Sync do
        pull = OMQ::PULL.new
        pull.qos = 1
        pull.bind("tcp://127.0.0.1:0")
        port = pull.last_tcp_port

        push = OMQ::PUSH.new
        push.qos                = 1
        push.linger             = 1
        push.reconnect_interval = RECONNECT_INTERVAL
        push.connect("tcp://127.0.0.1:#{port}")
        wait_connected(push)

        push.send("hello-tcp")
        assert_equal ["hello-tcp"], pull.receive
      ensure
        push&.close
        pull&.close
      end
    end


    it "retries to next PULL on disconnect" do
      Sync do
        pull1 = OMQ::PULL.new
        pull1.qos    = 1
        pull1.linger = 0
        pull1.bind("tcp://127.0.0.1:0")
        port1 = pull1.last_tcp_port

        pull2 = OMQ::PULL.new
        pull2.qos    = 1
        pull2.linger = 0
        pull2.bind("tcp://127.0.0.1:0")
        port2 = pull2.last_tcp_port

        push = OMQ::PUSH.new
        push.qos                = 1
        push.linger             = 1
        push.reconnect_interval = RECONNECT_INTERVAL
        push.connect("tcp://127.0.0.1:#{port1}")
        push.connect("tcp://127.0.0.1:#{port2}")
        wait_connected(push)

        pull1.close
        pull1 = nil
        sleep 0.1

        push.send("after")
        assert_equal ["after"], pull2.receive
      ensure
        push&.close
        pull1&.close
        pull2&.close
      end
    end
  end
end


describe "QoS 0 PUSH/PULL unchanged" do
  before { OMQ::Transport::Inproc.reset! }

  it "works without ACK at QoS 0 (default)" do
    Sync do
      pull = OMQ::PULL.bind("inproc://qos0-pp")
      push = OMQ::PUSH.connect("inproc://qos0-pp")

      push.send("no-ack")
      assert_equal ["no-ack"], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end
end
