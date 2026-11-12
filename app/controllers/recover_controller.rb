# Stuck-catch recovery: reads the angler's own queued catches out of IndexedDB
# (client-side) and re-submits their re-materialized photos through /api/catches.
# Hidden by default — a site admin flips clubs.recovery_tool_enabled during a
# sync incident. See docs/superpowers/specs/2026-07-16-ios-blob-sync-fix-design.md.
class RecoverController < ApplicationController
  before_action :require_sign_in!
  before_action :require_recovery_enabled!
  skip_notice_popup!

  def index; end

  private

  # 404 rather than 403: when the tool is off it should have no discoverable
  # surface at all.
  def require_recovery_enabled!
    head :not_found unless current_club&.recovery_tool_enabled?
  end
end
