# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rails"
require "action_controller/railtie"
require "view_bind"
require "minitest/autorun"

class TestApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.enable_reloading = false
  config.secret_key_base = "test" * 10
  config.logger = ActiveSupport::Logger.new(IO::NULL)
  config.log_level = :fatal
  config.hosts.clear
  config.action_view.cache_template_loading = true
  config.paths["app/views"] = [File.expand_path("views", __dir__)]

  routes.append { get "/page" => "fixtures#page" }
end

class FixturesController < ActionController::Base
  def page = render template: "fixtures/page", layout: "layouts/wrapper"
end

Rails.application.initialize!

# eager_load is off here, so ActionView::Base would not load until the first render and the
# railtie's on_load hook (which registers the dependency tracker) would fire at an unpredictable
# point in the test order. Touch it now so every test starts from the same state.
ActionView::Base
require "action_view/dependency_tracker"

I18n.available_locales = %i[en fr]

module ViewHelpers
  def view(locale: :en)
    controller = FixturesController.new
    controller.request  = ActionDispatch::TestRequest.create
    controller.response = ActionDispatch::TestResponse.new
    controller.view_context.tap { |v| v.lookup_context.locale = locale }
  end

  def squish(html) = html.to_s.gsub(/\s+/, " ").strip
end
