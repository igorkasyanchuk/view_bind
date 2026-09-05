# frozen_string_literal: true

require_relative "test_helper"

class ConcurrencyTest < Minitest::Test
  include ViewHelpers

  def test_concurrent_first_renders_keep_locals_and_memos_isolated
    ViewBind.clear_cache
    ready = Queue.new
    start = Queue.new
    workers = 8.times.map do |index|
      Thread.new do
        ready << true
        start.pop
        v = view
        name = index.even? ? :primary : :secondary
        Array.new(25) do
          v.capture { v.bind_render_memo("fixtures/named", **{ name => index.to_s }) }.strip
        end
      end
    end
    8.times { ready.pop }
    8.times { start << true }

    workers.each_with_index do |worker, index|
      name = index.even? ? :primary : :secondary
      assert_equal ["<i>#{name}=#{index}</i>"] * 25, worker.value
    end
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
    workers&.each(&:join)
    ViewBind.clear_cache
  end
end
