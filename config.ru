# frozen_string_literal: true

# Serve the benchmark dummy app so you can click through it:
#
#   bundle exec rake dummy      # or: bundle exec rackup -p 9292
#
# Routes: / (render everywhere), /bind_view, /bind_layout, /bind_both.
# All four return byte-identical HTML.
require_relative "benchmarks/app"

run Rails.application
