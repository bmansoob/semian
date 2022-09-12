# frozen_string_literal: true

require "test_helper"
require "active_record"
require "semian/mysql2"
require "semian/rails"

class TestPings < Minitest::Test
  include CircuitBreakerHelper

  SUCCESS_THRESHOLD = 2
  ERROR_THRESHOLD = 1
  ERROR_TIMEOUT = 5
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: SUCCESS_THRESHOLD,
    error_timeout: ERROR_TIMEOUT,
  }

  def setup
    Semian.destroy(:mysql_testing)
    @config = {
      adapter: "mysql2",
      connect_timeout: 2,
      read_timeout: 2,
      write_timeout: 2,
      reconnect: true,
      prepared_statements: false,
      connection_retries: 0,
      host: SemianConfig["toxiproxy_upstream_host"],
      port: SemianConfig["mysql_toxiproxy_port"],
      semian: SEMIAN_OPTIONS,
    }

    ActiveRecord::Base.establish_connection(@config)

    @connection = ActiveRecord::Base.connection
    @resource = @connection.semian_resource
    @circuit_breaker = @resource.circuit_breaker
    @proxy = Toxiproxy[:semian_test_mysql]
  end

  def test_once_circuit_opens_we_never_get_out_of_loop
    # this test reproduces the problem we have been seeing in production
    # there seems to be an edge case, where circuits get stuck in open state
    # possibly due to a combination of recent changes in rails and how Semian handles #PingFailure

    # just getting raw_connection to make it easy to assert on MySql2::Error
    raw_connection = @connection.send(:raw_connection)
    @proxy.downstream(:latency, latency: 3000).apply do
      (ERROR_THRESHOLD * 2).times do
        assert_raises(Mysql2::Error) do
          raw_connection.query("SELECT 1")
        end
      end
    end

    # verify circuits are open
    assert_circuit_opened(@resource)

    # force this else branch https://github.com/rails/rails/blob/bee6167977e601e6b690703de3be643bbdd88b38/activerecord/lib/active_record/connection_adapters/abstract_adapter.rb#L941-L945
    # this is what we see in production stacktraces
    @connection.stubs(:reconnect_can_restore_state?).returns(true)
    @connection.instance_variable_set("@verified", false)

    error_timeout = ERROR_TIMEOUT + 1
    100.times do
      Timecop.travel(error_timeout) do
        # verify we will transition from open to half_open, it will flap back to open because of PingFailure, which is eventually called by verify!
        # we never get out of this loop -- the connection is borked
        assert_equal(true, @circuit_breaker.send(:transition_to_half_open?))
        assert_raises(ActiveRecord::ConnectionNotEstablished) do
          @connection.execute("SELECT 1")
        end
        error_timeout += error_timeout
      end
      assert_circuit_opened(@resource)
    end
  end

  # module DoNotMarkPingFailure
  #   def mark_failed(error)
  #     return if error.is_a?(Semian::Mysql2::PingFailure)
  #     super
  #   end
  # end

  # def test_if_we_do_not_open_circuits_for_pings_above_test_passes
  #   Semian::CircuitBreaker.prepend(DoNotMarkPingFailure)

  #   # just getting raw_connection to make it easy to assert on MySql2::Error
  #   raw_connection = @connection.send(:raw_connection)
  #   @proxy.downstream(:latency, latency: 3000).apply do
  #     (ERROR_THRESHOLD * 2).times do
  #       assert_raises(Mysql2::Error) do
  #         raw_connection.query("SELECT 1")
  #       end
  #     end
  #   end

  #   # verify circuits are open
  #   assert_circuit_opened(@resource)

  #   # force this else branch https://github.com/rails/rails/blob/bee6167977e601e6b690703de3be643bbdd88b38/activerecord/lib/active_record/connection_adapters/abstract_adapter.rb#L941-L945
  #   # this is what we see in production stacktraces
  #   @connection.stubs(:reconnect_can_restore_state?).returns(true)
  #   @connection.instance_variable_set("@verified", false)

  #   error_timeout = ERROR_TIMEOUT + 1

  #   Timecop.travel(error_timeout) do
  #     # verify we will transition from open to half_open, it will NOT flap back to open because we do not mark PingFailure
  #     assert_equal(true, @circuit_breaker.send(:transition_to_half_open?))
  #     @connection.execute("SELECT 1")
  #     error_timeout += error_timeout  
  #   end
  #   assert_circuit_closed(@resource)
  # end
end
