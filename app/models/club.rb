class Club < ApplicationRecord
  has_many :club_memberships, dependent: :destroy
  has_many :members, through: :club_memberships, source: :user
  has_many :tournaments, dependent: :destroy
  has_many :boats, dependent: :destroy
  has_many :tournament_templates, dependent: :destroy
  has_many :rules_revisions, class_name: "ClubRulesRevision", dependent: :destroy
  enum :active_rules_season, { open_water: 0, ice: 1 }, prefix: true
  enum :banner_style, { info: 0, good: 1, alert: 2 }, default: :info

  enum :season_points_scheme,
       { tiered_ladders: 0, base_ladder: 1, full_field: 2 },
       prefix: :season_points_scheme,
       default: :tiered_ladders

  # Fixed field-size bands, by entry (boat/team) count. The last band is
  # open-ended so a big night can't fall through a hole.
  SEASON_POINTS_BANDS = [1..9, 10..19, 20..29, 30..Float::INFINITY].freeze

  # Single source of truth for the band labels and a representative sample
  # field size, derived from SEASON_POINTS_BANDS. Used by the admin editor
  # (labels + preview table) and the member-facing "how points work"
  # explainer so all three can't drift out of sync with each other or with
  # the bands themselves. The sample is the TOP of each band (the open-ended
  # last band uses its lower bound instead) — not a mid-band number — so a
  # raised season_points_min_entries can't make a band that genuinely does
  # pay placement points look like it never pays.
  def self.season_points_bands
    SEASON_POINTS_BANDS.map { |band| band_row(band.begin, band) }
  end

  def self.band_row(from, band)
    if band.end == Float::INFINITY
      { label: "#{from}+", sample: from }
    else
      { label: "#{from}–#{band.end}", sample: band.end }
    end
  end
  private_class_method :band_row

  # The bands as THIS club actually pays them: the first band starts at
  # season_points_min_entries (a club with a minimum of 5 pays the 1–9 ladder
  # to 5–9-entry nights, and a 4-boat night is attendance only), and any band
  # that falls wholly below the minimum is dropped. The admin preview and the
  # member-facing explainer both read this so their labels can't promise
  # placement points for a field size the minimum rules out.
  def effective_season_points_bands
    min = season_points_min_entries.to_i
    SEASON_POINTS_BANDS.filter_map do |band|
      from = [band.begin, min].max
      next if band.end != Float::INFINITY && from > band.end
      self.class.send(:band_row, from, band)
    end
  end

  # Field sizes the minimum rules out entirely ("1–4" for a minimum of 5),
  # or nil when every field size can place.
  def season_points_attendance_only_label
    min = season_points_min_entries.to_i
    return nil if min <= 1
    min == 2 ? "1" : "1–#{min - 1}"
  end

  validates :name, presence: true, uniqueness: true
  validate :season_points_ladders_are_well_formed
  validate :season_points_base_ladder_is_well_formed
  validate :season_points_tier_multipliers_are_well_formed
  # Upper bounds match the columns (decimal(5,2) and int4): without them a
  # value that passes `valid?` raises ActiveRecord::RangeError at save — a 500
  # instead of a 422 on the admin form.
  validates :season_points_attendance,
            numericality: { greater_than_or_equal_to: 0, less_than: 1000 }
  validates :season_points_min_entries,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than: 2**31 }

  def current_rules_revision
    ClubRulesRevision.latest_for(club: self, season: active_rules_season)
  end

  # Comma-separated form input ("9, 6, 3") → the jsonb arrays. parse_points_list
  # returns nil when any token isn't a number, and each writer flags only its
  # OWN attribute — so junk in the base ladder doesn't put an error on the
  # tiered ladders too.
  #
  # The four submitted strings are positional (one per SEASON_POINTS_BANDS
  # entry) and must stay that way. `compact`-ing out a band that failed to
  # parse used to shift every later band down one slot — on 422 the form
  # would silently re-render band 3's ladder under band 2's label, and if the
  # admin then "fixed" what they saw and resubmitted, it would save a ladder
  # against the wrong band with no error at all. So: never reassign
  # season_points_ladders when any band is invalid (the record is already
  # marked invalid via @season_points_ladders_invalid), and stash the raw
  # submitted strings so the re-rendered form echoes exactly what was typed,
  # in place, including the offending band.
  #
  # The same rule holds for the base ladder and the tier multipliers: on a
  # parse failure the saved column is left alone (the preview beneath the form
  # says "saved settings", and running it against an in-memory [] showed blank
  # cells or "0, 0, 0") and the raw text is stashed so the field re-renders as
  # typed instead of empty.
  #
  # Writing the jsonb column directly (season_points_ladders= etc.) clears the
  # stash and the failure flag, and so does #reload — otherwise an instance
  # that once saw bad text would stay invalid? forever even after the column
  # held good data again.
  def season_points_ladders_text=(values)
    texts = Array(values).map(&:to_s)
    parsed = texts.map { |v| parse_points_list(v) }
    if parsed.any?(&:nil?)
      @season_points_ladders_invalid = true
    else
      self.season_points_ladders = parsed
    end
    @season_points_ladders_text = texts
  end

  def season_points_base_ladder_text=(value)
    parsed = parse_points_list(value)
    if parsed
      self.season_points_base_ladder = parsed
    else
      @season_points_base_ladder_text = value.to_s
      @season_points_base_ladder_invalid = true
    end
  end

  def season_points_tier_multipliers_text=(value)
    parsed = parse_points_list(value)
    if parsed
      self.season_points_tier_multipliers = parsed
    else
      @season_points_tier_multipliers_text = value.to_s
      @season_points_tier_multipliers_invalid = true
    end
  end

  def season_points_ladders=(value)
    @season_points_ladders_text = nil
    @season_points_ladders_invalid = false
    super
  end

  def season_points_base_ladder=(value)
    @season_points_base_ladder_text = nil
    @season_points_base_ladder_invalid = false
    super
  end

  def season_points_tier_multipliers=(value)
    @season_points_tier_multipliers_text = nil
    @season_points_tier_multipliers_invalid = false
    super
  end

  def reload(*)
    @season_points_ladders_text = @season_points_base_ladder_text = @season_points_tier_multipliers_text = nil
    @season_points_ladders_invalid = @season_points_base_ladder_invalid = @season_points_tier_multipliers_invalid = false
    super
  end

  # Prefers the raw text just submitted via season_points_ladders_text= (so a
  # 422 re-render shows the admin exactly what they typed, band-for-band,
  # even for a band that failed to parse) and falls back to formatting the
  # persisted value when the writer hasn't run this request (a plain GET).
  def season_points_ladder_text(index)
    if @season_points_ladders_text
      @season_points_ladders_text[index].to_s
    else
      Array(season_points_ladders[index]).map { |n| format_points_amount(n) }.join(", ")
    end
  end

  def season_points_base_ladder_text
    @season_points_base_ladder_text ||
      Array(season_points_base_ladder).map { |n| format_points_amount(n) }.join(", ")
  end

  def season_points_tier_multipliers_text
    @season_points_tier_multipliers_text ||
      Array(season_points_tier_multipliers).map { |n| format_points_amount(n) }.join(", ")
  end

  private

  # Same formatter as the preview and the standings page (see
  # SeasonPoints::FormatAmount), so a value can't read one way in the form
  # and another way in the table beneath it.
  def format_points_amount(amount)
    SeasonPoints::FormatAmount.call(amount)
  end

  # nil means "at least one token wasn't a number" — the caller decides which
  # attribute to hang the error on. Amounts are rounded to two decimals on
  # the way in so what is stored is exactly what every reader shows; a token
  # that overflows Float (400 nines → Infinity, which jsonb would serialise
  # as null and read back as 0) is treated as not-a-number.
  def parse_points_list(value)
    tokens = value.to_s.split(",").map(&:strip)
    return nil if tokens.empty? || tokens.any? { |t| !t.match?(/\A\d+(\.\d+)?\z/) }
    amounts = tokens.map(&:to_f)
    return nil unless amounts.all?(&:finite?)
    amounts.map { |a| a.round(2) }
  end

  def season_points_ladders_are_well_formed
    if @season_points_ladders_invalid
      errors.add(:season_points_ladders, "must be numbers separated by commas")
      return
    end
    ladders = season_points_ladders
    unless ladders.is_a?(Array) && ladders.size == SEASON_POINTS_BANDS.size
      errors.add(:season_points_ladders, "needs one ladder per field-size band")
      return
    end
    ladders.each { |ladder| validate_ladder(ladder, :season_points_ladders) }
  end

  def season_points_base_ladder_is_well_formed
    if @season_points_base_ladder_invalid
      errors.add(:season_points_base_ladder, "must be numbers separated by commas")
      return
    end
    validate_ladder(season_points_base_ladder, :season_points_base_ladder)
  end

  def season_points_tier_multipliers_are_well_formed
    if @season_points_tier_multipliers_invalid
      errors.add(:season_points_tier_multipliers, "must be numbers separated by commas")
      return
    end
    multipliers = season_points_tier_multipliers
    unless multipliers.is_a?(Array) && multipliers.size == SEASON_POINTS_BANDS.size
      errors.add(:season_points_tier_multipliers, "needs one multiplier per field-size band")
      return
    end
    unless multipliers.all? { |m| m.is_a?(Numeric) }
      errors.add(:season_points_tier_multipliers, "must be numbers")
      return
    end
    return if multipliers.all?(&:positive?)
    errors.add(:season_points_tier_multipliers, "must all be greater than zero")
  end

  # Requires actual Numeric entries rather than coercing with #to_f: a jsonb
  # column happily stores strings, and a club saved via update_column (or any
  # other path that skips these callbacks) can end up with a ladder like
  # ["9", "6", "3"]. That used to pass every check here (to_f coerces) and
  # only blow up downstream, as a TypeError, the first time
  # SeasonPointsAwarded tried to add a String to an accumulator — a 500 on a
  # member-facing page. Both the text writers (which produce Floats) and the
  # jsonb column defaults (Integers) satisfy Numeric, so legitimate data
  # stays valid.
  def validate_ladder(ladder, attribute)
    unless ladder.is_a?(Array) && ladder.any?
      errors.add(attribute, "needs at least one place")
      return
    end
    unless ladder.all? { |amount| amount.is_a?(Numeric) && amount.finite? }
      errors.add(attribute, "must be numbers")
      return
    end
    if ladder.any?(&:negative?)
      errors.add(attribute, "can't include negative amounts")
    end
    return if ladder.each_cons(2).all? { |a, b| a >= b }
    errors.add(attribute, "must be listed highest first")
  end
end
