#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require_relative "lib/claude_sample/message_threads"

exit(ClaudeSample::MessageThreads.run(ARGV, ENV.to_h, $stdout, $stderr))
