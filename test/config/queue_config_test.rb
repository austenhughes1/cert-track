require "test_helper"

# Solid Queue only runs jobs on the queues config/queue.yml lists: a job on any other queue
# waits forever without an error. And import jobs must stay off the worker that runs backups
# and mail, so an import backlog can't hold those up.
class QueueConfigTest < ActiveSupport::TestCase
  ENVIRONMENTS = %w[development test production].freeze
  PIPELINE_JOBS = [ Imports::ExpandJob, Imports::ExtractTextJob, Imports::AiExtractJob, Imports::ProcessExtractionJob ].freeze

  test "every job class's queue is polled by a worker in every environment" do
    assert_includes job_queues.keys, "default"

    ENVIRONMENTS.each do |env|
      job_queues.each do |queue, classes|
        assert polled?(env, queue), "#{env}: no worker in config/queue.yml polls #{queue.inspect} (#{classes.join(", ")})"
      end
    end
  end

  test "the import pipeline has its own queue, which the default worker never takes" do
    assert_equal [ "imports" ], PIPELINE_JOBS.map { |job| job.new.queue_name }.uniq
    assert_equal "default", ImportMailer.delivery_job.new("ImportMailer", "summary", "deliver_now", args: []).queue_name

    ENVIRONMENTS.each do |env|
      default_workers = workers(env).select { |queues| polls?(queues, "default") }
      assert_predicate default_workers, :any?, env
      default_workers.each do |queues|
        assert_not polls?(queues, "imports"), "#{env}: the worker for #{queues.inspect} would run import jobs too"
      end
    end
  end

  test "recurring tasks run on a polled queue" do
    recurring = YAML.load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)

    recurring.each do |env, tasks|
      tasks.each do |key, task|
        queue = task["queue"] || (task["class"] ? task["class"].constantize.new.queue_name : SolidQueue::RecurringJob.new.queue_name)
        assert polled?(env, queue.to_s), "#{env}: recurring task #{key} runs on #{queue.inspect}, which no worker polls"
      end
    end
  end

  private
    # { queue name => [job class names] } for every job class the app and its frameworks define.
    def job_queues
      @job_queues ||= begin
        Rails.application.eager_load!
        jobs = ActiveJob::Base.descendants.select(&:name).reject { |job| job <= ActionMailer::MailDeliveryJob }
          .map { |job| [ job.new.queue_name, job.name ] }
        mail = ActionMailer::Base.descendants.select(&:name).map do |mailer|
          [ mailer.delivery_job.new(mailer.name, "any", "deliver_now", args: []).queue_name, "#{mailer.name} mail" ]
        end
        (jobs + mail).group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
      end
    end

    # The queues each worker in config/queue.yml polls (Solid Queue's default is every queue).
    def workers(env)
      config = YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).fetch(env)
      config.fetch("workers").map { |worker| Array(worker.fetch("queues", "*")).map(&:to_s) }
    end

    def polled?(env, queue)
      workers(env).any? { |queues| polls?(queues, queue) }
    end

    # Solid Queue's rules: "*" is every queue, "name*" a prefix, anything else an exact name.
    def polls?(queues, queue)
      queues.any? { |pattern| pattern == "*" || pattern == queue || (pattern.end_with?("*") && queue.start_with?(pattern.delete_suffix("*"))) }
    end
end
