# Mission Control Jobs (/jobs) sits behind the app's own sign-in and is admin-only:
# its controllers inherit from AdminController, so HTTP basic auth is not needed.
# Set on the module, not config.mission_control, because the engine copies config
# values in before_initialize, which runs before this file.
Rails.application.configure do
  MissionControl::Jobs.base_controller_class = "AdminController"
  MissionControl::Jobs.http_basic_auth_enabled = false
end
