# The compliance matrix for one project, as HTML or a CSV export. Read-only, so every
# signed-in role may view and export it.
class ComplianceController < ApplicationController
  before_action :set_project

  def show
    @report = Compliance::ProjectReport.new(@project, today: Date.current)

    respond_to do |format|
      format.html
      format.csv do
        send_data @report.to_csv, type: "text/csv; charset=utf-8", disposition: "attachment",
          filename: @report.csv_filename
      end
    end
  end

  private
    def set_project
      @project = Project.find(params[:project_id])
    end
end
