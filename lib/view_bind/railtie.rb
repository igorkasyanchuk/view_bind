# frozen_string_literal: true

require "rails/railtie"

module ViewBind
  class Railtie < ::Rails::Railtie
    initializer "view_bind.helper" do
      ActiveSupport.on_load(:action_view) do
        include ViewBind::Helper

        require "action_view/dependency_tracker"
        ActionView::DependencyTracker.register_tracker(:erb, ViewBind::Tracker)
      end
    end
  end
end
