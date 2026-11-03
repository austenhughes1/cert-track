require "test_helper"

# Production gets its environment only from config/deploy.yml, so a variable the app reads
# but deploy.yml never mentions is silently unset in production.
class DeployConfigTest < ActiveSupport::TestCase
  ENV_READ = /ENV(?:\.fetch)?[\[(]\s*"([A-Z][A-Z0-9_]*)"/

  test "every ENV variable app/ reads is declared in config/deploy.yml" do
    declared = deploy_yml_source.scan(/\b[A-Z][A-Z0-9_]+\b/).to_set
    read = Rails.root.glob("app/**/*.{rb,erb}").flat_map { |path| path.read.scan(ENV_READ).flatten }.uniq

    assert_empty read.reject { |name| declared.include?(name) },
      "set these under env in config/deploy.yml (or leave them commented out there with a note), " \
      "and add them to the env tables in docs/DEPLOY.md and docs/PLAN.md"
  end

  test "every deployed variable is in the runbook's env table" do
    runbook = Rails.root.join("docs/DEPLOY.md").read

    assert_empty deployed_env_names.reject { |name| runbook.include?("`#{name}`") }
  end

  # Crew expiry notices ask crew to reply with their renewed certificate.
  test "OFFICE_EMAIL is set to an inbox outside the send-only mail domain" do
    office = deploy_env.dig("clear", "OFFICE_EMAIL")
    sending_domain = deploy_env.dig("clear", "MAIL_FROM").to_s[/@([^>\s]+)/, 1]

    assert_match URI::MailTo::EMAIL_REGEXP, office.to_s
    assert sending_domain.present?
    assert_not office.downcase.end_with?("@#{sending_domain.downcase}", ".#{sending_domain.downcase}"),
      "#{sending_domain} has no MX, so replies to #{office} would bounce"
  end

  private
    def deploy_yml_source
      @deploy_yml_source ||= Rails.root.join("config/deploy.yml").read
    end

    def deploy_env
      @deploy_env ||= YAML.safe_load(ERB.new(deploy_yml_source).result, aliases: true).fetch("env")
    end

    def deployed_env_names
      deploy_env.fetch("clear").keys + deploy_env.fetch("secret")
    end
end
