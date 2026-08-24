# frozen_string_literal: true

# A dummy Rails app with a realistic layout: header -> nav -> nav_item, a card collection
# whose cards render an author block, a tag collection and an actions block, plus a sidebar
# and footer. Four routes render byte-identical HTML through different call styles.
# Production Rails runs YJIT; benchmark with it on unless YJIT=0.
RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && ENV["YJIT"] != "0"

require "rails"
require "action_controller/railtie"
require "logger"
require_relative "../lib/view_bind"

NAV_LINKS    = [["Home", "/"], ["Posts", "/posts"], ["Tags", "/tags"], ["About", "/about"]].freeze
FOOTER_LINKS = [["Docs", "/docs"], ["Status", "/status"], ["Source", "/source"]].freeze
WIDGETS      = [["Popular", %w[ruby rails erb views]],
                ["Recent",  %w[perf caching sqlite]],
                ["Authors", %w[ada linus grace]]].freeze

Post = Struct.new(:id, :title, :author, :excerpt, :views, :tags)

POSTS = (1..200).map do |i|
  Post.new(i,
           "Post number #{i}",
           %w[Ada Linus Yukihiro Grace Rich][i % 5],
           "Body text for post #{i}. " * 4,
           i * 7,
           %w[ruby rails perf views sqlite erb].sample(3))
end.freeze

class BenchApp < Rails::Application
  config.root = __dir__
  config.eager_load = true
  config.enable_reloading = false
  config.secret_key_base = "benchmark" * 8
  config.logger = ActiveSupport::Logger.new(IO::NULL)
  config.log_level = :fatal
  config.hosts.clear
  config.consider_all_requests_local = true
  config.action_view.cache_template_loading = true
  config.paths["app/views"] = [File.expand_path("views", __dir__)]
  config.middleware.delete ActionDispatch::DebugExceptions if Rails.env.production?

  routes.append do
    root                 to: "pages#plain"
    get "/bind_view"   => "pages#bind_view"
    get "/bind_layout" => "pages#bind_layout"
    get "/bind_both"   => "pages#bind_both"
  end
end

class PagesController < ActionController::Base
  before_action do
    @user = "Igor"
    @current_path = "/"  # fixed so every route renders byte-identical HTML
    @flashes = [[:notice, "Signed in"], [:warning, "Trial ends soon"]]
  end

  # render everywhere: the baseline
  def plain       = render template: "pages/index", layout: "layouts/application"

  # bind_render in the view only
  def bind_view   = render template: "pages/bound", layout: "layouts/application"

  # bind_render in the layout only
  def bind_layout = render template: "pages/index", layout: "layouts/bound"

  # bind_render in both
  def bind_both   = render template: "pages/bound", layout: "layouts/bound"

  private

  def default_render = nil
end

class PagesController
  before_action { @posts = POSTS }
end

Rails.application.initialize!
