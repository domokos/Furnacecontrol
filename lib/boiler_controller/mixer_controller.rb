# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/globals'
require '/usr/local/lib/boiler_controller/boiler_base'

class MixerControl
  def initialize(mix_sensor, cw_switch, ccw_switch,
                  config,
                  initial_target_temp = 34.0)
    # Initialize class variables
    @mix_sensor = mix_sensor
    @target_temp = initial_target_temp
    @cw_switch = cw_switch
    @ccw_switch = ccw_switch

    # Copy the configuration
    @config = config
    @logger = config.logger.app_logger

    # Create Filters
    @mix_filter = BoilerBase::Filter.new(@config[:mixer_filter_size])

    @target_mutex = Mutex.new
    @control_mutex = Mutex.new
    @measurement_mutex = Mutex.new
    @measurement_thread_mutex = Mutex.new
    @stop_measurement_requested = Mutex.new
    @control_thread_mutex = Mutex.new
    @stop_control_requested = Mutex.new
    @paused = true
    @resuming = false

    @control_thread = nil
    @measurement_thread = nil

    # Create the log rate limiter
    @mixer_log_rate_limiter = \
      Globals::TimerSec.new(@config[:mixer_limited_log_period],\
                            'Mixer controller log timer')
  end

  def init
    # Prefill sample buffer to get rid of false values
    @config[:mixer_filter_size].times do
      @mix_filter.input_sample(@mix_sensor.temp)
    end
    @integrated_cw_movement_time = 0
    @integrated_ccw_movement_time = 0
    @int_err_sum = 0
  end

  def temp
    retval = 0
    @measurement_mutex.synchronize { retval = @mix_filter.value }
    retval
  end

  def set_target_temp(new_target_temp)
    @target_mutex.synchronize { @target_temp = new_target_temp }
  end

  def start_control
    # Only start control thread if not yet started
    return unless @control_thread_mutex.try_lock

    @logger.debug('Mixer controller starting control')

    # Clear control thread stop sugnaling mutex
    @stop_control_requested.unlock if @stop_control_requested.locked?

    # Start control thread
    @control_thread = Thread.new do
      Thread.current[:name] = 'Mixer controller'
      # Acquire lock for controlling switches
      @control_mutex.synchronize do
        # Initialize mixer variables
        init
        start_measurement_thread
        @logger.trace('Mixer controller do_control_thread before '\
        'starting control loop')

        # Control until stop is requested
        until @stop_control_requested.locked?
          # Pause as long as pause is requested
          if @paused
            sleep 1
          else
            # Do the actual control
            do_control_thread

            # Delay between control actions
            sleep @config[:mixer_control_loop_delay] unless\
            @stop_control_requested.locked? || @paused
          end
        end
        # Stop the measurement thread before exiting
        stop_measurement_thread
      end
      # of control mutex synchronize
    end
  end

  def stop_control
    # Return if we do not have a control thread
    if !@control_thread_mutex.locked? || @control_thread.nil?
      @logger.debug(\
        'Mixer controller not running in stop control - returning')
      return
    end

    # Signal the control thread to exit
    @stop_control_requested.lock
    # Wait for the control thread to exit
    @control_thread.join
    @logger.debug('Mixer controller control_thread joined')

    # Allow the next call to start control to create a new control thread
    @control_thread_mutex.unlock
    @logger.debug('Mixer controller control_thread_mutex unlocked')
  end

  def pause
    if !@control_thread_mutex.locked? || @control_thread.nil?
      @logger.debug('Mixer controller not running in pause - returning')
      return
    end

    if @paused
      @logger.trace(\
        'Mixer controller - controller already paused - ignoring')
    else
      @logger.debug('Mixer controller - pausing control')
      # Signal controller to pause
      @paused = true
    end
  end

  def resumecheck
    if !@control_thread_mutex.locked? || @control_thread.nil?
      @logger.debug('Mixer controller not running')
      return false
    end

    unless @paused
      @logger.trace('Mixer controller - controller not paused')
      return false
    end

    if @resuming
      @logger.trace('Mixer controller - resuming active')
      return false
    end
    true
  end

  def resume
    return unless resumecheck

    @resuming = true
    Thread.new do
      Thread.current[:name] = 'Mixer resume thread'
      # Initialize mixer variables
      init

      @logger.debug('Mixer controller - resuming control')

      # Signal controller to resume
      @paused = false
      @resuming = false
    end
  end

  def start_measurement_thread
    @logger.debug('Mixer controller - measurement thread start requested')
    return unless @measurement_thread_mutex.try_lock

    # Unlock the measurement thread exis signal
    @stop_measurement_requested.unlock if @stop_measurement_requested.locked?

    # Create a temperature measurement thread
    @measurement_thread = Thread.new do
      Thread.current[:name] = 'Mixer measurement'
      @logger.debug('Mixer controller - measurement thread starting')
      until @stop_measurement_requested.locked?
        @measurement_mutex.synchronize\
          { @mix_filter.input_sample(@mix_sensor.temp) }
        sleep @config[:mixer_sampling_delay] unless\
          @stop_measurement_requested.locked?
      end
      @logger.debug('Mixer controller - measurement thread exiting')
    end
  end

  def stop_measurement_thread
    # Return if we do not have a measurement thread
    return if !@measurement_thread_mutex.locked? || @measurement_thread.nil?

    # Signal the measurement thread to exit
    @stop_measurement_requested.lock

    # Wait for the measurement thread to exit
    @logger.debug(\
      'Mixer controller - waiting for measurement thread to exit')
    @measurement_thread.join
    @logger.debug('Mixer controller - measurement thread joined')

    # Allow a next call to start_measurement thread to create
    # a new measurement thread
    @measurement_thread_mutex.unlock
    @logger.debug('Mixer controller - measurement_thread_mutex unlocked')
  end

  def log(value, error)
    # Copy the config for updates
    @logger.debug("Mixer forward temp: #{value.round(2)}")
    @logger.debug("Mixer controller error: #{error.round(2)}")
    @mixer_log_rate_limiter.set_timer(@config[:mixer_limited_log_period])
    @mixer_log_rate_limiter.reset
  end

  # The actual control thread
  def do_control_thread
    # Init local variables
    target = 0
    value = 0

    # Read target temp thread safely
    @target_mutex.synchronize { target = @target_temp }
    @measurement_mutex.synchronize { value = @mix_filter.value }

    error = target - value
    adjustment_time = calculate_adjustment_time(error)

    log(value, error) if @mixer_log_rate_limiter.expired?

    # Adjust mixing motor if it is needed
    return if adjustment_time.abs.zero?

    @logger.trace('Mixer controller target: '\
      "#{target.round(2)}")
    @logger.trace("Mixer controller value: #{value.round(2)}")
    @logger.trace('Mixer controller adjustment time: '\
      "#{adjustment_time.round(2)}")
    @logger.trace(\
      'Mixer controller int. cw time: '\
      "#{@integrated_cw_movement_time.round(2)}"
    )
    @logger.trace(\
      'Mixer controller int. ccw time: '\
      "#{@integrated_ccw_movement_time.round(2)}"
    )

    # Move CCW
    if adjustment_time.positive? && \
        @integrated_ccw_movement_time < \
        @config[:mixer_unidirectional_movement_time_limit]
      @logger.trace('Mixer controller adjusting ccw')
      @ccw_switch.pulse_block((adjustment_time * 10).to_i)

      # Keep track of movement time for limiting movement
      @integrated_ccw_movement_time += adjustment_time

      # Adjust available movement time for the other direction
      @integrated_cw_movement_time -= adjustment_time
      @integrated_cw_movement_time = 0 if @integrated_cw_movement_time.negative?

      # Move CW
    elsif adjustment_time.negative? && \
          @integrated_cw_movement_time < \
          @config[:mixer_unidirectional_movement_time_limit]
      adjustment_time = -adjustment_time
      @logger.trace('Mixer controller adjusting cw')
      @cw_switch.pulse_block((adjustment_time * 10).to_i)

      # Keep track of movement time for limiting movement
      @integrated_cw_movement_time += adjustment_time

      # Adjust available movement time for the other direction
      @integrated_ccw_movement_time -= adjustment_time
      @integrated_ccw_movement_time = 0 if @integrated_ccw_movement_time < 0
    else
      @logger.trace\
        ("Mixer controller not moving. Adj:#{adjustment_time.round(2)}"\
        " CW: #{@integrated_cw_movement_time} CCW: " + \
        @integrated_ccw_movement_time.to_s)
    end
  end

  # Calculate mixer motor actuation time based on error
  # This implements a simple P type controller with limited boundaries
  def calculate_adjustment_time(error)
    # Integrate the error if above the integrate threshold
    @int_err_sum += @config[:mixer_motor_ki_parameter] * error \
    if error.abs > @config[:mixer_motor_integrate_error_limit]

    if @int_err_sum.abs > @config[:mixer_motor_ival_limit]
      @int_err_sum = if @int_err_sum.positive?
                       @config[:mixer_motor_ival_limit]
                     else
                       -@config[:mixer_motor_ival_limit]
                     end
    end

    # Calculate the controller output
    retval = @config[:mixer_motor_kp_parameter] * error + @int_err_sum

    @logger.trace(\
      'Adjustments Pval: '\
      "#{(@config[:mixer_motor_kp_parameter] * error).round(2)} "\
      "Ival: #{@int_err_sum.round(2)}"
    )
    return 0 if retval.abs < @config[:min_mixer_motor_movement_time]

    if retval.abs > @config[:max_mixer_motor_movement_time]
      if retval.positive?
        @logger.trace("Calculated value: #{retval.round(2)} "\
          "returning: #{@config[:max_mixer_motor_movement_time]}")
        return @config[:max_mixer_motor_movement_time]
      else
        @logger.trace("Calculated value: #{retval.round(2)} "\
          "returning: -#{@config[:max_mixer_motor_movement_time]}")
        return -@config[:max_mixer_motor_movement_time]
      end
    end
    @logger.trace("Returning: #{retval.round(2)}")
    retval
  end
end
  # of class MixerControl
