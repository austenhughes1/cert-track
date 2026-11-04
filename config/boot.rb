ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

# A RAILS_MASTER_KEY exported for another app (say, in ~/.bashrc) would override config/master.key,
# and this app's credentials would fail to decrypt or, worse, be re-encrypted with that key. Where
# config/master.key exists, it wins. The production image has no master.key and uses the env var.
master_key_path = File.expand_path("master.key", __dir__)
if ENV["RAILS_MASTER_KEY"] && File.exist?(master_key_path) && ENV["RAILS_MASTER_KEY"].strip != File.read(master_key_path).strip
  warn "CertTrack: ignoring RAILS_MASTER_KEY from the environment; it doesn't match config/master.key."
  ENV.delete("RAILS_MASTER_KEY")
end

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
