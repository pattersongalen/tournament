class Tournament < ApplicationRecord
  belongs_to :club
  belongs_to :drawn_winning_placement, class_name: "CatchPlacement", optional: true
  belongs_to :drawn_by_user,           class_name: "User",           optional: true
  has_many :scoring_slots, dependent: :destroy
  accepts_nested_attributes_for :scoring_slots, allow_destroy: true,
                                reject_if: ->(attrs) { attrs["species_id"].blank? }
  has_many :tournament_entries, dependent: :destroy
  has_many :tournament_judges, dependent: :destroy
  has_many :tournament_deputies, dependent: :destroy
  has_many :catch_placements, dependent: :destroy
  has_many :judge_users, through: :tournament_judges, source: :user
  has_many :deputy_users, through: :tournament_deputies, source: :user
  enum :mode, { solo: 0, team: 1 }, prefix: true
  enum :format, { standard: 0, big_fish_season: 1, hidden_length: 2, biggest_vs_smallest: 3, fish_train: 4, tagged: 5, smallest_fish: 6, pro_walleye: 7, bingo: 8, progressive_length: 9, beat_the_average: 10, random_bag: 11 }, prefix: true

  validates :name, :mode, :starts_at, :ends_at, presence: true
  validate :ends_at_after_starts_at
  validate :blind_leaderboard_locked_after_start, on: :update
  validate :format_locked_after_start, on: :update
  validate :train_cars_locked_after_start, on: :update
  validate :scoring_slots_locked_after_start, on: :update
  validate :big_fish_season_requires_solo
  validate :big_fish_season_requires_one_scoring_slot
  validate :hidden_length_requires_one_scoring_slot
  validate :hidden_length_target_locked_once_set
  validate :hidden_length_target_in_range
  validate :biggest_vs_smallest_requires_one_scoring_slot
  validate :fish_train_pool_size_between_1_and_3
  validate :fish_train_train_cars_length_between_3_and_6
  validate :fish_train_train_cars_species_in_pool
  validate :tagged_requires_solo
  validate :tagged_requires_one_tagged_walleye_scoring_slot
  validate :pro_walleye_requires_one_walleye_scoring_slot
  before_validation :force_pro_walleye_slot_count
  validate :progressive_length_requires_one_scoring_slot
  before_validation :force_progressive_length_slot_count
  before_validation :force_beat_the_average_blind
  validate :beat_the_average_requires_scoring_slots
  before_validation :force_random_bag_blind
  validate :random_bag_requires_scoring_slots
  validate :random_bag_range_valid
  validate :target_range_locked_after_start, on: :update
  before_validation :assign_bingo_layout
  validate :bingo_layout_well_formed
  validate :bingo_layout_locked_after_start, on: :update
  validate :bingo_not_blind
  validate :bingo_species_present
  validate :link_group_id_only_on_team_tournaments

  scope :active_at, ->(time) {
    where("starts_at <= ?", time).where("ends_at IS NULL OR ends_at >= ?", time)
  }

  def active?(at: Time.current)
    starts_at <= at && (ends_at.nil? || ends_at >= at)
  end

  def started?(at: Time.current)
    starts_at.present? && starts_at <= at
  end

  def ended?(at: Time.current)
    ends_at.present? && ends_at < at
  end

  def blind?(at: Time.current)
    blind_leaderboard? && active?(at: at)
  end

  def friendly?
    !judged?
  end

  # Whether a judge's "force into slot index" manual override is meaningful here.
  # Only the slot-based top-N formats and append-only Fish Train have a durable,
  # positional slot_index. The length-derived formats (BvS / Smallest Fish / Pro
  # Walleye) re-derive the whole basket from length, and the every-catch formats
  # (Hidden Length / Tagged) place every catch — so a forced slot is meaningless
  # and would be silently reverted by the next reconcile.
  def supports_forced_slot?
    format_standard? || format_big_fish_season? || format_fish_train?
  end

  # The drawn fish's ticket can be retired after the draw (a DQ, a species
  # correction to plain walleye). Resolved by catch, not by row: a GPS fix
  # re-issues the ticket as a new row and the fish is still the winner, and
  # a winner recorded before the FK followed re-issued rows still resolves.
  def drawn_winner_voided?
    winner = drawn_winning_placement
    winner.present? && !catch_placements.active.exists?(catch_id: winner.catch_id)
  end

  # Whether a re-draw has anything to run over. With no active ticket the
  # draw service refuses, so the views offer nothing rather than a button
  # that fails.
  def tickets_remain?
    catch_placements.active.exists?
  end

  # After the drawn winner's ticket is retired and re-issued as a new row (a
  # judge correction, or a member dropped from a boat and put on another with
  # the backfill sweep), keep the recorded winner on the live row so anything
  # trusting the FK sees an active ticket. Called by PlaceInSlots as it mints
  # the row, the one place every re-issue passes through. One guarded UPDATE
  # against the current DB value, so a stale in-memory winner is never
  # written back and a ticket for any other fish touches no row (and takes no
  # lock). Runs under the entry lock and the tournament key-share lock
  # PlaceInSlots holds; DrawTaggedWinner takes both for update, so it can't
  # race a draw.
  def repoint_drawn_winner!(ticket)
    Tournament.where(id: id)
              .where(drawn_winning_placement_id: CatchPlacement.where(catch_id: ticket.catch_id).select(:id))
              .update_all(drawn_winning_placement_id: ticket.id)
  end

  # Other tournaments sharing this one's link group. Club-scoped as well as
  # group-scoped: a group id is generated per link, but scoping to the club
  # means a stray duplicate can never reach across clubs.
  def linked_tournaments
    return [] if link_group_id.blank?
    Tournament.where(club_id: club_id, link_group_id: link_group_id)
              .where.not(id: id)
              .to_a
  end

  def linked?
    linked_tournaments.any?
  end

  after_save :schedule_lifecycle_jobs

  private

  def ends_at_after_starts_at
    return if starts_at.blank? || ends_at.blank?
    return if ends_at > starts_at
    errors.add(:ends_at, "must be after the start time")
  end

  def schedule_lifecycle_jobs
    if saved_change_to_starts_at? && starts_at.future?
      TournamentLifecycleAnnounceJob.set(wait_until: starts_at).perform_later(tournament_id: id, kind: "started")
    end
    if saved_change_to_ends_at? && ends_at&.future?
      TournamentLifecycleAnnounceJob.set(wait_until: ends_at).perform_later(tournament_id: id, kind: "ended")
    end
  end

  def big_fish_season_requires_solo
    return unless format_big_fish_season?
    return if mode_solo?
    errors.add(:format, "Big Fish Season tournaments must be solo")
  end

  def big_fish_season_requires_one_scoring_slot
    return unless format_big_fish_season?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.size == 1
    errors.add(:scoring_slots, "Big Fish Season tournaments must have exactly one species configured")
  end

  def hidden_length_requires_one_scoring_slot
    return unless format_hidden_length?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.size == 1
    errors.add(:scoring_slots, "Hidden Length tournaments must have exactly one species configured")
  end

  def biggest_vs_smallest_requires_one_scoring_slot
    return unless format_biggest_vs_smallest?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.size == 1
    errors.add(:scoring_slots, "Biggest vs Smallest tournaments must have exactly one species configured")
  end

  def hidden_length_target_locked_once_set
    # "Locked" means once non-nil, the value can't be changed *or* cleared back to nil.
    return unless will_save_change_to_hidden_length_target?
    return if hidden_length_target_was.nil?
    errors.add(:hidden_length_target, "can't be changed once set")
  end

  def hidden_length_target_in_range
    return unless format_hidden_length?
    return if hidden_length_target.blank?
    target = hidden_length_target.to_d
    in_bounds = target >= "12.00".to_d && target <= "22.00".to_d
    on_quarter = (target * 4) == (target * 4).truncate
    return if in_bounds && on_quarter
    errors.add(:hidden_length_target, "must be a quarter-inch step between 12.00 and 22.00")
  end

  def blind_leaderboard_locked_after_start
    return unless will_save_change_to_blind_leaderboard?
    return if starts_at.blank? || starts_at > Time.current
    errors.add(:blind_leaderboard, "can't be changed once the tournament has started")
  end

  def format_locked_after_start
    return unless will_save_change_to_format?
    return if starts_at.blank? || starts_at > Time.current
    errors.add(:format, "can't be changed once the tournament has started")
  end

  def train_cars_locked_after_start
    return unless will_save_change_to_train_cars?
    return if starts_at.blank? || starts_at > Time.current
    errors.add(:train_cars, "can't be changed once the tournament has started")
  end

  # The species-and-quantity set is fixed once a tournament is active — the same
  # "no changes after start" rule as format/train_cars, applied to the scoring
  # slots. Blocks adding, removing, or editing a slot (species or slot_count).
  # This makes the "active tournaments never change" operating rule real in code,
  # and closes the mid-tournament slot-removal case that would otherwise strand
  # already-scored placements for a species the tournament no longer ranks. Same-
  # value reassignments (e.g. force_pro_walleye_slot_count pinning slot_count) are
  # not dirty, so a plain save of a started tournament still passes.
  def scoring_slots_locked_after_start
    return if starts_at.blank? || starts_at > Time.current
    return unless scoring_slots.any? { |s| s.new_record? || s.marked_for_destruction? || s.changed? }
    errors.add(:scoring_slots, "can't be changed once the tournament has started")
  end

  def fish_train_pool_size_between_1_and_3
    return unless format_fish_train?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    distinct_count = remaining.map(&:species_id).uniq.size
    return if distinct_count.between?(1, 3)
    errors.add(:scoring_slots, "Fish Train tournaments must have between 1 and 3 species in the pool")
  end

  def fish_train_train_cars_length_between_3_and_6
    return unless format_fish_train?
    size = (train_cars || []).size
    return if size.between?(3, 6)
    errors.add(:train_cars, "Fish Train must have between 3 and 6 cars")
  end

  def fish_train_train_cars_species_in_pool
    return unless format_fish_train?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    pool_species_ids = remaining.map(&:species_id).compact.uniq
    cars = train_cars || []
    return if cars.empty?
    return if cars.all? { |sp_id| pool_species_ids.include?(sp_id) }
    errors.add(:train_cars, "Fish Train cars must reference species in the pool")
  end

  def tagged_requires_solo
    return unless format_tagged?
    return if mode_solo?
    errors.add(:format, "Tagged Walleye tournaments must be solo")
  end

  def tagged_requires_one_tagged_walleye_scoring_slot
    return unless format_tagged?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    unless remaining.size == 1 && remaining.first.species&.tagged_walleye?
      errors.add(:scoring_slots,
                 "Tagged Walleye tournaments must have exactly one scoring slot for the Tagged Walleye species")
    end
  end

  def pro_walleye_requires_one_walleye_scoring_slot
    return unless format_pro_walleye?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    unless remaining.size == 1 && remaining.first.species&.walleye?
      errors.add(:scoring_slots,
                 "Pro Walleye tournaments must have exactly one scoring slot for the Walleye species")
    end
  end

  # The basket is a fixed 5 fish (at most 2 over 55 cm). PlaceInSlots/
  # ReconcileProWalleye enforce the basket size and over-cap themselves, but the
  # leaderboard `complete` flag and the winners/season-points capacity math read
  # scoring_slots.sum(:slot_count) — so pin the single slot to the basket size
  # here (the slot-count field is "ignored" in the UI).
  def force_pro_walleye_slot_count
    return unless format_pro_walleye?
    scoring_slots.reject(&:marked_for_destruction?).each { |s| s.slot_count = Catches::ProWalleye::BASKET_SIZE }
  end

  def progressive_length_requires_one_scoring_slot
    return unless format_progressive_length?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.size == 1
    errors.add(:scoring_slots, "Progressive Length tournaments must have exactly one species configured")
  end

  # The ladder is unbounded, so the slot-count field is meaningless here. Pin it
  # to 1 (the UI labels it "ignored") so the leaderboard `complete` flag and the
  # winners/season-points capacity math, which read scoring_slots.sum(:slot_count),
  # get a sane number. Same reasoning as force_pro_walleye_slot_count. A no-op
  # reassignment leaves the record clean, so scoring_slots_locked_after_start
  # still permits saving a started tournament.
  def force_progressive_length_slot_count
    return unless format_progressive_length?
    scoring_slots.reject(&:marked_for_destruction?).each { |s| s.slot_count = 1 }
  end

  # Beat the Average is inherently blind: catches are hidden between teams during
  # play and the winning average is revealed only at the end. Force the flag on so
  # the whole blind machinery (ViewerScope own-entry-only view, reveal at ends_at,
  # push suppression) engages without the organizer having to remember the checkbox.
  # Idempotent, so a plain save of a started tournament stays clean and passes
  # blind_leaderboard_locked_after_start.
  def force_beat_the_average_blind
    return unless format_beat_the_average?
    self.blind_leaderboard = true
  end

  # One or more species, like Standard. Every catch of any configured species
  # counts toward the single combined average.
  def beat_the_average_requires_scoring_slots
    return unless format_beat_the_average?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.any?
    errors.add(:scoring_slots, "Catch the Average tournaments must have at least one species configured")
  end

  # Random Bag is blind during play (each team sees only its own target and bag);
  # the full ranking is revealed at ends_at. Force the flag on exactly like
  # force_beat_the_average_blind so the blind machinery engages automatically.
  def force_random_bag_blind
    return unless format_random_bag?
    self.blind_leaderboard = true
  end

  # One or more species, like Standard/Beat the Average. Every catch of any
  # configured species is eligible for the bag.
  def random_bag_requires_scoring_slots
    return unless format_random_bag?
    remaining = scoring_slots.reject(&:marked_for_destruction?)
    return if remaining.any?
    errors.add(:scoring_slots, "Random Bag tournaments must have at least one species configured")
  end

  # Per-tournament target bounds. Equal min == max is a legal "fixed shared
  # target" configuration (every team draws the same number), so the rule is
  # max >= min, not max > min.
  def random_bag_range_valid
    return unless format_random_bag?
    if target_min_inches.blank? || target_max_inches.blank?
      errors.add(:base, "Random Bag tournaments need a target range")
      return
    end
    errors.add(:target_min_inches, "must be at least 0") if target_min_inches.to_d.negative?
    if target_max_inches.to_d < target_min_inches.to_d
      errors.add(:target_max_inches, "must be greater than or equal to the minimum")
    end
    # Targets are drawn on the 1/4-inch grid anchored at the minimum
    # (RandomBag::AssignTarget), so an off-grid bound is never drawable and would
    # silently narrow the announced range — e.g. a 100.10" max can't be hit from a
    # 70" min. Require both bounds on the 1/4-inch grid so every configured value
    # is reachable.
    step = RandomBag::AssignTarget::STEP
    if (target_min_inches.to_d % step).nonzero?
      errors.add(:target_min_inches, "must be in 1/4-inch steps")
    end
    if (target_max_inches.to_d % step).nonzero?
      errors.add(:target_max_inches, "must be in 1/4-inch steps")
    end
  end

  # The per-team target draw depends on target_min_inches/target_max_inches, and
  # targets are assigned lazily once the tournament starts. Editing the range mid-
  # tournament would desync already-drawn targets from newly-assigned ones, so lock
  # it at start like format/blind/scoring_slots. Same-value re-saves stay clean
  # (not dirty), so a plain save of a started tournament still passes.
  def target_range_locked_after_start
    return unless format_random_bag?
    return unless will_save_change_to_target_min_inches? || will_save_change_to_target_max_inches?
    return if starts_at.blank? || starts_at > Time.current
    errors.add(:base, "Target range can't be changed once the tournament has started")
  end

  def assign_bingo_layout
    return unless format_bingo?
    return if bingo_layout.present?
    self.bingo_layout = Catches::Bingo::Tasks.random_layout
  end

  def bingo_layout_well_formed
    return unless format_bingo?
    layout = bingo_layout
    unless layout.is_a?(Array) && layout.size == 25 &&
           layout.all?(String) &&
           layout[Catches::Bingo::Tasks::FREE_INDEX] == "free" &&
           (layout - ["free"]).sort == Catches::Bingo::Tasks.keys.sort
      errors.add(:bingo_layout, "must be the 24 bingo tasks plus the free center cell")
    end
  end

  # Mirror scoring_slots_locked_after_start: the shuffled card freezes at start.
  def bingo_layout_locked_after_start
    return unless format_bingo?
    return unless will_save_change_to_bingo_layout?
    return if starts_at.blank? || starts_at > Time.current
    # Switching format to bingo after start also auto-assigns a layout (nil -> array).
    # That rejection belongs to format_locked_after_start; don't pile on a misleading
    # "layout can't be changed" error when the layout only appeared because of the
    # (already-blocked) format switch.
    return if will_save_change_to_format?
    errors.add(:bingo_layout, "can't be changed once the tournament has started")
  end

  def bingo_not_blind
    return unless format_bingo?
    errors.add(:blind_leaderboard, "isn't available for Bingo tournaments") if blind_leaderboard?
  end

  # The bingo card references Walleye/Perch/Pike by canonical name. If any is
  # absent (never seeded, or renamed), those squares can never fill and blackout
  # becomes unreachable — so surface it loudly at save time instead of shipping a
  # silently broken card.
  #
  # Only guard when a bingo card is actually being wired up: a new tournament, or a
  # not-yet-started tournament switching to bingo. Re-running on every later edit
  # would lock organizers out of an existing bingo tournament the instant a global
  # species is renamed — an unrelated edit (fixing the name, extending ends_at)
  # can't fix that, so blocking it just strands the tournament. A post-start format
  # switch is skipped too: format_locked_after_start already rejects it, so don't
  # pile on a misleading "species missing" base error (mirrors
  # bingo_layout_locked_after_start).
  def bingo_species_present
    return unless format_bingo?
    return unless new_record? || (will_save_change_to_format? && !started?)
    missing = Catches::Bingo::EvaluateCard.species_id_map.select { |_, id| id.nil? }.keys
    return if missing.empty?
    errors.add(:base, "Bingo needs these species defined first: #{missing.map { |s| s.to_s.titleize }.join(', ')}")
  end

  # Link groups are team-mode only: solo tournaments (the season-long Big Walleye
  # Local/Travel pair) stay independent by design.
  def link_group_id_only_on_team_tournaments
    return if link_group_id.blank?
    return if mode_team?
    errors.add(:link_group_id, "is only available for team tournaments")
  end
end
