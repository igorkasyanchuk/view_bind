# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class ConcurrencyTest < Minitest::Test
  include ViewHelpers

  # Bounded, because every blocking call below is a place a lock-ordering bug would stop
  # rather than fail: without this the suite hangs instead of reporting the deadlock it caught.
  DEADLOCK_TIMEOUT = 60
  CLEANUP_TIMEOUT = 5

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
    Timeout.timeout(DEADLOCK_TIMEOUT) do
      8.times { ready.pop }
      8.times { start << true }

      workers.each_with_index do |worker, index|
        name = index.even? ? :primary : :secondary
        assert_equal ["<i>#{name}=#{index}</i>"] * 25, worker.value
      end
    end
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
    # One deadline for the whole cleanup rather than one per thread: a worker that ignores
    # kill must not hang the suite here, which is what DEADLOCK_TIMEOUT exists to prevent, and
    # eight sequential per-thread waits would add eight times the bound instead of one.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLEANUP_TIMEOUT
    undead = workers&.reject do |worker|
      worker.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
    end
    # Said out loud: an abandoned thread still holds whatever it was holding, and the next
    # test to fail would otherwise look like the culprit.
    warn "#{undead.size} worker thread(s) survived kill" if undead&.any?
    ViewBind.clear_cache
  end
end
