# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Off unless asked for: it slows every run and the default task is what people run locally.
if ENV["COVERAGE"]
  require "simplecov"
  # Pinned rather than left to default to Dir.pwd, so that lib/ is tracked and coverage/ is
  # written in the same place however the suite was launched.
  SimpleCov.root File.expand_path("..", __dir__)
  # Named so that the no-Rails child process in test_loads_without_rails can report under a
  # different name and have its result merged into this one, rather than overwrite it.
  # The stored results are dropped first: SimpleCov merges anything written in the last ten
  # minutes, and a 100% gate must not be satisfied by a previous run's numbers.
  require "fileutils"
  FileUtils.rm_f(File.join(SimpleCov.root, "coverage", ".resultset.json"))
  SimpleCov.command_name "suite"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/test/"
    add_filter "/benchmarks/"
    minimum_coverage line: 100, branch: 100
  end
end

require "rails"
require "action_controller/railtie"
require "view_bind"
require "minitest/autorun"
require "open3"

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

  routes.append do
    get "/page"  => "fixtures#page"
    get "/plain" => "fixtures#plain"
  end
end

class FixturesController < ActionController::Base
  def page = render template: "fixtures/page", layout: "layouts/wrapper"
  # No bound partial anywhere in this response, so the profiler has nothing to summarise.
  def plain = render template: "fixtures/plain", layout: false
end

Rails.application.initialize!

# eager_load is off here, so ActionView::Base would not load until the first render and the
# railtie's on_load hook (which registers the dependency tracker) would fire at an unpredictable
# point in the test order. Touch it now so every test starts from the same state.
ActionView::Base.name # force the on_load(:action_view) hook
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

  # For expectations that pin exact adjacency between partials.
  def dense(html) = html.to_s.gsub(/\s+/, "")

  # Swaps DependencyTracker's private registry for the duration of the block. There is no
  # public writer, and the tracker has to cope with a registry it cannot read.
  def swap_tracker_registry(registry)
    was = ActionView::DependencyTracker.instance_variable_get(:@trackers)
    ActionView::DependencyTracker.instance_variable_set(:@trackers, registry)
    yield
  ensure
    ActionView::DependencyTracker.instance_variable_set(:@trackers, was)
  end

  def erb_handler = ActionView::Template.handler_for_extension(:erb)

  # The memo values for one path and locals shape, across every HTML-safety mask.
  def memo_bucket(rendered, path, shape)
    by_safety = rendered.instance_variable_get(:@__view_bind_memo).values.first[path][shape]
    by_safety.values.reduce({}) { |all, entries| all.merge(entries) }
  end

  # The innermost memo map for the first thing `rendered` memoised: the memo nests as
  # context => path => locals names => HTML-safety mask => value => markup. Named `rendered`
  # rather than `view`, which in this module builds a fresh view context.
  def memo_entries(rendered)
    rendered.instance_variable_get(:@__view_bind_memo)
            .values.first.values.first.values.first.values.first
  end
end
