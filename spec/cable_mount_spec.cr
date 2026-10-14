# Cable-mount seam: Application#cable_handler встаёт ПЕРЕД middleware-
# стеком (аналог ActionCable::Engine). Спека проверяет: (1) handler
# вызывается первым и может не звать call_next (upgrade-путь), (2)
# обычные запросы проходят сквозь него в стек к builtin /up.

require "spec"
require "../src/railties_cr"

class CableProbe
  include HTTP::Handler
  property calls : Int32 = 0

  def call(context : HTTP::Server::Context) : Nil
    @calls += 1
    if context.request.path == "/cable"
      context.response.status_code = 101
      context.response.headers["X-Cable-Probe"] = "upgrade"
    else
      call_next(context)
    end
  end
end

describe "Application#cable_handler" do
  it "runs before the middleware stack and passes normal requests through" do
    app = CRails::Application.new
    probe = CableProbe.new
    app.cable_handler = probe
    session = ActionDispatch::IntegrationSession.new(app)

    # /cable: перехватывается probe без прохода в стек.
    session.get("/cable")
    response = session.response.not_nil!
    response.status_code.should eq(101)
    response.headers["X-Cable-Probe"].should eq("upgrade")

    # Обычный путь: probe зовёт call_next, работает обычный стек (/up —
    # builtin-эндпоинт Dispatcher'а).
    session.get("/up")
    response = session.response.not_nil!
    response.status_code.should eq(200)
    probe.calls.should eq(2)
  end
end
