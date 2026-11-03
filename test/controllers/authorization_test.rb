require "test_helper"

# Exercises the Authorization concern (app/controllers/concerns/authorization.rb)
# through a throwaway controller, plus the real admin-only routes.
class AuthorizationTest < ActionDispatch::IntegrationTest
  class ProbesController < ApplicationController
    require_role :editor, except: :index
    before_action -> { authorize!(:admin) }, only: :destroy

    def index = render(plain: "viewer ok")
    def create = render(plain: "editor ok")
    def destroy = render(plain: "admin ok")
  end

  with_routing do |set|
    set.draw do
      resource :session
      resources :probes, only: %i[index create destroy], controller: "authorization_test/probes"
    end
  end

  test "anonymous requests are redirected to sign in" do
    get "/probes"
    assert_redirected_to new_session_path
  end

  test "viewers can read but get 403 on an :editor action" do
    sign_in_as users(:viewer)

    get "/probes"
    assert_response :success

    post "/probes"
    assert_response :forbidden
    assert_select "h1", "Not allowed"
  end

  test "managers pass :editor checks but get 403 on an :admin action" do
    sign_in_as users(:manager)

    post "/probes"
    assert_response :success
    assert_equal "editor ok", response.body

    delete "/probes/1"
    assert_response :forbidden
  end

  test "admins pass every level" do
    sign_in_as users(:admin)

    post "/probes"
    assert_response :success
    delete "/probes/1"
    assert_equal "admin ok", response.body
  end

  test "non-HTML requests get a bare 403" do
    sign_in_as users(:viewer)
    post "/probes", as: :json
    assert_response :forbidden
    assert_empty response.body
  end
end
