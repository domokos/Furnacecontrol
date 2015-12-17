require_relative "boiler_base"
require "test/unit"
 
class Trial_test < Test::Unit::TestCase
 
  def test_one
    assert_equal(4, SimpleNumber.new(2).add(2) )
    assert_equal(6, SimpleNumber.new(2).multiply(3) )
  end
 
end