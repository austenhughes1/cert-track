# The compliance packet for one project: a zip of the current certificate files plus an
# index PDF, built by Compliance::PacketJob. Building only reads data, so every
# signed-in role may build and download it.
class PacketsController < ApplicationController
  before_action :set_project

  def show
    @state = Compliance::PacketJob.state(@project)
    @builder = Compliance::PacketBuilder.new(@project) # preview counts; builds nothing
  end

  def create
    if Compliance::PacketJob.building?(@project)
      redirect_to project_packet_path(@project), notice: "The packet is already being built."
    else
      Compliance::PacketJob.request(@project)
      redirect_to project_packet_path(@project), notice: "Building the packet. This page refreshes until it is ready."
    end
  end

  private
    def set_project
      @project = Project.with_attached_packet.find(params[:project_id])
    end
end
