# frozen_string_literal: true

# Runs every test file in one Minitest process: `bundle exec ruby test/run.rb`. A plain `ruby test/run.rb` works as well,
# because test_helper.rb loads bundler/setup.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |file| require file }
