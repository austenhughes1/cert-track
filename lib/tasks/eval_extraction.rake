namespace :certtrack do
  desc 'Score AI extraction on test/fixtures/import_samples: bin/rails "certtrack:eval_extraction[provider,model,vision_model]" ' \
    "(SAMPLES_DIR=path for another folder, VISION_ONLY=1 to score the vision model alone; docs/IMPORT_SPIKE.md)"
  task :eval_extraction, %i[provider model vision_model] => :environment do |_task, args|
    dir = ENV["SAMPLES_DIR"].presence || Rails.root.join("test/fixtures/import_samples")
    runner = Imports::Eval::Runner.new(dir: dir, provider: args[:provider], model: args[:model],
      vision_model: args[:vision_model], vision_only: ENV["VISION_ONLY"] == "1", progress: $stderr)
    report = runner.call
    puts report
  rescue Imports::Eval::Runner::NoSamples, Ai::ConfigurationError => error
    abort error.message
  end
end
