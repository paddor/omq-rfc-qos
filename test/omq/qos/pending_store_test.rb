# frozen_string_literal: true

require_relative "../../test_helper"

describe OMQ::QoS::PendingStore do
  let(:store)  { OMQ::QoS::PendingStore.new }
  let(:conn_a) { Object.new }
  let(:conn_b) { Object.new }

  it "tracks and acks a message" do
    hash  = "12345678"
    parts = ["hello"].freeze
    store.track(hash, parts, conn_a)

    assert_equal 1, store.size
    refute store.empty?

    entry = store.ack(hash)
    assert_equal parts, entry.parts
    assert_equal conn_a, entry.connection

    assert_equal 0, store.size
    assert store.empty?
  end

  it "returns nil for unknown hash" do
    assert_nil store.ack("unknown!")
  end

  it "returns messages_for a specific connection" do
    store.track("hash1___", ["msg1"].freeze, conn_a)
    store.track("hash2___", ["msg2"].freeze, conn_b)
    store.track("hash3___", ["msg3"].freeze, conn_a)

    entries = store.messages_for(conn_a)
    assert_equal 2, entries.size
    assert_equal ["msg1"], entries[0].parts
    assert_equal ["msg3"], entries[1].parts

    # Only conn_b remains
    assert_equal 1, store.size
  end

  it "records sent_at timestamp" do
    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    store.track("hashtime", ["ts"].freeze, conn_a)
    after = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    entry = store.ack("hashtime")
    assert_operator entry.sent_at, :>=, before
    assert_operator entry.sent_at, :<=, after
  end
end

describe OMQ::QoS do
  it "computes deterministic digest" do
    parts = ["hello", "world"].freeze
    d1    = OMQ::QoS.digest(parts)
    d2    = OMQ::QoS.digest(parts)
    assert_equal d1, d2
    assert_equal 8, d1.bytesize
  end

  it "produces different digests for different framings" do
    d1 = OMQ::QoS.digest(["AB", "CD"])
    d2 = OMQ::QoS.digest(["A", "BCD"])
    d3 = OMQ::QoS.digest(["ABCD"])
    refute_equal d1, d2
    refute_equal d1, d3
    refute_equal d2, d3
  end

  it "builds an ACK command" do
    cmd = OMQ::QoS.ack_command(["test"])
    assert_equal "ACK", cmd.name
    algo, hash = cmd.ack_data
    assert_equal "x", algo
    assert_equal 8, hash.bytesize
  end
end
