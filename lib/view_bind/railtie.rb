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

      # A code reload rebuilds view classes and template caches; ours has to go with them.
      # Without this an app that enables cache_template_loading in development would keep
      # rendering the version of a partial it first resolved.
      app.reloader.to_prepare { ViewBind.clear_cache }
    end
  end
end
