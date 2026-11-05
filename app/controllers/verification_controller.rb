# "/verification": current certificates of active crew that a person confirmed fake, that are
# flagged for review (an automatic check, a QR code or a lookalike link found a problem), or that
# need a person to check them (docs/PLAN.md, Phase 3b), worst first. The dashboard's tiles link
# here filtered (?status=fake, flagged or needs_check, Authenticity::REVIEW_FILTERS). Every role
# can see it; checking happens on each certificate.
class VerificationController < ApplicationController
  # Authenticity::REVIEW_FILTERS' labels, also the dashboard's tiles'.
  FILTERS = { "fake" => "Confirmed fake", "flagged" => "Flagged for review", "needs_check" => "Needs a check" }.freeze
  # Most severe first, as the list is sorted after the confirmed fake ones.
  ORDER = %w[suspicious mismatch not_found needs_check].freeze
  LIMIT = 500

  def show
    @status = params[:status].presence_in(Authenticity::REVIEW_FILTERS)
    scope = Certificate.current.joins(:crew_member).merge(CrewMember.active)
    @counts = scope.authenticity_review_counts
    @total = @status ? @counts.fetch(@status) : @counts.values.sum
    @certificates = (@status ? scope.authenticity_review_filter(@status) : scope)
      .order(confirmed_fake_first).in_order_of(:authenticity_status, ORDER)
      .order("crew_members.last_name", "crew_members.first_name", :id)
      .preload(:crew_member, :certificate_type, :certificate_issuer, :authenticity_checked_by)
      .limit(LIMIT).to_a
  end

  private
    # A person's not_found or mismatch (Certificate.authenticity_confirmed_fake) before the rest.
    def confirmed_fake_first
      Certificate.authenticity_confirmed_fake_order(fake_first: true)
    end
end
