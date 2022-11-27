class HeatingController
  private
  def create_pumps
    # Create pumps
    @radiator_pump =
      BusDevice::Switch.new(@homebus_device_base, 'Radiator pump',
                            'In the basement boiler room - '\
                            'Contact 4 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:radiator_pump_reg_addr], DRY_RUN)
    @floor_pump =
      BusDevice::Switch.new(@homebus_device_base, 'Floor pump',
                            'In the basement boiler room - '\
                            'Contact 5 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:floor_pump_reg_addr], DRY_RUN)
    @hydr_shift_pump =
      BusDevice::Switch.new(@homebus_device_base, 'Hydraulic shift pump',
                            'In the basement boiler room - '\
                            'Contact 6 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:hydr_shift_pump_reg_addr], DRY_RUN)
    @hot_water_pump =
      BusDevice::Switch.new(@homebus_device_base, 'Hot water pump',
                            'In the basement boiler room - '\
                            'Contact 7 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:hot_water_pump_reg_addr], DRY_RUN)
  end

  def create_sensors
    create_mixer_controller_sensors
    create_main_controller_sensors
    create_six_owbus_sensors
    create_hp_sensors
  end

  def create_mixer_controller_sensors
    @mixer_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Forward floor temperature',
                                'On the forward piping after the mixer valve',
                                @config[:mixer_controller_dev_addr],
                                @config[:mixer_fwd_sensor_reg_addr],
                                DRY_RUN, @config[:mixer_forward_mock_temp])
    @heat_return_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Heating return temperature',
                                'On the return piping before the buffer',
                                @config[:mixer_controller_dev_addr],
                                @config[:mixer_fwd_sensor_reg_addr],
                                DRY_RUN, @config[:mixer_forward_mock_temp])
    @forward_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Forward boiler temperature',
                                'On the forward piping of the boiler',
                                @config[:mixer_controller_dev_addr],
                                @config[:forward_sensor_reg_addr],
                                DRY_RUN, @config[:forward_mock_temp])
    @return_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Return water temperature',
                                'On the return piping of the boiler',
                                @config[:mixer_controller_dev_addr],
                                @config[:return_sensor_reg_addr],
                                DRY_RUN, @config[:return_mock_temp])
  end

  def create_main_controller_sensors
    @upper_buffer_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Upper Buffer temperature',
                                'Inside the buffer - upper section',
                                @config[:main_controller_dev_addr],
                                @config[:upper_buffer_sensor_reg_addr],
                                DRY_RUN, @config[:upper_buffer_mock_temp])
    @output_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Heating output temperature',
                                'After the joining of the buffer and the bypass',
                                @config[:main_controller_dev_addr],
                                @config[:output_sensor_reg_addr],
                                DRY_RUN, @config[:output_mock_temp])
    @hw_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Hot Water temperature',
                                'Inside the hot water container '\
                                'sensing tube',
                                @config[:main_controller_dev_addr],
                                @config[:hw_sensor_reg_addr],
                                DRY_RUN, @config[:HW_mock_temp])
  end

  def create_six_owbus_sensors
    @living_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Living room temperature',
                                'Temperature in the living room',
                                @config[:six_owbus_dev_addr],
                                @config[:living_sensor_reg_addr],
                                DRY_RUN, @config[:living_mock_temp])
    @upstairs_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Upstairs temperature',
                                'Upstairs forest room',
                                @config[:six_owbus_dev_addr],
                                @config[:upstairs_sensor_reg_addr],
                                DRY_RUN, @config[:upstairs_mock_temp])
    @basement_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'Basement temperature',
                                'In the sauna rest area',
                                @config[:main_controller_dev_addr],
                                @config[:basement_sensor_reg_addr],
                                DRY_RUN, @config[:basement_mock_temp])
    @external_sensor =
      BusDevice::TempSensor.new(@homebus_device_base, 'External temperature',
                                'On the northwestern external wall',
                                @config[:six_owbus_dev_addr],
                                @config[:external_sensor_reg_addr],
                                DRY_RUN, @config[:external_mock_temp])
  end

  def create_hp_sensors
    @hp_ehs_active =
      BusDevice::BinaryInput.new(@homebus_device_base, 'EHS signal from HP',
                                 'On HP controller board',
                                 @config[:hp_controller_dev_addr],
                                 @config[:hp_ehs_input_reg_addr],
                                  DRY_RUN, @config[:external_mock_temp])

    @hp_cooling_mode_active =
      BusDevice::BinaryInput.new(@homebus_device_base, 'EHS signal from HP',
                                 'On HP controller board',
                                 @config[:hp_controller_dev_addr],
                                 @config[:hp_heat_cool_input_reg_addr],
                                 DRY_RUN, @config[:external_mock_temp])

    @hp_backup_heater_active =
      BusDevice::BinaryInput.new(@homebus_device_base, 'EHS signal from HP',
                                 'On HP controller board',
                                 @config[:hp_controller_dev_addr],
                                 @config[:hp_backup_heater_input_reg_addr],
                                 DRY_RUN, @config[:external_mock_temp])

    @hp_alarm_active =
      BusDevice::BinaryInput.new(@homebus_device_base, 'EHS signal from HP',
                                 'On HP controller board',
                                 @config[:hp_controller_dev_addr],
                                 @config[:hp_alarm_input_reg_addr],
                                 DRY_RUN, @config[:external_mock_temp])
  end

  # Create value procs/lambdas
  def create_valueprocs
    # Create the is_HW or valve movement proc for the floor PWM thermostats
    @is_hw_or_valve_proc = proc {
      determine_power_needed == :HW || @moving_valves_required == true
    }

    # Create the value proc for the basement thermostat. Lambda is used
    # because proc would also return the "return" command
    @basement_thermostat_valueproc = lambda { |sample_filter, target|
      return 0 if sample_filter.depth < 6

      error = target - sample_filter.value
      # Calculate compensation for water temperature drop
      multiplier = if @target_boiler_temp > 45
                     1
                   else
                     (45 - @target_boiler_temp) / 15 + 1
                   end

      value = (error + 0.9) / 5.0 * multiplier
      if value > 0.9
        value = 1
      elsif value < 0.2
        value = 0
      end
      return value
    }

    # Create the value proc for the cold outside thermostat. Lambda is used
    # because proc would also return the "return" command
    @cold_outside_valueproc = lambda { |sample_filter, target|
      outside_temp = sample_filter.value - target * 0
      # Operate radiators @50% if outside temperature is below -3 C
      value = 0
      if outside_temp < -5
        value = 0.5
      elsif outside_temp < -3
        value = 0.3
      elsif outside_temp < 2
        value = 0.1
      end
      return value
    }
  end

  # Create devices
  def create_devices
    create_thermostats
    create_valves
    create_relays
    create_temp_wipers
    create_controllers
  end

  def create_thermostats
    # Create thermostats, with default threshold values and hysteresis values
    @living_thermostat =
      BoilerBase::SymmetricThermostat.new(@living_sensor, 0.3, 0.0, 15)
    @hw_thermostat =
      BoilerBase::ASymmetricThermostat.new(@hw_sensor, 2, 0, 0.0, 8)
    @floor_thermostat =
      BoilerBase::SymmetricThermostat.new(@external_sensor,
                                          @config[:floor_hysteresis],
                                          @config[:floor_heating_threshold], 30)
    @mode_thermostat =
      BoilerBase::SymmetricThermostat.new(@external_sensor,
                                          @config[:mode_hysteresis],
                                          @config[:mode_threshold], 50)
    @upstairs_thermostat =
      BoilerBase::SymmetricThermostat.new(@upstairs_sensor, 0.3, 5.0, 15)
    @pwmbase = BoilerBase::PwmBase.new(@config, @is_hw_or_valve_proc,
                                       @config[:basement_pwm_timebase])
    @basement_thermostat =
      BoilerBase::PwmThermostat.new(@pwmbase, @basement_sensor, 30,
                                    @basement_thermostat_valueproc,
                                    'Basement thermostat')
    @cold_outside_thermostat =
      BoilerBase::PwmThermostat.new(@pwmbase, @external_sensor, 30,
                                    @cold_outside_valueproc,
                                    'Cold outside thermostat')
  end

  def create_valves
    # Create magnetic valves
    @basement_radiator_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Basement radiator valve',
           'Contact 8 on main board',
           @config[:main_controller_dev_addr],
           @config[:basement_radiator_valve_reg_addr],
           DRY_RUN)
    @basement_floor_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Basement floor valve',
           'Contact 9 on main board',
           @config[:main_controller_dev_addr],
           @config[:basement_floor_valve_reg_addr],
           DRY_RUN)
    @living_floor_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Living level floor valve',
           'In the living floor water distributor',
           @config[:six_owbus_dev_addr],
           @config[:living_floor_valve_reg_addr],
           DRY_RUN)
    @upstairs_floor_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Upstairs floor valve',
           'In the upstairs water distributor',
           @config[:six_owbus_dev_addr],
           @config[:upstairs_floor_valve_reg_addr],
           DRY_RUN)

    # Create buffer direction shift valves
    @hw_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Forward three-way valve',
           'After the boiler+buffer joint - Contact 2 on main board',
           @config[:main_controller_dev_addr],
           @config[:hw_valve_reg_addr], DRY_RUN, :init_from_device)

    # Create buffer bypass valves
    @bufferbypass_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Buffer bypass three-way valves',
           'After the heat exhanger and after the buffer output in tandem - Usebuffer Contact on mixer controller board',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_usebuffer_reg_addr], DRY_RUN, :init_from_device)

    # Create buffer bypass valves
    @hw_hp_only_valve = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Forward three-way valve',
           'After the heat exchanger before Gas boiler - HW_HP_ONLY Contact on mixer controller board',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_hp_hw_only_valve_reg_addr], DRY_RUN, :init_from_device)
  end

  def create_relays
    # Create heater relay switch
    @heater_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'Heater relay', 'Heater contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:heater_relay_reg_addr], DRY_RUN)

    # Create the HP heater relay switch
    @hp_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP heater relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_on_off_switch_reg_addr], DRY_RUN)

    # Create the HP low_tariff relay switch
    @hp_low_tariff_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP low tariff relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_low_tariff_switch_reg_addr], DRY_RUN)

    # Create the HP night mode relay switch
    @hp_night_mode_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP night mode relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_night_mode_switch_reg_addr], DRY_RUN)

    # Create the HP heat/cool mode relay switch
    @hp_heat_cool_mode_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP heat/cool mode relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_heat_cool_switch_reg_addr], DRY_RUN)

    # Create the HP dual point relay switch
    @hp_dual_setpoint_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP dual setpoint relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_dual_setpoint_switch_reg_addr], DRY_RUN)

    # Create the HP HW relay switch
    @hp_hw_relay = \
      BusDevice::Switch\
      .new(@homebus_device_base, 'HP HW switch relay', 'Relay contact on HP controller',
           @config[:hp_controller_dev_addr],
           @config[:hp_hw_switch_reg_addr], DRY_RUN)

    # Create mixer pulsing switches
    @cw_switch = \
      BusDevice::PulseSwitch\
      .new(@homebus_device_base, 'CW mixer switch', 'In the mixer controller box',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_cw_reg_addr], DRY_RUN)

    @ccw_switch = \
      BusDevice::PulseSwitch\
      .new(@homebus_device_base, 'CCW mixer switch', 'In the mixer controller box',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_ccw_reg_addr], DRY_RUN)
  end

  def create_temp_wipers
    # Create water temp wipers
    @heating_watertemp = \
      BusDevice::HeatingWaterTemp\
      .new(@homebus_device_base, 'Heating temp wiper',
           'Heating wiper contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:heating_wiper_reg_addr], DRY_RUN,
           @config[:heating_temp_shift])
    @hw_watertemp = \
      BusDevice::HWWaterTemp\
      .new(@homebus_device_base, 'HW temp wiper',
           'HW wiper contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:hw_wiper_reg_addr], DRY_RUN,
           @config[:hw_temp_shift])

    @hp_dhw_wiper = \
      BusDevice::HPHWWaterTemp\
      .new(@homebus_device_base, 'HP HW temp wiper',
           'HW wiper contact on HP panel',
           @config[:hp_controller_dev_addr],
           @config[:hp_hw_wiper_reg_addr], DRY_RUN,
           0)
    # @hp_heating_wiper = \
    # BusDevice::WE_need_a_New_Class_Here\
    # .new(@homebus_device_base, 'HP HW temp wiper',
    #     'HW wiper contact on HP panel',
    #     @config[:hp_controller_dev_addr],
    #     @config[:hp_heat_wiper_reg_addr], DRY_RUN,
    #     0)
    #     
  end

  def create_controllers
    # Create the BufferHeat controller
    @buffer_heater = \
      BufferHeat\
      .new(@forward_sensor, @upper_buffer_sensor,
           @output_sensor, @return_sensor, @heat_return_sensor,
           @hw_sensor, @hw_valve, @bufferbypass_valve,
           @heater_relay, @hp_relay, @hp_dhw_wiper,
           @hydr_shift_pump, @hot_water_pump, @hw_watertemp,
           @heating_watertemp,
           @config)

    # Create the Mixer controller
    @mixer_controller = \
      BoilerBase::MixerControl\
      .new(@mixer_sensor, @cw_switch, @ccw_switch, @config)
  end
end