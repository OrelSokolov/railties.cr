# Oracle cases for the middleware stack (Iteration 12): captured from
# Rails 8.1.4 — ActionDispatch::MiddlewareStack semantics (unit) + the
# default stack of a real app + HTTP behavior through the stack
# (Rack::Head, Rack::Runtime, a middleware inserted from config).
#
# Copy this file into /tmp/rails8_oracle (the reference 8.1.4 app, with
# config/initializers/oracle_middleware.rb added — see README note in
# railties.cr/PLAN.md), start the server:
#   RAILS_ENV=production SECRET_KEY_BASE=dummy \
#     PORT=3200 bin/rails server > /tmp/rails8_oracle/server.log 2>&1 &
# then:
#   PORT=3200 bundle exec ruby oracle/middleware_cases.rb \
#     > oracle/middleware_expected.yml
#
# Each line: "<case_id>\t<value>". Mirrored 1:1 in spec/middleware_spec.cr.
# Volatile values are normalized in place (durations -> NUM).

require "net/http"
require_relative "config/environment" # run from the reference app root

PORT = Integer(ENV.fetch("PORT", "3200"))

# --- scratch middleware classes (stable names for the mirror spec) ----
%w[One Two Three Four Five Six].each do |name|
  klass = Class.new do
    attr_reader :app

    def initialize(app)
      @app = app
    end
  end
  Object.const_set(name, klass)
end

def names(stack)
  stack.map(&:name).join(",")
end

def case_run(id)
  puts "#{id}\t#{yield}"
rescue StandardError => e
  puts "#{id}\traise:#{e.class}:#{e.message}"
end

def http
  Net::HTTP.new("127.0.0.1", PORT)
end

# --- default stack of the reference app ------------------------------
case_run("default_stack_names") { names(Rails.application.middleware) }

# --- MiddlewareStack semantics (scratch stack) ------------------------
case_run("ops_use") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  names(s)
end

case_run("ops_unshift") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.unshift Three
  names(s)
end

case_run("ops_insert_before") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.insert_before Two, Three
  names(s)
end

case_run("ops_insert_after") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.insert_after One, Three
  names(s)
end

case_run("ops_swap") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.swap One, Three
  names(s)
end

case_run("ops_delete") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.delete Two
  names(s)
end

case_run("ops_delete_missing_stays") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.delete Three # not found: no-op, returns nil
  names(s)
end

case_run("ops_delete_bang_missing") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.delete! Two
end

case_run("ops_move_before") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.use Three
  s.move_before One, Three
  names(s)
end

case_run("ops_move_after") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.use Three
  s.move_after One, Three
  names(s)
end

case_run("ops_insert_before_missing") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.insert_before Four, Two
end

case_run("ops_insert_after_missing") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.insert_after Four, Two
end

case_run("ops_swap_missing") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.swap Four, Two
end

case_run("ops_size_last_index") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  s.use Three
  "#{s.size}:#{s.last.name}:#{s[0].name}"
end

case_run("middleware_equality") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  node = s[0]
  "#{node == One}:#{node == Two}:#{node == s[0]}"
end

case_run("middleware_inspect") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s[0].inspect
end

def unwrap(mw)
  # In a booted Rails app Notifications listens to process_middleware
  # and build() wraps the head in InstrumentationProxy — unwrap it so
  # the case reflects composition, not instrumentation.
  if mw.is_a?(ActionDispatch::MiddlewareStack::InstrumentationProxy)
    mw.instance_variable_get(:@middleware)
  else
    mw
  end
end

case_run("build_head_class") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  unwrap(s.build(->(env) { [200, {}, []] })).class.name
end

case_run("build_wires_app") do
  s = ActionDispatch::MiddlewareStack.new
  s.use One
  s.use Two
  head = unwrap(s.build(->(env) { [200, {}, []] }))
  unwrap(head.app).class.name
end

# --- HTTP behavior through the stack (running server) -----------------
case_run("head_up_status") do
  http.request(Net::HTTP::Head.new("/up")).code
end

case_run("head_up_body_empty") do
  http.request(Net::HTTP::Head.new("/up")).body.to_s.empty? ? "empty" : "non-empty"
end

case_run("head_up_content_type") do
  http.request(Net::HTTP::Head.new("/up"))["Content-Type"]
end

case_run("head_up_content_length") do
  http.request(Net::HTTP::Head.new("/up"))["Content-Length"]
end

case_run("head_up_x_request_id") do
  rid = http.request(Net::HTTP::Head.new("/up"))["X-Request-Id"]
  rid =~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/ ? "UUID" : rid.to_s
end

case_run("x_runtime_header") do
  v = http.get("/up")["X-Runtime"]
  v.nil? ? "absent" : "present"
end

case_run("x_runtime_format") do
  v = http.get("/up")["X-Runtime"]
  v.nil? ? "absent" : (v =~ /\A\d+\.\d+\z/ ? "NUM" : v)
end

# Middleware inserted via config/initializers/oracle_middleware.rb:
# insert_before ActionDispatch::RequestId, OracleHeaderMiddleware
case_run("custom_insert_before_header") do
  http.get("/up")["X-Oracle-Mw"]
end
