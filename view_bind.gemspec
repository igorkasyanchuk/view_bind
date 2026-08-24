# frozen_string_literal: true

require_relative "lib/view_bind/version"

Gem::Specification.new do |spec|
  spec.name    = "view_bind"
  spec.version = ViewBind::VERSION
  spec.authors = ["Igor Kasyanchuk"]
  spec.email   = ["igorkasyanchuk@gmail.com"]

  spec.summary     = "Render Rails partials by calling their compiled method, skipping the per-call render machinery."
  spec.description = "bind_render and bind_render_each resolve a partial once and then call the " \
                     "method ActionView already compiled for it. Partials stay ordinary partials: " \
                     "backtraces, locals, strict locals, development reloading and fragment cache " \
                     "digests all keep working."
  spec.homepage = "https://github.com/igorkasyanchuk/view_bind"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "concurrent-ruby", ">= 1.1"
end
