module SeasonPoints
  # The one formatter for season-point amounts everywhere they render — the
  # ladder text fields in the admin editor, the "what it pays" preview, and
  # the standings page — so a value can't read "3.333" in the form and "3.33"
  # in the table directly beneath it. Whole numbers render bare ("3"), halves
  # as "3.5", and anything finer is rounded to two decimals.
  class FormatAmount
    def self.call(amount)
      format("%.2f", amount.to_f).sub(/\.?0+\z/, "")
    end
  end
end
