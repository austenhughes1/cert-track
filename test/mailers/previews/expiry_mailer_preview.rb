# Preview all emails at http://localhost:3000/rails/mailers/expiry_mailer
# Each preview uses current data when there is some and unsaved sample records otherwise, so
# they render on an empty database. Nothing is written (the send log is never touched).
class ExpiryMailerPreview < ActionMailer::Preview
  # Preview this email at http://localhost:3000/rails/mailers/expiry_mailer/daily_digest
  def daily_digest
    items = Notifications::DigestBuilder.daily_items.presence || ExpiryMailer.sample_items
    ExpiryMailer.with(user: recipient, items: items).daily_digest
  end

  # Preview this email at http://localhost:3000/rails/mailers/expiry_mailer/test_digest_with_sample_data
  def test_digest_with_sample_data
    ExpiryMailer.with(user: recipient, items: ExpiryMailer.sample_items, test: true, sample: true).daily_digest
  end

  # Preview this email at http://localhost:3000/rails/mailers/expiry_mailer/weekly_digest
  def weekly_digest
    today = Date.current
    expiring = Notifications::DigestBuilder.weekly_items(today: today)
    gaps = Compliance::Overview.new(Project.active, today: today).reports.flat_map(&:gaps)
    if expiring.empty? && gaps.empty?
      expiring = ExpiryMailer.sample_items(today: today).select { |item| item.days_left <= Compliance::EXPIRING_WINDOW }
      gaps = ExpiryMailer.sample_gaps(today: today)
    end

    ExpiryMailer.with(user: recipient, expiring: expiring, gaps: gaps).weekly_digest
  end

  # Preview this email at http://localhost:3000/rails/mailers/expiry_mailer/weekly_digest_all_clear
  def weekly_digest_all_clear
    ExpiryMailer.with(user: recipient, expiring: [], gaps: []).weekly_digest
  end

  # Preview this email at http://localhost:3000/rails/mailers/expiry_mailer/crew_notice
  def crew_notice
    item = Notifications::DigestBuilder.weekly_items.find { |candidate| candidate.crew_member.email.present? && !candidate.expired? }
    item ||= ExpiryMailer.sample_items.first.tap { |sample| sample.crew_member.email = "alex.example@example.com" }

    ExpiryMailer.with(crew_member: item.crew_member, certificate: item.certificate, threshold: item.threshold).crew_notice
  end

  private
    def recipient
      User.digest_recipients.order(:id).first || User.order(:id).first ||
        User.new(name: "Pat Example", email_address: "pat@example.com", role: :manager)
    end
end
