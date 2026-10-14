# TcpNodelayServer — обёртка над HTTP::Server, ставящая TCP_NODELAY
# на принятые сокеты (как это делают Puma/nginx/Thruster в проде).
#
# Зачем: stdlib HTTP::Server не трогает опции сокета, и ответы больше
# буфера ответа пишутся серией socket-write. На loopback (MSS ~64KB)
# каждый чанк — «малый сегмент», Nagle придерживает его до ACK, а
# delayed-ACK клиента срабатывает таймером ~40ms — запрос стоит эти
# самые 40ms. Замер wrk-ом (2 потока / 10 соединений, qp_on_crystal):
# 64KB-статика — 250 RPS и flat-латентность 40ms; с TCP_NODELAY —
# десятки тысяч RPS. Малые ответы (< буфера, один write) не страдали.

module CRails
  class TcpNodelayServer < HTTP::Server
    protected def dispatch(io) : Nil
      if io.is_a?(TCPSocket)
        begin
          io.tcp_nodelay = true
        rescue Socket::Error | IO::Error
          # не ронять соединение из-за опции (например, сокет уже закрыт)
        end
      end
      # Тело stdlib HTTP::Server#dispatch (previous_def не видит
      # protected-метод родителя): fiber-per-connection.
      spawn handle_client(io)
    end
  end
end
