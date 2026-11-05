require "test_helper"

# Phase 1 acceptance: "a viewer gets a 403 on every write action". Walks the app's route
# table, so every new POST/PATCH/PUT/DELETE route (and every new/edit form) is covered
# automatically: it either answers 403 to a viewer or is listed in ALLOWED with a reason.
# One test per route, so a failure names the route.
class AuthorizationAuditTest < ActionDispatch::IntegrationTest
  WRITE_VERBS = %w[POST PATCH PUT DELETE].freeze
  FORM_ACTIONS = %w[new edit].freeze
  # Controllers a viewer may not even read (Phase 3: uploads and import results carry
  # personal data), so their GET routes are audited too. The Ask box stays open to everyone.
  EDITOR_ONLY_CONTROLLERS = %w[imports import_reviews].freeze

  # Framework and engine internals. Mission Control guards itself through AdminController
  # (test/controllers/admin_jobs_test.rb); Active Storage through its own auth tests.
  SKIPPED_CONTROLLERS = %r{\A(rails|active_storage|action_mailbox|turbo|mission_control)/}

  # "controller#action" or "controller#*" => why a viewer may use it.
  ALLOWED = {
    "sessions#*" => "signing in and out works for every user, signed in or not",
    "passwords#*" => "password reset and invite acceptance are unauthenticated and token-gated",
    "packets#create" => "building the download packet is a read-only export every role may run"
  }.freeze

  # Fixture behind :id, by controller. Nested parents come from PARENT_FIXTURES.
  ID_FIXTURES = {
    "users" => %i[users manager],
    "crew_roles" => %i[crew_roles foreman],
    "crew_members" => %i[crew_members juan_ortiz],
    "certificates" => %i[certificates juan_osha30], # belongs to juan_ortiz, the :crew_member_id below
    "certificate_types" => %i[certificate_types osha30],
    "certificate_issuers" => %i[certificate_issuers retired_example],
    "projects" => %i[projects tower_2417],
    "project_assignments" => %i[project_assignments tower_juan], # on tower_2417, the :project_id below
    "imports" => %i[import_batches march_batch], # /imports/:id is an ImportBatch
    "import_reviews" => %i[import_items review_juan_first_aid] # /imports/review/:id is an ImportItem
  }.freeze

  PARENT_FIXTURES = {
    user_id: %i[users manager],
    crew_role_id: %i[crew_roles foreman],
    crew_member_id: %i[crew_members juan_ortiz],
    certificate_id: %i[certificates juan_osha30],
    certificate_type_id: %i[certificate_types osha30],
    project_id: %i[projects tower_2417],
    assignment_id: %i[project_assignments tower_juan],
    import_id: %i[import_batches march_batch],
    import_batch_id: %i[import_batches march_batch],
    import_item_id: %i[import_items review_juan_first_aid]
  }.freeze

  def self.route_key(route)
    route.defaults.values_at(:controller, :action).join("#")
  end

  def self.allowed?(route)
    controller, action = route.defaults.values_at(:controller, :action)
    ALLOWED.key?("#{controller}##{action}") || ALLOWED.key?("#{controller}#*")
  end

  # App routes a viewer must not use: write verbs plus the new/edit forms.
  def self.guarded_routes
    Rails.application.routes.routes.select do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next false if controller.nil? || controller.match?(SKIPPED_CONTROLLERS)

      WRITE_VERBS.include?(route.verb) ||
        (route.verb == "GET" && (FORM_ACTIONS.include?(action) || EDITOR_ONLY_CONTROLLERS.include?(controller)))
    end
  end

  guarded_routes.reject { |route| allowed?(route) }.each do |route|
    spec = route.path.spec.to_s.delete_suffix("(.:format)")
    test "viewer gets 403 on #{route.verb} #{spec} (#{route_key(route)})" do
      assert_viewer_forbidden(route)
    end
  end

  test "the audit sees the core write routes" do
    keys = self.class.guarded_routes.map { |route| self.class.route_key(route) }

    %w[
      users#create users#destroy crew_members#create crew_members#update crew_members#destroy crew_members#new
      certificates#create certificates#edit certificates#destroy crew_roles#create certificate_types#update
      projects#create projects#destroy project_requirements#update project_requirements#copy
      project_assignments#create project_assignments#destroy
      imports#index imports#show imports#create import_reviews#index import_reviews#show import_reviews#update
      import_reviews#accept import_reviews#reject import_reviews#skip import_reviews#create_crew_member import_reviews#merge
    ].each { |key| assert_includes keys, key }
    assert_not_includes keys, "ask#show"
  end

  test "the Ask box stays open to viewers" do
    sign_in_as users(:viewer)

    get ask_path, params: { q: "does juan ortiz have osha 30" }

    assert_response :success
  end

  test "every allowlist entry matches a real route" do
    routes = self.class.guarded_routes
    ALLOWED.each_key do |key|
      controller, action = key.split("#")
      assert routes.any? { |route| route.defaults[:controller] == controller && (action == "*" || route.defaults[:action] == action) },
        "ALLOWED has #{key}, but no guarded route matches it; remove the entry"
    end
  end

  private
    def assert_viewer_forbidden(route)
      sign_in_as users(:viewer)
      path = route.format(route_params(route))

      process route.verb.downcase.to_sym, path

      assert_response :forbidden, "#{route.verb} #{path} (#{self.class.route_key(route)}) answered #{response.status} " \
        "to a viewer. Guard it with require_role/authorize!, or add it to ALLOWED with a reason."
    end

    def route_params(route)
      controller = route.defaults[:controller]
      route.required_parts.index_with do |part|
        fixture = part == :id ? ID_FIXTURES[controller] : PARENT_FIXTURES[part]
        fixture ? send(*fixture).to_param : guess_id(controller, part)
      end
    end

    # Falls back to any row of the model the param names, so a new resource is still
    # audited; add it to ID_FIXTURES/PARENT_FIXTURES if that pick is wrong.
    def guess_id(controller, part)
      model = (part == :id ? controller.split("/").last : part.to_s.delete_suffix("_id")).classify.safe_constantize
      record = model.first if model.is_a?(Class) && model < ApplicationRecord
      record&.to_param || flunk("#{controller}: no fixture for :#{part}; add one to ID_FIXTURES or PARENT_FIXTURES")
    end
end
