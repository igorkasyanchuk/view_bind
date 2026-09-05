# frozen_string_literal: true

# A dummy Rails app with a realistic layout: header -> nav -> nav_item, a card collection
# whose cards render an author block, a tag collection and an actions block, plus a sidebar
# and footer. Five routes render equivalent HTML through different call styles.
# Production Rails runs YJIT; benchmark with it on unless YJIT=0.
RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable) && ENV["YJIT"] != "0"

require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "logger"
require_relative "../lib/view_bind"

NAV_LINKS    = [["Discover", "/"], ["Latest stories", "#latest"], ["Topics", "#topics"], ["Community", "#community"]].freeze
FOOTER_LINKS = [["About", "#community"], ["Topics", "#topics"], ["Source", "https://github.com/igorkasyanchuk/view_bind"]].freeze
# Presentation copy shared by every benchmark route; the database workload stays the same.
STORY_TITLES = [
  "The quiet art of making software faster",
  "Good abstractions leave room to change your mind",
  "What a slow query can teach you about your product",
  "Building interfaces that get out of the way",
  "Small teams, thoughtful tools, better software",
  "A practical guide to doing less work in Rails",
  "The details that make a codebase feel like home",
  "Beyond the benchmark: performance people can feel",
  "A little less JavaScript, a little more clarity",
  "Why the simplest solution is rarely the first one"
].freeze
STORY_EXCERPT = "Notes from the workbench: practical lessons, small experiments, and a closer look at the decisions that make everyday software better."
WIDGETS      = [["Popular", %w[ruby rails erb views]],
                ["Recent",  %w[perf caching sqlite]],
                ["Authors", %w[ada linus grace]]].freeze

class Author < ActiveRecord::Base
  has_many :posts
end

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments

  def tags = tag_list.to_s.split(",")
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class BenchApp < Rails::Application
  config.root = __dir__
  # Benchmark like production; browse (rake dummy) like development, so template edits
  # are picked up and errors render the debug page.
  benchmarking = Rails.env.production?
  config.eager_load = benchmarking
  config.enable_reloading = !benchmarking
  config.secret_key_base = "benchmark" * 8
  # Keep benchmark runs quiet unless logging is explicitly requested. A blank LOG_LEVEL counts
  # as unset: `LOG_LEVEL= bin/rails s` is how a variable exported in a shell profile gets
  # cleared, and it would otherwise assign "" and fail to boot.
  requested_log_level = ENV["LOG_LEVEL"].presence
  config.log_level = requested_log_level || (benchmarking ? "fatal" : "debug")
  config.logger = ActiveSupport::Logger.new(
    benchmarking && requested_log_level.nil? ? IO::NULL : $stdout
  )
  config.hosts.clear
  config.consider_all_requests_local = true
  config.action_view.cache_template_loading = benchmarking
  config.paths["app/views"] = [File.expand_path("views", __dir__)]
  config.active_record.maintain_test_schema = false
  config.middleware.delete ActionDispatch::DebugExceptions if Rails.env.production?

  routes.append do
    root                 to: "pages#plain"
    get "/bind_view"   => "pages#bind_view"
    get "/bind_layout" => "pages#bind_layout"
    get "/bind_both"   => "pages#bind_both"
    get "/bind_memo"   => "pages#bind_memo"
  end
end

POSTS_PER_PAGE = 200

