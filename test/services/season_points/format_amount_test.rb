require "test_helper"

module SeasonPoints
  class FormatAmountTest < ActiveSupport::TestCase
    test "formats whole numbers bare, trims trailing zeros, keeps up to two decimals" do
      { 3 => "3", 3.5 => "3.5", 3.75 => "3.75", 3.333 => "3.33", 0 => "0", 10.0 => "10", BigDecimal("0.5") => "0.5" }.each do |n, s|
        assert_equal s, SeasonPoints::FormatAmount.call(n), "format(#{n.inspect})"
      end
    end
  end
end
