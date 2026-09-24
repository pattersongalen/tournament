module CatchesHelper
  # Google Maps query URL for a catch's exact coordinates. Universal link:
  # hands off to the Maps app on a phone (Google Maps if installed, else web),
  # opens web maps on a laptop. Only ever shown to the catch's own angler —
  # other viewers see the fuzzed ~approximate coords, never this link.
  def maps_url_for(catch)
    "https://maps.google.com/?q=#{catch.latitude.to_f},#{catch.longitude.to_f}"
  end

  # The one authoritative spelling of the EXIF-strip transcode: every photo we
  # serve — display variant or download — goes through this. The strip is a
  # privacy control: the original EXIF carries full-precision GPS, and any club
  # member can save a rival's catch photo — the coordinate fuzzing in the views
  # is pointless if the pixels ship the honey hole.
  #
  # libvips 8.14 has no granular `keep:` (that landed in 8.15), so `strip: true`
  # takes the embedded ICC profile with the EXIF. iPhone photos are Display P3,
  # so an untagged wide-gamut JPEG renders oversaturated in every browser. Bake
  # the profile into the pixels first: icc_transform reads the embedded profile
  # and rewrites the pixels as real sRGB, so dropping the tag is then lossless.
  # colourspace must come first — icc_transform raises "unable to load or find
  # any compatible input profile" on a 1-band grayscale source, and widening to
  # 3 bands is what keeps that from 500ing the variant. Insertion order is the
  # application order (Active Storage applies the hash in sequence), so the
  # conversion has to be built before the saver.
  def stripped_jpeg_variant(attachment, size: nil, quality: nil)
    options = {}
    options[:resize_to_limit] = size if size
    options[:colourspace] = :srgb
    options[:icc_transform] = "srgb"
    options[:format] = :jpeg
    options[:saver] = { strip: true }
    options[:saver][:Q] = quality if quality
    attachment.variant(**options)
  end

  # Renders a resized, lazy-loaded <img> for an Active Storage attachment.
  # (Resizing + transcoding: catch photos are full-resolution phone stills,
  # multi-MB and HEIC on iOS; a JPEG variant renders everywhere. Generated on
  # first request, cached on disk.)
  def thumb(attachment, size: [400, 400], **html_options)
    image_tag stripped_jpeg_variant(attachment, size: size), loading: "lazy", **html_options
  end

  # <img> for a large, full-bleed display (catch detail / lightbox).
  def photo_full(attachment, size: [2000, 2000], **html_options)
    image_tag stripped_jpeg_variant(attachment, size: size), **html_options
  end

  # Bare URL of a large JPEG variant — for lightbox/inline display, which must
  # never point at a raw (possibly HEIC) original. Resized for fast loading.
  def photo_src_url(attachment, size: [2000, 2000])
    url_for(stripped_jpeg_variant(attachment, size: size))
  end

  # URL for the "Save photo" download — FULL resolution at high encode
  # quality, never a resized display variant: downloads should be the largest
  # quality we can serve (user decision 2026-08-08). Still a stripped JPEG,
  # including for JPEG originals: an Android native-camera JPEG carries
  # full-precision GPS EXIF, and serving it raw would hand out what the
  # fuzzing hides — the metadata strip is the point, and it must happen at
  # serve time (originals keep EXIF for PhotoCaptureTime forensics).
  # ACCEPTED COST: the first tap on a photo runs an unbounded on-demand vips
  # transcode — a 200MP native-mode still (PHOTO_MAX_BYTES allows 50MB) can
  # be slow on the single VM. Quality was chosen over bounding the transcode;
  # don't re-add a resize limit here unprompted.
  DOWNLOAD_JPEG_QUALITY = 95

  def photo_download_url(attachment)
    url_for(stripped_jpeg_variant(attachment, quality: DOWNLOAD_JPEG_QUALITY))
  end

  # The photo(s) to show on a single-catch detail/modal page, as an ordered list
  # of { label:, attachment: } hashes. When an organizer has added a reference
  # photo, both it and the angler's original are shown — each labelled, and both
  # visible to every viewer (not staff-only). The reference comes first because
  # it supersedes the original for display. With a single photo attached, it's
  # shown unlabelled (the common case).
  def catch_detail_photos(catch_record)
    reference = catch_record.reference_photo
    original  = catch_record.photo
    if reference.attached? && original.attached?
      [{ label: "Reference photo", attachment: reference },
       { label: "Original photo",    attachment: original }]
    elsif reference.attached?
      [{ label: nil, attachment: reference }]
    elsif original.attached?
      [{ label: nil, attachment: original }]
    else
      []
    end
  end

  # An organizer of the club, or a judge of any tournament where this catch
  # is placed, may open the catch detail page (photo, video, GPS, etc.).
  # Regular members can see catches on the leaderboard but not the detail.
  def can_view_catch?(catch_record)
    return false if current_user.nil?
    return true  if catch_record.user_id == current_user.id
    return true  if current_user.organizer_in?(current_club)
    judge_tournament_ids = TournamentJudge.where(user: current_user).pluck(:tournament_id)
    catch_tournament_ids = catch_record.catch_placements.pluck(:tournament_id).uniq
    (judge_tournament_ids & catch_tournament_ids).any?
  end

  # Cheap form for the leaderboard partial: any organizer, or a judge of
  # the given tournament. (Doesn't load the catch's placements.)
  # Memoized per-tournament — called once per fish row in the leaderboard,
  # so without the cache a member viewer would do one TournamentJudge.exists?
  # query per row, plus one per Turbo Stream rebroadcast.
  def can_open_catches_in?(tournament)
    return false if current_user.nil? || tournament.nil?
    return true if current_user.organizer_in?(current_club)
    @_can_open_tournaments ||= {}
    @_can_open_tournaments.fetch(tournament.id) do
      @_can_open_tournaments[tournament.id] =
        TournamentJudge.exists?(tournament: tournament, user: current_user)
    end
  end

  # Returns [url, turbo_frame] for the leaderboard fish-row link.
  # - Organizer/judge of the tournament: full catch detail page (no frame, full navigation).
  # - Member, non-blind tournament (or blind tournament that has ended): photo modal via
  #   tournament_catch_path, framed.
  # - Member, blind tournament during its active window: [nil, nil] — caller renders plain
  #   text instead of a link, so the active blind-leaderboard guarantee is preserved.
  def catch_link_target(tournament:, catch_id:)
    return [catch_path(catch_id, t: tournament.id), nil] if can_open_catches_in?(tournament)
    return [nil, nil] if tournament.blind?(at: Time.current)
    [tournament_catch_path(tournament, catch_id), "catch_photo_modal"]
  end

  # Staff-eyes-only check used to gate review-oriented UI (e.g. the
  # possible-duplicate flag). Catch owners do NOT qualify here.
  def can_review_catch?(catch_record)
    return false if current_user.nil?
    return true  if current_user.organizer_in?(current_club)
    # Reuses ApplicationController#judged_tournament_ids (request-memoized), so the
    # TournamentJudge lookup runs once per request, not once per catch.
    return false if judged_tournament_ids.empty?
    # map (not pluck) so the controller's :catch_placements preload is used —
    # pluck always issues a fresh query, N+1ing the listing it was preloaded for.
    catch_tournament_ids = catch_record.catch_placements.map(&:tournament_id).uniq
    return true if (judged_tournament_ids & catch_tournament_ids).any?
    # Bingo keeps no CatchPlacement rows, so the placed-in check above can't connect
    # a dedicated judge to an entrant's catch. Fall back to the bingo tournaments
    # this viewer judges: the catch is reviewable if its owner is an entrant and it
    # falls in the window (mirroring EvaluateCard's load).
    reviewable_via_judged_bingo?(catch_record)
  end

  # For a dedicated judge, the bingo tournaments they judge — each as its catch
  # window plus the set of its entrant user ids. Loaded once per request so the
  # per-catch check in can_review_catch? doesn't N+1 the listing.
  def judged_bingo_review_contexts
    @judged_bingo_review_contexts ||=
      Tournament.format_bingo.where(id: judged_tournament_ids.to_a).map do |t|
        entrant_ids = TournamentEntryMember
          .joins(:tournament_entry)
          .where(tournament_entries: { tournament_id: t.id })
          .pluck(:user_id).to_set
        { window: t.starts_at..t.ends_at, entrant_ids: entrant_ids }
      end
  end

  def reviewable_via_judged_bingo?(catch_record)
    at = catch_record.captured_at_device
    return false if at.nil?
    judged_bingo_review_contexts.any? do |ctx|
      ctx[:entrant_ids].include?(catch_record.user_id) && ctx[:window].cover?(at)
    end
  end

  # Flags judges/organizers see but members must not — either to avoid tipping
  # off a cheater or falsely accusing an honest member of one.
  REVIEW_ONLY_FLAGS = %w[possible_duplicate imported_photo screenshot_suspect].freeze

  # Member-facing flag list: drops review-only flags unless the current viewer
  # is staff for this catch. The early return keeps the common case (no
  # review-only flag present) from issuing the can_review_catch? query.
  def visible_flags_for(catch_record)
    flags = Array(catch_record.flags)
    return flags if (flags & REVIEW_ONLY_FLAGS).empty?
    return flags if can_review_catch?(catch_record)
    flags - REVIEW_ONLY_FLAGS
  end

  FLAG_LABELS = {
    "missing_gps"        => "no GPS",
    "clock_skew"         => "clock mismatch",
    "out_of_bounds"      => "outside local",
    "out_of_province"    => "outside Saskatchewan",
    "possible_duplicate" => "possible duplicate",
    "imported_photo"     => "imported photo",
    "screenshot_suspect" => "possible screenshot",
    "no_draw_ticket"     => "no draw ticket"
  }.freeze

  def flag_label(flag)
    FLAG_LABELS.fetch(flag, flag.humanize.downcase)
  end

  # Returns a URL for the given day-cell on the calendar. The URL encodes the
  # next selection state per `next_range`, while passing other params (species,
  # sort, page, etc.) through unchanged. Drops Rails-internal :controller and
  # :action keys, the :month filter (tapping a day returns to date-range mode,
  # overriding any active month-of-year filter), and :mc (so the match
  # conditions panel collapses on a calendar tap).
  def month_calendar_link_url(day, current_start:, current_end:, params:, path_helper:)
    target_start, target_end = next_range(day, current_start, current_end)
    cleaned = params.to_h.with_indifferent_access.except(:controller, :action, :month, :mc)
    public_send(path_helper, cleaned.merge(
      start: target_start&.iso8601,
      end: target_end&.iso8601
    ).compact)
  end

  # Returns [target_start, target_end] given a tapped day and the current
  # selection state. Implements the tap-rule table:
  #   - no selection         → single day on tapped
  #   - single day, same tap → no change
  #   - single day, diff tap → range (min/max of the two)
  #   - existing range, tap  → reset to single day on tapped
  def next_range(day, current_start, current_end)
    return [day, day] if current_start.nil?
    return [current_start, current_end] if current_start == current_end && day == current_start
    return [[current_start, day].min, [current_start, day].max] if current_start == current_end
    [day, day]
  end

  # CSS class for a single calendar day cell, given the day and the current
  # selection range. Caller adds layout classes (size, padding) on top.
  def catch_calendar_day_classes(day:, selected_start:, selected_end:, in_displayed_month:)
    base = ["relative", "flex", "items-center", "justify-center", "h-10", "text-sm"]
    return base + ["text-slate-600"] unless in_displayed_month

    classes = base + ["text-slate-200", "rounded"]
    if selected_start && day >= selected_start && day <= (selected_end || selected_start)
      if day == selected_start && day == selected_end
        classes += ["bg-blue-600", "text-white", "rounded"]
      elsif day == selected_start
        classes += ["bg-blue-600", "text-white", "rounded-l", "rounded-r-none"]
      elsif day == selected_end
        classes += ["bg-blue-600", "text-white", "rounded-r", "rounded-l-none"]
      else
        classes += ["bg-blue-600/40", "rounded-none"]
      end
    end
    classes += ["ring-2", "ring-blue-400"] if day == Date.current
    classes.join(" ")
  end

  # The 6×7 grid of dates that fills the visible month, including dim
  # leading/trailing days from the prior/next months. Returns an array of
  # arrays (rows of 7 Date objects).
  def catch_calendar_grid(month_start)
    first = month_start.beginning_of_month
    grid_start = first.beginning_of_week(:sunday)
    last = month_start.end_of_month
    grid_end = last.end_of_week(:sunday)
    (grid_start..grid_end).each_slice(7).to_a
  end
end
