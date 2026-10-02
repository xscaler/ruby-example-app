source "https://rubygems.org"

ruby "~> 3.3"

gem "puma", "~> 6.4"
gem "rackup", "~> 2.1"
gem "sinatra", "~> 4.0"
# MySQL client. Trilogy speaks the protocol itself, so unlike mysql2 it needs no
# libmysqlclient in the runtime image. Auto-instrumented by the OTel gem.
gem "trilogy", "~> 2.9"

group :test do
  gem "minitest", "~> 5.22"
  gem "rack-test", "~> 2.1"
  # Lets the frontend's backend calls be asserted without a live backend.
  gem "webmock", "~> 3.23"
end
