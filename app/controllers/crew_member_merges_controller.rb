# Merge two records of the same person (CrewMembers::Merge): new shows what moves from this record
# (crew_member_id) into the one kept (into, a member id; defaults to the possible duplicate it was
# marked as), create does it and goes to the kept record.
class CrewMemberMergesController < ApplicationController
  require_role :editor
  before_action :set_crew_member

  def new
    @others = CrewMember.where.not(id: @crew_member.id).ordered.to_a
    @into = @others.find { |member| member.id == (params[:into].presence || @crew_member.possible_duplicate_of_id).to_i }
    @preview = CrewMembers::Merge.new(from: @crew_member, into: @into).preview if @into
  end

  def create
    into = CrewMember.find_by(id: params[:into])
    result = CrewMembers::Merge.new(from: @crew_member, into:).call
    redirect_to result.crew_member, status: :see_other, notice: "Merged #{@crew_member.display_name} into #{into.display_name}: " \
      "#{helpers.pluralize(result.certificates, 'certificate')}, #{helpers.pluralize(result.projects, 'project')} and " \
      "#{helpers.pluralize(result.import_items, 'imported card')} moved. #{@crew_member.full_name} is now one of their other spellings."
  rescue CrewMembers::Merge::Invalid => error
    redirect_to new_crew_member_merge_path(@crew_member), alert: error.message, status: :see_other
  end

  private
    def set_crew_member
      @crew_member = CrewMember.find(params.expect(:crew_member_id))
    end
end
