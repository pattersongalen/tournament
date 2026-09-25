class Catch < ApplicationRecord
  self.table_name = "catches"
  belongs_to :user
  belongs_to :species
  belongs_to :logged_by_user, class_name: "User", optional: true
  has_one_attached :photo
  has_one_attached :reference_photo       # admin-added photo that supersedes the original for display
  has_one_attached :video                 # not used in Phase 1; reserved for Phase 2
  has_many :catch_placements, dependent: :destroy
  has_many :judge_actions, dependent: :destroy

  # The photo shown to viewers. An admin-added reference photo supersedes the
  # angler's original submission for display; the original stays visible to
  # staff on the judge review page.
  def display_photo
    reference_photo.attached? ? reference_photo : photo
  end

  # Single source of truth for the override-or-inside geofence decision shared by
  # ComputeFlags, PlaceInSlots, and SlotPlacement: the catch satisfies the named
  # region (:lake or :sask) when a judge has overridden that region's boundary
  # for this catch, or its coordinates actually fall inside it. Callers handle
  # the no-location (latitude nil) case themselves.
  def in_geofence?(region)
    overridden = region == :lake ? override_in_lake? : override_in_sask?
    overridden || ::Geofence.includes?(region, latitude, longitude)
  end

  # Single source of the geofence *scoring* rule: whether this catch counts toward
  # `tournament`. A catch with no recorded location is always eligible (kept for
  # judge review); otherwise it must sit inside Saskatchewan, and inside the lake
  # when the tournament is local. Judge geofence overrides are honored via
  # #in_geofence?. Shared by PlaceInSlots, SlotPlacement, and the bingo
  # EvaluateCard so every format scores the same set of catches.
  def geofence_eligible_for?(tournament)
    return true if latitude.nil?
    return false unless in_geofence?(:sask)
    return true unless tournament.local?
    in_geofence?(:lake)
  end

  # Add `flag` to the flags array in one guarded UPDATE against the row's
  # current flags: two writers appending different flags (FlagImportedPhotoJob
  # and a teammate's FlagDuplicates on the same row) never clobber each other
  # the way a read-modify-write from an in-memory snapshot would, and a
  # repeat add is a no-op. With `bump_to_review`, a still-synced catch moves
  # to needs_review in the same statement, guarded on the row's *current*
  # status so a concurrent judge decision is never overwritten.
  #
  # The loaded instance is then brought in line with what the row now holds,
  # read back from the statement itself (RETURNING) rather than inferred from
  # this instance's stale snapshot: a row a judge disqualified after this
  # instance loaded it keeps its status, and the mirror says so. Mirrored as
  # a fact, not a pending change: the API create response and the catch
  # views read flags/status off this instance after placement, and a later
  # save must not re-send them. When the row already carried the flag the
  # statement touches nothing and only the flag is mirrored; any other flag
  # the row holds that this instance never loaded is deliberately left alone
  # (the concurrent-writer guarantee is about the row, not the snapshot).
  # Returns the number of rows changed (0 or 1).
  def add_flag!(flag, bump_to_review: false)
    set_sql = "flags = array_append(flags, ?::text)"
    if bump_to_review
      synced = self.class.statuses["synced"]
      review = self.class.statuses["needs_review"]
      set_sql += ", status = CASE WHEN status = #{synced} THEN #{review} ELSE status END"
    end
    sql = self.class.sanitize_sql_array([
      "UPDATE #{self.class.quoted_table_name} SET #{set_sql} " \
      "WHERE id = ? AND NOT (flags @> ARRAY[?]::text[]) RETURNING flags, status",
      flag, id, flag
    ])
    row = self.class.connection.exec_query(sql, "#{self.class.name} add_flag!").cast_values.first
    if row
      new_flags, new_status = row
      write_attribute(:flags, new_flags)
      write_attribute(:status, new_status)
    else
      write_attribute(:flags, Array(flags) | [flag])
    end
    clear_attribute_changes(%i[flags status])
    row ? 1 : 0
  end

  # The inverse of add_flag!: one guarded UPDATE against the row's current
  # flags, mirrored back from RETURNING the same way, so a flag another
  # writer appended meanwhile survives and the instance reports what the row
  # now holds. Status is never touched: a flag that has stopped being true
  # (no_draw_ticket once a ticket is minted) says nothing about review.
  # Returns the number of rows changed (0 or 1).
  def remove_flag!(flag)
    sql = self.class.sanitize_sql_array([
      "UPDATE #{self.class.quoted_table_name} SET flags = array_remove(flags, ?::text) " \
      "WHERE id = ? AND flags @> ARRAY[?]::text[] RETURNING flags",
      flag, id, flag
    ])
    row = self.class.connection.exec_query(sql, "#{self.class.name} remove_flag!").cast_values.first
    write_attribute(:flags, row ? row : Array(flags) - [flag])
    clear_attribute_changes(%i[flags])
    row ? 1 : 0
  end

  # The tag this fish carries, or carried: a species change away from Tagged
  # Walleye drops the tag (Catches::ApplyJudgeAction), and the draw views
  # still need to name the fish the winner was drawn from. The audit log
  # snapshots the tag before every judge action, so the most recent
  # snapshot that held one is the last tag the fish wore. One query, and
  # only once the tag is gone.
  def last_known_tag_number
    tag_number.presence ||
      judge_actions.where("COALESCE(before_state->>'tag_number', '') <> ''")
                   .order(created_at: :desc, id: :desc)
                   .pick(Arel.sql("before_state->>'tag_number'"))
  end

  enum :status, {
    pending_sync: 0,
    synced:       1,
    needs_review: 2,
    disputed:     3,
    disqualified: 4
  }

  # Hard upper bounds (inches) per species, to catch fat-finger length entries.
  # Keyed by downcased species name. Species not listed are unbounded.
  MAX_LENGTH_BY_SPECIES = {
    "perch" => 20, "walleye" => 50, "pike" => 70, "bass" => 35,
    "lake trout" => 55, "stocked trout" => 35, "tagged walleye" => 50,
    "other" => 200
  }.freeze
  PHOTO_CONTENT_TYPES = %w[image/jpeg image/png image/heic image/heif image/webp].freeze
  # Native full-res phone cameras can produce 100+ MP stills; a single
  # high-res shot can reach ~20 MB, and a 200 MP sensor more. 50 MB leaves
  # headroom so a legitimate full-resolution catch photo is never rejected.
  PHOTO_MAX_BYTES = 50.megabytes
  VIDEO_CONTENT_TYPES = %w[video/mp4 video/webm video/quicktime].freeze
  # The client only ever records mp4/webm (video_capture_controller candidates
  # list); quicktime covers iOS re-submits of camera-roll files. A few minutes
  # of 1080p release video fits comfortably under this.
  VIDEO_MAX_BYTES = 100.megabytes

  validates :length_inches, numericality: { greater_than: 0 }
  validates :length_unit, inclusion: { in: %w[inches centimeters] }
  validates :captured_at_device, presence: true
  validates :client_uuid, presence: true, uniqueness: true
  validate :photo_must_be_attached
  validate :photo_within_limits
  validate :reference_photo_within_limits
  validate :video_within_limits
  validate :length_within_species_cap
  validates :note, length: { maximum: 500 }, allow_blank: true

  # No character-set rule on purpose: tags get typed on a boat, and a stray
  # smart quote or space used to 422 the upload and strand the queued catch on
  # the phone with no way to edit it (2026-09-12 stuck tagged walleye). Accept
  # whatever was typed (upcased, trimmed, capped at the 16-char column) and let
  # an organizer correct the odd typo afterwards.
  before_validation :normalize_tag_number
  before_validation :default_length_unit
  validate :tag_number_required_for_tagged_walleye
  validates :tag_number, length: { maximum: 16 }, allow_blank: true

  before_validation :normalize_weight_text
  validates :weight_text, length: { maximum: 32 }, allow_blank: true

  def latest_approver
    # max_by walks the in-memory array so an eager-loaded :judge_actions stays
    # consumed; .order(:created_at).last would re-query Postgres per row and
    # defeat Leaderboards::Build's includes(:judge_actions => :judge_user).
    last = judge_actions.max_by(&:created_at)
    last&.approve? ? last.judge_user : nil
  end

  def disqualification_note
    return nil unless disqualified?
    # Walk the in-memory association (like latest_approver) so an eager-loaded
    # :judge_actions stays consumed instead of re-querying Postgres per row.
    # Tie-break on id so two disqualifies at the same created_at are
    # deterministic (latest timestamp, then highest id = most recently created).
    judge_actions.select(&:disqualify?).max_by { |a| [a.created_at, a.id] }&.note
  end

  # The stored form of a science tag: trimmed, upcased, blank -> nil. Public so
  # editors can tell whether a submitted tag actually differs from the stored one
  # before saving (and so the rule lives in exactly one place).
  def self.normalize_tag(value)
    value.to_s.strip.upcase.presence
  end

  # Max length (inches) for a species, or nil if the species is unbounded.
  # Single source of truth for the cap lookup (validation, controller, views).
  def self.length_cap_for(species)
    return nil if species.nil?
    MAX_LENGTH_BY_SPECIES[species.name.to_s.downcase]
  end

  private

  # Unconditional so a whitespace-only tag lands as nil (the form the editor's
  # changed-tag comparison assumes), not as a string of spaces.
  def normalize_tag_number
    self.tag_number = self.class.normalize_tag(tag_number)
  end

  def default_length_unit
    return if length_unit.present?
    self.length_unit = Catches::InferLoggedUnit.call(
      length_inches: length_inches,
      user_length_unit: user&.length_unit
    )
  end

  def normalize_weight_text
    trimmed = weight_text.to_s.strip
    self.weight_text = trimmed.presence
  end

  def tag_number_required_for_tagged_walleye
    return if species.nil?
    return unless species.tagged_walleye?
    return if tag_number.present?
    errors.add(:tag_number, "is required for Tagged Walleye catches")
  end

  def photo_must_be_attached
    errors.add(:photo, "is required") unless photo.attached?
  end

  def photo_within_limits
    attachment_within_limits(photo, :photo)
  end

  # An admin-uploaded reference photo supersedes the original as display_photo for
  # every viewer and is run through libvips variants on render, so it needs the
  # same content-type/size gate as the original — the form's accept= is
  # client-side only and a non-image would 500 the catch list/detail pages.
  def reference_photo_within_limits
    attachment_within_limits(reference_photo, :reference_photo)
  end

  # Shared content-type/size gate for both the original and reference photo.
  def attachment_within_limits(attachment, field)
    return unless attachment.attached?
    unless PHOTO_CONTENT_TYPES.include?(attachment.content_type)
      errors.add(field, "must be a JPEG, PNG, HEIC, or WebP image")
    end
    if attachment.byte_size.to_i > PHOTO_MAX_BYTES
      errors.add(field, "is larger than #{PHOTO_MAX_BYTES / 1.megabyte}MB")
    end
  end

  # `video` was permitted through the API with zero validation — an unbounded
  # authenticated upload of arbitrary bytes. Same shape of gate as the photos,
  # with video types/cap. Only checked while the video is being attached:
  # catches predating this gate can carry a video the old API accepted as-is,
  # and re-validating those on every save would make every later judge action
  # (ApplyJudgeAction's update!) raise on an untouched record.
  def video_within_limits
    return unless attachment_changes["video"].is_a?(ActiveStorage::Attached::Changes::CreateOne)
    unless VIDEO_CONTENT_TYPES.include?(video.content_type)
      errors.add(:video, "must be an MP4, WebM, or QuickTime video")
    end
    if video.byte_size.to_i > VIDEO_MAX_BYTES
      errors.add(:video, "is larger than #{VIDEO_MAX_BYTES / 1.megabyte}MB")
    end
  end

  def length_within_species_cap
    return if species.nil? || length_inches.nil?
    cap = Catch.length_cap_for(species)
    return if cap.nil? || length_inches <= cap
    errors.add(:length_inches, "for #{species.name} can't exceed #{cap}\"")
  end
end
