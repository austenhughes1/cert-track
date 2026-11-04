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

  # Mail goes out through a Google Workspace account (smtp.gmail.com), and Gmail rewrites any
  # From that isn't that account or one of its "Send mail as" aliases.
  test "MAIL_FROM is the Google Workspace account SMTP_USERNAME signs in as" do
    username = deploy_env.dig("clear", "SMTP_USERNAME").to_s
    from = Mail::Address.new(deploy_env.dig("clear", "MAIL_FROM").to_s)

    assert_match URI::MailTo::EMAIL_REGEXP, username
    assert_equal username.downcase, from.address.to_s.downcase,
      "Gmail would rewrite this From to #{username}. If MAIL_FROM is one of its \"Send mail as\" aliases, allow it here"
  end

  # Crew expiry notices ask crew to reply with their renewed certificate.
  test "OFFICE_EMAIL is set to an email address" do
    assert_match URI::MailTo::EMAIL_REGEXP, deploy_env.dig("clear", "OFFICE_EMAIL").to_s
  end

  test "the SMTP app password is a Kamal secret" do
    assert_includes deploy_env.fetch("secret"), "SMTP_PASSWORD"
    assert_not_includes deploy_env.fetch("clear").keys, "SMTP_PASSWORD"
    assert_match(/^SMTP_PASSWORD=\$SMTP_PASSWORD$/, Rails.root.join(".kamal/secrets").read)
  end

  # A misspelt name here would leave production signing in to Gmail with nothing.
  test "every ENV variable production.rb reads without a default is deployed" do
    required = Rails.root.join("config/environments/production.rb").read.scan(/ENV\[\s*"([A-Z][A-Z0-9_]*)"\s*\]/).flatten

    assert_includes required, "SMTP_USERNAME"
    assert_includes required, "SMTP_PASSWORD"
    assert_empty required - deployed_env_names
  end

  test "nothing still points at Resend" do
    files = Rails.root.glob("{app,config,lib,test}/**/*.{rb,erb,yml,rake}") + [ Rails.root.join(".kamal/secrets") ]
    names = files.map { |path| path.relative_path_from(Rails.root).to_s } - [ "test/config/deploy_config_test.rb" ]

    assert_empty names.select { |name| Rails.root.join(name).read.match?(/RESEND_API_KEY|smtp\.resend\.com/) }
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
