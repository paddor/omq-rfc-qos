# frozen_string_literal: true

require_relative "../test_helper"

describe "QoS rejects fan-out socket types" do
  it "raises when setting qos > 0 on PUB" do
    pub = OMQ::PUB.new
    err = assert_raises(ArgumentError) { pub.qos = 1 }
    assert_match(/PUB/, err.message)
  ensure
    pub&.close
  end


  it "raises when setting qos > 0 on SUB" do
    sub = OMQ::SUB.new
    err = assert_raises(ArgumentError) { sub.qos = 1 }
    assert_match(/SUB/, err.message)
  ensure
    sub&.close
  end


  it "raises when setting qos > 0 on XPUB" do
    xpub = OMQ::XPUB.new
    assert_raises(ArgumentError) { xpub.qos = 2 }
  ensure
    xpub&.close
  end


  it "raises when setting qos > 0 on XSUB" do
    xsub = OMQ::XSUB.new
    assert_raises(ArgumentError) { xsub.qos = 1 }
  ensure
    xsub&.close
  end


  it "still allows qos = 0 on fan-out types" do
    pub = OMQ::PUB.new
    pub.qos = 0
    assert_equal 0, pub.qos
  ensure
    pub&.close
  end


  it "still allows qos > 0 on point-to-point types" do
    push = OMQ::PUSH.new
    push.qos = 1
    assert_equal 1, push.qos
  ensure
    push&.close
  end
end
