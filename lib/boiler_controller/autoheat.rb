# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/boiler_base'
require '/usr/local/lib/boiler_controller/globals'

# A PI controller for the boiler
class BoilerPI
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
                       .new(@config[:boiler_pi_filter_size])
    @sampling_timer = Globals::TimerSec
                      .new(@config[:boiler_pi_sampling_delay],
                           'Stability sampling delay timer')

    @pi_output_active = Mutex.new
    @pi_thread = nil
    @lastchanged = Time.now

    @ki = @config[:boiler_pi_ki]
    @kp = @config[:boiler_pi_kp]
  end

  def target(target = nil)
    return @target if target.nil?
    return if target == @target

    init_needed = (@target - target).abs > 4
    @target = target
    init_pi if init_needed
  end

  def start
    return unless @pi_thread.nil?

    init_pi
    @pi_thread = Thread.new do
      @logger.info('Boiler PD sleeping '\
        "#{@stability_buffer.size} secs before starting control")
      sleep @config[:boiler_pi_start_grace_time]
      @logger.info('Boiler PD starting control')

      # Main loop of the PD controller
      until @pi_output_active.locked?
        pi_main_loop
        sleep 0.1
      end
      @logger.info('Boiler PD exiting control loop')
    end
  end

  def stop
    return if @pi_thread.nil?
    @logger.info('Boiler PD stop requested - control active')
    @pi_output_active.lock if @pi_output_active.lock
    @pi_thread.join
    @pi_output_active.unlock
  end

  private

  # The main loop of the PD controller
  def pi_main_loop
    if @stability_timer.expired?
      @stability_timer.reset
      @stability_buffer.input_sample(@sensor.temp)
      @logger.info('Boiler PD stability buffer size: '\
                   "#{@stability_buffer.size}")
    end
    if @sampling_timer.expired?
      @sampling_timer.reset
      @sampling_buffer.input_sample(@sensor.temp)
      @logger.info('Boiler PD sampling buffer size: '\
                   "#{@sampling_buffer.size}")
      pi_control(@sampling_buffer.value)
      @output_wiper.set_water_temp(@output)
    end
  end

  def pi_control(input)
    error = (@target - input).abs > 0.3 ? @target - input : 0

    @i_term += @ki * error

    # Compute PI Output
    new_output = limit(@kp * error + @i_term)
    if (@output - new_output).abs > 0.2 &&
       new_output < @target + 10
      @output = new_output
      @logger.info('PD Output adjusted')
    end

    @logger.info("PD input: #{input.round(2)}")
    @logger.info("PD target: #{@target.round(2)}")
    @logger.info("PD Error: #{error.round(2)}")
    @logger.info("PD Output: #{@output.round(2)}")

    @last_input = input
  end

  def init_pi
    @stability_buffer.reset
    @sampling_buffer.reset
    @stability_timer.reset
    @sampling_timer.reset
    @last_input = @sensor.temp
    @i_term = limit(@target)
    @output = limit(@target)
  end

  def limit(value)
    return 34 if value < 34
    return 85 if value > 85

    value
  end
end