class PagesController < ActionController::Base
  before_action do
    @user = "Igor"
    @current_path = "/"  # fixed so every route renders byte-identical HTML
    @flashes = [[:notice, "Signed in"], [:warning, "Trial ends soon"]]
    load_page_data
  end

  # render everywhere: the baseline
  def plain       = render template: "pages/index", layout: "layouts/application"

  # bind_render in the view only
  def bind_view   = render template: "pages/bound", layout: "layouts/application"

  # bind_render in the layout only
  def bind_layout = render template: "pages/index", layout: "layouts/bound"

  # bind_render in both
  def bind_both   = render template: "pages/bound", layout: "layouts/bound"

  # bind_render in both, with the repeated leaf partials memoised for the request
  def bind_memo   = render template: "pages/memo", layout: "layouts/bound"

  private

  # A page's worth of queries, the way a real index action accumulates them.
  def load_page_data
    @posts           = Post.includes(:author).order(id: :desc).limit(per_page).to_a
    @top_categories  = Post.group(:category).order(count_all: :desc).limit(5).count
    @busiest_authors = Author.joins(:posts).group("authors.name").order(count_all: :desc).limit(5).count
    @recent_comments = Comment.includes(:post).order(id: :desc).limit(8).to_a
    @top_monthly     = Post.includes(:author).where(created_at: 30.days.ago..).order(views: :desc).limit(6).to_a
    @totals          = { posts: Post.count, comments: Comment.count }
  end

  # POSTS_PER_PAGE by default; ?per=6 keeps the whole page on one screen for a screenshot.
  def per_page = params[:per].present? ? params[:per].to_i.clamp(1, 500) : POSTS_PER_PAGE

  def default_render = nil
end

ViewBind.profile = Rails.env.development?
Rails.application.initialize!

# The schema and rows go in after boot: Rails opens its own connection from
# config/database.yml, and every connection to ":memory:" is a database of its own.
ActiveRecord::Base.logger = nil if Rails.env.production?
ActiveRecord::Migration.verbose = false

# Only build the schema and rows when they are not already there. `rake dummy` and
# `rake bench` share one database -- a SQLite file, or view_bind_bench on PostgreSQL --
# and dropping the tables under a running server would 500 every request it is serving.
POST_COUNT = 2_000
COMMENT_COUNT = 6_000

def seeded?
  Post.count == POST_COUNT && Comment.count == COMMENT_COUNT
rescue ActiveRecord::StatementInvalid
  false
end

unless seeded?
  ActiveRecord::Schema.define do
    create_table :authors, force: true do |t|
      t.string :name
      t.string :city
    end

    create_table :posts, force: true do |t|
      t.references :author
      t.string :title
      t.string :category
      t.text :excerpt
      t.integer :views
      t.string :tag_list
      t.timestamps
    end

    create_table :comments, force: true do |t|
      t.references :post
      t.string :body
      t.string :author_name
      t.timestamps
    end
  end

  # Enough rows that the queries are doing real work, not so many that the benchmark
  # turns into a database benchmark.
  AUTHORS    = %w[Ada Linus Yukihiro Grace Rich Matz Aaron Eileen Xavier Jeremy].freeze
  CITIES     = %w[Kyiv Lviv Berlin Lisbon Tokyo].freeze
  CATEGORIES = %w[performance rails ruby databases frontend].freeze
  TAG_POOL   = %w[ruby rails perf views sqlite erb caching yjit].freeze

  author_ids = AUTHORS.each_with_index.map do |name, i|
    Author.create!(name: name, city: CITIES[i % CITIES.size]).id
  end

  Post.insert_all(
    (1..POST_COUNT).map do |i|
      { author_id: author_ids[i % author_ids.size],
        title: "Post number #{i}",
        category: CATEGORIES[i % CATEGORIES.size],
        excerpt: "Body text for post #{i}. " * 4,
        views: i * 7 % 991,
        tag_list: TAG_POOL.rotate(i).first(3).join(","),
        # spread over six months, so "top posts this month" selects a real slice
        created_at: Time.now - (i % 180) * 86_400, updated_at: Time.now }
    end
  )

  Comment.insert_all(
    (1..COMMENT_COUNT).map do |i|
      { post_id: (i % POST_COUNT) + 1,
        body: "Comment #{i} on the post, with a sentence of text.",
        author_name: AUTHORS[i % AUTHORS.size],
        created_at: Time.now, updated_at: Time.now }
    end
  )
end
