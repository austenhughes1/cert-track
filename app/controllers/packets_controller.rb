# The compliance packet for one project: a zip of the current certificate files plus an
# index PDF, built by Compliance::PacketJob. The zip is deleted the night after its last
# day (Project#packet_kept_until, 7 days after the build day); the page lists every past
# build with its index PDF. Building only reads data, so every signed-in role may build and
# download it.
class PacketsController < ApplicationController
  before_action :set_project

  def show
    @state = Compliance::PacketJob.state(@project)
    @builder = Compliance::PacketBuilder.new(@project) # preview counts; builds nothing
    @builds = @project.packet_builds.newest_first.includes(:built_by, index_pdf_attachment: :blob)
  end

  def create
    if Compliance::PacketJob.building?(@project)
      redirect_to project_packet_path(@project), notice: "The packet is already being built."
    else
      Compliance::PacketJob.request(@project, built_by: Current.user)
      redirect_to project_packet_path(@project), notice: "Building the packet. This page refreshes until it is ready."
    end
  end

  private
    def set_project
      @project = Project.with_attached_packet.find(params[:project_id])
    end
end
