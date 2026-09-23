require "test_helper"

module Catches
  class ProWalleyeTest < ActiveSupport::TestCase
    test "caps and threshold constants, and big? classifies on the 55cm boundary in inches" do
      assert_equal 5, ProWalleye::BASKET_SIZE
      assert_equal 2, ProWalleye::BIG_CAP
      assert_equal 55, ProWalleye::THRESHOLD_CM

      assert_not ProWalleye.big?(BigDecimal("21.65")), "55.0 cm stores 21.65 in => small"
      assert     ProWalleye.big?(BigDecimal("21.66")), "just over threshold => big"
      assert_not ProWalleye.big?(20),   "well under => small"
      assert     ProWalleye.big?(24),   "well over => big"
    end
  end
end
