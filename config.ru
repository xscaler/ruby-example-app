role = ENV.fetch("APP_ROLE", "frontend")

case role
when "frontend"
  require_relative "frontend"
  run FrontendApp
when "backend"
  require_relative "backend"
  run BackendApp
else
  raise ArgumentError, "APP_ROLE must be 'frontend' or 'backend', got #{role.inspect}"
end
