# frozen_string_literal: true

require_relative "../test_helper"

describe "QoS 1 PUSH/PULL" do
  before { OMQ::Transport::Inproc.reset! }

  describe "over inproc" do
    it "sends and receives with ACK" do
      Async do
        pull = OMQ::PULL.new(nil, linger: 1, qos: 1)
        pull.bind("inproc://qos1-pp-1")

        push = OMQ::PUSH.new(nil, linger: 1, qos: 1)
        push.connect("inproc://qos1-pp-1")

        push.send("hello")
        msg = pull.receive
        assert_equal ["hello"], msg

        push.send(["multi", "part"])
        msg = pull.receive
        assert_equal ["multi", "part"], msg
      ensure
        push&.close
        pull&.close
      end
    end

    it "delivers many messages reliably" do
      Async do
        pull = OMQ::PULL.new(nil, linger: 1, qos: 1)
        pull.bind("inproc://qos1-pp-many")

        push = OMQ::PUSH.new(nil, linger: 1, qos: 1)
        push.connect("inproc://qos1-pp-many")

        n = 100
        n.times { |i| push.send("msg-#{i}") }

        received = []
        n.times { received << pull.receive.first }

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
      Async do
        pull = OMQ::PULL.new(nil, linger: 1, qos: 1)
        pull.bind("tcp://127.0.0.1:0")
        port = pull.last_tcp_port

        push = OMQ::PUSH.new(nil, linger: 1, qos: 1)
        push.reconnect_interval = RECONNECT_INTERVAL
        push.connect("tcp://127.0.0.1:#{port}")
        wait_connected(push)

        push.send("hello-tcp")
        msg = pull.receive
        assert_equal ["hello-tcp"], msg
      ensure
        push&.close
        pull&.close
      end
    end

    it "retries to next PULL on disconnect" do
      Async do
        pull1 = OMQ::PULL.new(nil, linger: 0, qos: 1)
        pull1.bind("tcp://127.0.0.1:0")
        port1 = pull1.last_tcp_port

        pull2 = OMQ::PULL.new(nil, linger: 0, qos: 1)
        pull2.bind("tcp://127.0.0.1:0")
        port2 = pull2.last_tcp_port

        push = OMQ::PUSH.new(nil, linger: 1, qos: 1)
        push.reconnect_interval = RECONNECT_INTERVAL
        push.connect("tcp://127.0.0.1:#{port1}")
        push.connect("tcp://127.0.0.1:#{port2}")
        wait_connected(push)

        # Send enough messages so both pulls get one (round-robin)
        push.send("a")
        push.send("b")
        msg1 = pull1.receive
        msg2 = pull2.receive
        assert_includes [["a"], ["b"]], msg1
        assert_includes [["a"], ["b"]], msg2

        # Close pull1, send more — should go to pull2
        pull1.close
        pull1 = nil
        sleep 0.05

        push.send("after")
        msg = pull2.receive
        assert_equal ["after"], msg
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
    Async do
      pull = OMQ::PULL.bind("inproc://qos0-pp")
      push = OMQ::PUSH.connect("inproc://qos0-pp")

      push.send("no-ack")
      msg = pull.receive
      assert_equal ["no-ack"], msg
    ensure
      push&.close
      pull&.close
    end
  end
end
