# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "minitest", "~> 5.25"
  gem "minitest-reporters", "~> 1.7"
  gem "rake", "~> 13.0"
  gem "standard", "~> 1.44"
  gem "sorbet-static-and-runtime"
  gem "tapioca", require: false
  gem "webmock", "~> 3.24"
end

# Optional runtime dependencies (autoloaded)
# gem "async", "~> 2.0", require: false
# gem "async-http", "~> 0.75", require: false
# gem "eth", "~> 0.5", require: false
# gem "rlp", "~> 0.7", require: false
gem "stripe", require: false
