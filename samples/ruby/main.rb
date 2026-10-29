#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require_relative "lib/claude_sample/sample"

exit(ClaudeSample::Sample.run(ARGV, ENV.to_h, $stdout, $stderr))
