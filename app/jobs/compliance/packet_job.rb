module Compliance
  # Builds a project's compliance packet zip (Compliance::PacketBuilder) and attaches it
  # as project.packet. The "building" and "failed" states live in Rails.cache rather
  # than a column: a state written at or before project.packet_built_at is stale, and a
  # building entry expires after BUILD_TIMEOUT in case a worker dies mid-build.
  #
  #   Compliance::PacketJob.request(project)  # record "building" and enqueue
  #   Compliance::PacketJob.state(project)    # => "building", "failed" or nil
  class PacketJob < ApplicationJob
    BUILD_TIMEOUT = 15.minutes
    FAILURE_TTL = 1.day

    queue_as :default
    limits_concurrency to: 1, key: ->(project) { project }, duration: BUILD_TIMEOUT
    discard_on ActiveJob::DeserializationError

    class << self
      def request(project)
        write_state(project, "building", expires_in: BUILD_TIMEOUT)
        perform_later(project)
      end

      def state(project)
        entry = Rails.cache.read(state_key(project))
        return unless entry.is_a?(Hash)

        at = Time.zone.parse(entry["at"].to_s)
        return if at.nil? || (project.packet_built_at && project.packet_built_at >= at)

        entry["state"]
      end

      def building?(project)
        state(project) == "building"
      end

      def state_key(project)
        "compliance/packet_state/#{project.id}"
      end

      def write_state(project, state, expires_in:)
        Rails.cache.write(state_key(project), { "state" => state, "at" => Time.current.iso8601(6) }, expires_in: expires_in)
      end
    end

    def perform(project)
      PacketBuilder.new(project).attach!
      Rails.cache.delete(self.class.state_key(project))
    rescue StandardError
      self.class.write_state(project, "failed", expires_in: FAILURE_TTL)
      raise
    end
  end
end
