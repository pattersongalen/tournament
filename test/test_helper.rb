ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    # threshold: the system suite is ~45 tests after the 2026-08 reduction; Rails' default threshold of 50 would silently run it in one process (~4 min instead of ~30 s).
    parallelize(workers: :number_of_processors, threshold: 10)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

require "factory_bot_rails"

class ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods

  # The three canonical species the Bingo card references. Tournament validates
  # they exist before a bingo tournament can be saved, so bingo tests must seed
  # them (inherited by integration and system test cases too).
  def create_bingo_species!
    %w[Walleye Perch Pike].map { |n| Species.find_or_create_by!(name: n) }
  end

  # Captures every Placements::BroadcastLeaderboard.call(tournament:) inside the
  # block and yields the array of tournament ids broadcast to. Restores the
  # original implementation in `ensure` so failures don't leak the stub.
  def with_broadcast_spy
    calls = []
    original = Placements::BroadcastLeaderboard.method(:call)
    Placements::BroadcastLeaderboard.define_singleton_method(:call) { |tournament:, **| calls << tournament.id }
    begin
      yield calls
    ensure
      Placements::BroadcastLeaderboard.define_singleton_method(:call, original)
    end
    calls
  end

  # Counts sql.active_record queries whose SQL matches `pattern` during the
  # block, ignoring schema introspection and cached queries. Use it to prove an
  # association is eager-loaded (one query for the whole page) rather than
  # N+1'd (one query per rendered row). A String pattern is matched literally.
  def count_queries(pattern)
    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"
      count += 1 if payload[:sql] =~ pattern
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  # Replaces self-method `name` on `klass` with `replacement` (a callable) for
  # the duration of the block. Restores the original even if the block raises.
  def with_class_method_stub(klass, name, replacement)
    original = klass.method(name)
    klass.define_singleton_method(name, replacement)
    yield
  ensure
    klass.define_singleton_method(name, original)
  end
end

class ActionDispatch::SystemTestCase
  include FactoryBot::Syntax::Methods
end
