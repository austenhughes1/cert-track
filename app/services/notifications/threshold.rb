module Notifications
  # Expiry thresholds, least to most urgent. Stored in ExpiryNotification#threshold.
  module Threshold
    ALL = ExpiryNotification.thresholds.keys.freeze # %w[d90 d60 d30 d7 expired]
    CREW = %w[d30 d7].freeze # the only thresholds crew members are emailed at

    LABELS = {
      "d90" => "90 days",
      "d60" => "60 days",
      "d30" => "30 days",
      "d7" => "7 days",
      "expired" => "Expired"
    }.freeze

    module_function

    # Most urgent threshold crossed with days_left to go, or nil (see ExpiryNotification.threshold_for).
    def for_days_left(days_left)
      ExpiryNotification.threshold_for(days_left)
    end

    def urgency(threshold)
      ExpiryNotification.thresholds.fetch(threshold.to_s)
    end

    # True when already_sent is threshold itself or a more urgent one. nil already_sent = nothing sent.
    def covered?(threshold, already_sent)
      already_sent.present? && urgency(already_sent) >= urgency(threshold)
    end

    # Most urgent of the given thresholds, or nil.
    def most_urgent(thresholds)
      thresholds.compact.max_by { |threshold| urgency(threshold) }
    end

    def crew?(threshold)
      CREW.include?(threshold.to_s)
    end

    def label(threshold)
      LABELS.fetch(threshold.to_s)
    end
  end
end
