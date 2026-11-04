require "test_helper"
require_relative "../services/backups/file_copy_test_support"

class DashboardFileCopyBannerIntegrationTest < ActionDispatch::IntegrationTest
  include FileCopyTestSupport

  test "only admins see the file copy banner on the dashboard" do
    with_copy_dir(File.join(@copy_dir, "not-mounted")) do
      sign_in_as users(:admin)
      get root_path
      assert_select "#file_copy_banner", text: /Certificate files are not being copied to the server/
      sign_out

      %i[manager viewer].each do |role|
        sign_in_as users(role)
        get root_path
        assert_response :success
        assert_select "#file_copy_banner", count: 0
        sign_out
      end
    end
  end
end
