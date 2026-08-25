# frozen_string_literal: true

require "rails/railtie"

module ViewBind
  class Railtie < ::Rails::Railtie
    initializer "view_bind.helper" do |app|
      ActiveSupport.on_load(:action_view) do
        include ViewBind::Helper

        require "action_view/dependency_tracker"
        ViewBind::Tracker.register_for(:erb)
      end

      # One summary per request, in place of the per-partial lines bound partials no longer
      # produce. Subscribed once; does nothing while profiling is off.
      ActiveSupport::Notifications.subscribe("process_action.action_controller") do
        next unless ViewBind.profile?

        summary = ViewBind::Profiler.summary
        Rails.logger.info(summary) if summary
      end

      # A code reload rebuilds view classes and template caches; ours has to go with them.
      # Without this an app that enables cache_template_loading in development would keep
      # rendering the version of a partial it first resolved.
      app.reloader.to_prepare { ViewBind.clear_cache }
    end
  end
end
