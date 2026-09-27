module Catches
  # Turns the heat map page's query params into safe filter values. Nothing a
  # member types can raise: an invalid value falls back to its default, and a
  # reversed range is swapped.
  class HeatMapFilters
    DEFAULT_SPAN = 12.months
    # catches.length_inches is decimal(5,2); anything above this cannot match
    # and a larger number would overflow the comparison.
    LENGTH_CAP = 999.0

    attr_reader :species_ids, :min_length, :max_length, :from, :to

    def self.from_params(params, species:, today: ::Date.current)
      new(params, species: species, today: today)
    end

    def initialize(params, species:, today:)
      @species_ids = parse_species(params, species)
      @min_length, @max_length = [parse_length(params[:min_length]), parse_length(params[:max_length])]
      @min_length, @max_length = @max_length, @min_length if @min_length && @max_length && @min_length > @max_length
      @from = parse_date(params[:from]) || (today - DEFAULT_SPAN)
      @to = parse_date(params[:to]) || today
      @from, @to = @to, @from if @from > @to
    end

    def to_query
      { species_ids: species_ids, min_length: min_length, max_length: max_length, from: from, to: to }
    end

    private

    # The form sends a hidden filtered=1. With it, the ticked boxes are the
    # whole truth (none ticked means none shown). Without it, this is a first
    # visit and every species is on.
    def parse_species(params, species)
      all_ids = species.map(&:id)
      return all_ids if params[:filtered].blank?

      ticked = params[:species]
      return [] unless ticked.is_a?(::Array)

      all_ids & ticked.filter_map { |value| Integer(value, exception: false) if value.is_a?(::String) }
    end

    def parse_length(value)
      return nil unless value.is_a?(::String)

      number = Float(value.strip, exception: false)
      return nil if number.nil? || !number.finite? || number.negative?

      [number, LENGTH_CAP].min
    end

    def parse_date(value)
      return nil unless value.is_a?(::String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      ::Date.strptime(value, "%Y-%m-%d")
    rescue ::Date::Error
      nil
    end
  end
end
