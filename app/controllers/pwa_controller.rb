class PwaController < ApplicationController
  # The same-origin check on JS responses fires when content-type is text/javascript;
  # service workers are loaded by the browser itself (not a <script> include) so the
  # cross-origin-script defense is a false positive here.
  skip_forgery_protection only: :service_worker
  skip_notice_popup!

  def manifest
    render template: "pwa/manifest", formats: [:json], content_type: "application/manifest+json"
  end

  def service_worker
    # Tell browsers to re-check the SW file every navigation rather than serving
    # a cached copy. The SW response body is tiny; the per-deploy cache key
    # bump inside it is what actually invalidates the asset cache for users.
    response.headers["Cache-Control"] = "no-cache, max-age=0, must-revalidate"
    render template: "pwa/service_worker", formats: [:js], content_type: "text/javascript"
  end

  # The offline shell is intentionally renderable without a signed-in user and
  # contains no personalized data, so the service worker can precache it and
  # serve it to anyone on a shared device without leaking another user's HTML.
  def offline
    render template: "pwa/offline", layout: "offline"
  end
end
