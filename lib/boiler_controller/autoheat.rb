# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/boiler_base'
require '/usr/local/lib/boiler_controller/globals'


# A PID controller for the boiler
class BoilerPID
  def initialize(output_wiper, heatmap,
                 sensor, config, initial_target = 34.0)
    @target = initial_target
    @output_wiper = output_wiper
    @output = initial_target
    @heatmap = heatmap
    @corrected_heatmap = heatmap.dup
    @sensor = sensor
    @config = config
    @logger = config.logger.analyzer_logger
    @stability_buffer = BoilerBase::Filter
                        .new(@config[:sensor_stability_windowsize])
    @stability_timer = Globals::TimerSec
                       .new(@config[:sensor_stability_measurement_period],
                            'Stability sampling delay timer')
    @sampling_buffer = BoilerBase::Filter
                       .new(@config[:boiler_pid_filter_size])
    @sampling_timer = Globals::TimerSec
                      .new(@config[:boiler_pid_sampling_delay],
                           'Stability sampling delay timer')

    @pid_output_active = Mutex.new
    @pid_thread = nil
    @lastchanged = Time.now

    @ki = @config[:boiler_pid_ki]
    @kp = @config[:boiler_pid_kp]
    @kd = @config[:boiler_pid_kd]

    start_pid
  end

  def target(target)
    return if target == @target

    @lastchanged = Time.now
    @target = target
  end

  def start_pid
    init_pid
    Thread.new do
      loop do
        if @stability_timer.expired?
          @stability_timer.reset
          @stability_buffer.input_sample(@sensor.temp)
          @logger.info("Boiler PID stability buffer size: #{@stability_buffer.size}")
        end
        if @sampling_timer.expired?
          @sampling_timer.reset
          @sampling_buffer.input_sample(@sensor.temp)
          @logger.info("Boiler PID sampling buffer size: #{@sampling_buffer.size}")
          pid_control(@sampling_buffer.value)
        end
        sleep 0.1
      end
    end
  end

  def reset
    @stability_buffer.reset
    @sampling_buffer.reset
    init_pid
  end

  private

  def pid_control(input)
    if @pid_output_active.locked?

    else

    end
    input = @sampling_buffer.value
    error = @target - input

    @i_term += @ki * error

    d_input = input - @last_input

    # Compute PID Output
    @output = limit(@kp * error + @i_term - @kd * d_input)

    @logger.info("PID Error: #{error}")
    @logger.info("PID Output: #{@output}")

    @last_input = input
  end

  def init_pid
    @last_input = @sensor.temp
    @i_term = limit(@target)
  end

  def limit(value)
    return 34 if value < 34
    return 85 if value > 85

    value
  end

end
