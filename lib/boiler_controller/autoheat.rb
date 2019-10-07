# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/boiler_base'
require '/usr/local/lib/boiler_controller/globals'

# Analyzes the stability of a sensor
# The analyzer takes measurements periodically and
# examines samples within a time window
class SensorAnalyzer
  def initialize(sensor, target, config)
    @sensor = sensor
    @sample_buffer =[]
    @target = target
    @config = config
    @window = @config[:sensor_stability_windowsize]
    @period = @config[:sensor_stability_period]
    @logger = config.logger.analyzer_logger
    @window = @period if @window < @period
    @nr_samples = window / period
    @delay_timer = Globals::TimerSec
                   .new(period, 'Analyzer sampling delay timer')
    @stop_analyzer_mutex = Mutex.new
    @sample_mutex = Mutex.new
    @analyzer_thread = nil
  end

  def start
    return unless @analyzer_thread.nil?

    sleep rand * period + 1
    @stop_analyzer_mutex.unlock if @stop_analyzer_mutex.locked?
    @delay_timer.reset
    @analyzer_thread = Thread.new { do_measurement }
  end

  def stop
    # Signal analyzer thread to exit
    @stop_analyzer_mutex.lock
    @analyzer_thread.join
    @analyzer_thread = nil
  end

  def do_measurement
    until @stop_analyzer_mutex.locked?
      if @delay_timer.expired?
        @sample_mutex.synchronize do
          @sample_buffer << [@sensor.temp]
          @sample_buffer.shift if @sample_buffer.size > @nr_samples
        end
        @logger.info("#{@sensor.name} - Sample size: #{@sample_buffer.size}")
      end
      sleep 0.1
    end
  end


end

# A PID controller for the boiler
class BoilerPID
  def initialize(output, heatmap, config, initial_target = 34.0)
    @target = initial_target
    @output = output
    @heatmap = heatmap
    @corrected_heatmap = heatmap.dup
    @config = config
    @logger = config.logger.analyzer_logger
  end

end
