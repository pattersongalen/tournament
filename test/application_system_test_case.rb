require "test_helper"
require "capybara/cuprite"

Capybara.register_driver :tournament_cuprite do |app|
  # no-sandbox: Chromium's setuid sandbox can't run as root inside an unprivileged container.
  # disable-dev-shm-usage: /dev/shm in Docker defaults to 64MB, too small for Chromium tabs.
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1280, 800],
    headless: true,
    process_timeout: 30,
    browser_options: { "no-sandbox": nil, "disable-dev-shm-usage": nil }
  )
end

# Capybara waits 2s by default for a page to show what a test expects. With
# every core running a headless Chromium, a sign-in POST can take longer than
# that: the page arrives, just late, and the test fails at a different line
# each run. 5s only costs time when something is actually missing.
Capybara.default_max_wait_time = 5

require_relative "support/ios_web_quirks"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include IosWebQuirks

  driven_by :tournament_cuprite
end
