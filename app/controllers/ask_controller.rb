# The Ask box (docs/PLAN.md "Ask box"): GET /ask?q=... answers a plain-English question
# with AskQuery and links the evidence. Read-only, so every signed-in role may ask. A
# "Did you mean" link adds the chosen record's id (crew_member_id, certificate_type_id or
# project_id) so the re-asked question resolves to exactly that record.
class AskController < ApplicationController
  PIN_PARAMS = %i[crew_member_id certificate_type_id project_id].freeze

  def show
    @today = Date.current
    @question = ask_params[:q].to_s.squish.first(Ask::Question::MAX_LENGTH)
    @examples = Ask::Examples.new.to_a
    @result = AskQuery.new(@question, user: Current.user, today: @today, **pins).call if @question.present?
  end

  private
    def ask_params
      params.permit(:q, *PIN_PARAMS)
    end

    def pins
      PIN_PARAMS.index_with { |key| ask_params[key].to_s[/\A\d+\z/]&.to_i }.compact
    end
end
