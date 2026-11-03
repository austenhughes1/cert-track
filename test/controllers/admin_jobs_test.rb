require "test_helper"

# Mission Control Jobs at /jobs inherits from AdminController (config/initializers/mission_control.rb).
class AdminJobsTest < ActionDispatch::IntegrationTest
  test "mission control is configured to use the app's admin gate" do
    assert_equal "AdminController", MissionControl::Jobs.base_controller_class
    assert_not MissionControl::Jobs.http_basic_auth_enabled
    assert_operator MissionControl::Jobs::ApplicationController, :<, AdminController
  end

  test "anonymous users are redirected to sign in" do
    get "/jobs"
    # Literal path: after a request into the engine, the test's route helpers carry its /jobs prefix.
    assert_redirected_to "/session/new"
  end

  test "viewers and managers get 403" do
    %i[viewer manager].each do |role|
      sign_in_as users(role)
      get "/jobs"
      assert_response :forbidden, "#{role} should be refused"
      assert_select "h1", "Not allowed"
      sign_out
    end
  end

  test "admins see the dashboard" do
    sign_in_as users(:admin)
    get "/jobs"
    follow_redirect! while response.redirect?

    assert_response :success
    assert_select "title", /Mission control/
  end
end
