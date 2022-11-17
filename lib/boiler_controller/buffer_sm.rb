# frozen_string_literal: true

require 'rubygems'
require 'finite_machine'

module BufferStates
  # The definition of the heating state machine
  class BufferSM < FiniteMachine::Definition
    alias_target :buffer

    event :turnoff, to: :off
    event :normal, to: :normal
    event :frombuffer, to: :frombuffer
    event :dhw, to: :hw
    event :init, none: :off

    # :off, :normal, :frombuffer, :hw

    # Log state transitions and arm the state change relaxation timer
    on_before do |event|
      buffer.logger.debug('Bufferheater state change from '\
                        "#{event.from} to #{event.to}")
      buffer.prev_sm_state = event.from
      buffer.heater_relax_timer.reset
    end

    # On turning off the controller will take care of pumps
    # - Turn off HW production of boiler
    # - Turn off the heater relay
    on_enter(:off) do |event|
      buffer.hp_relay.off if buffer.hp_relay.on?
      if event.name == :init
        buffer.logger.debug('Bufferheater initializing')
        buffer.hw_wiper.set_water_temp(65.0)
        buffer.set_relays(:normal)
        buffer.heater_relay.off if buffer.heater_relay.on?
      else
        buffer.logger.debug('Bufferheater turning off')
        if buffer.heater_relay.on?
          buffer.heater_relay.off
          sleep buffer.config[:circulation_maintenance_delay]
        else
          buffer.logger.debug('Heater relay already off')
        end
      end
    end
    # of enter off action

    # On entering heat through buffer shifter
    # - Turn off HW production of boiler
    # - move relay to normal
    # - start the boiler
    # - Start the hydr shift pump
    on_enter(:normal) do
      buffer.logger.debug('Activating normal state')
      buffer.hw_pump.off if buffer.hw_pump.on?
      buffer.heat_wiper.set_water_temp(\
        buffer.corrected_watertemp(buffer.target_temp)
      )
      # buffer.hydr_shift_pump.on
      sleep buffer.config[:circulation_maintenance_delay] \
        if buffer.set_relays(:normal) == :immediate
      # buffer.heater_relay.on
      buffer.hp_relay.on
    end
    # of enter normal action

    # On entering heating from buffer set relays and turn off heating
    # - Turn off HW production of boiler
    on_enter(:frombuffer) do
      buffer.logger.debug('Activating frombuffer state')
      buffer.hw_pump.off if buffer.hw_pump.on?
      buffer.heater_relay.off if buffer.heater_relay.on?
      buffer.hp_relay.off if buffer.hp_relay.on?

      # Dump excess heat into the buffer if coming from HW
      if buffer.prev_sm_state == :hw
        buffer.logger.debug('Coming from hw')
        buffer.set_relays(:normal)
        buffer.hydr_shift_pump.on
        buffer.hydr_shift_pump\
              .delayed_off(buffer.config[:post_HW_heat_dump_into_buffer_time])
      # Turn off hydr shift pump
      elsif buffer.hydr_shift_pump.on?
        # Wait for boiler to turn off safely
        buffer.logger.debug('Waiting for boiler to stop before '\
          'cutting it off from circulation')
        sleep buffer.config[:circulation_maintenance_delay]
        buffer.hydr_shift_pump.off
      end
    end
    # of enter frombuffer action

    # On entering hw
    # - Set relays to hw
    # - turn on HW pump
    # - start HW production
    # - turn off hydr shift pump
    on_enter(:hw) do
      buffer.logger.debug('Activating hw state')
      # buffer.hw_pump.on --- Removed for HP only HW activation
      sleep buffer.config[:circulation_maintenance_delay] if\
        buffer.set_relays(:hw) != :delayed
      if buffer.hydr_shift_pump.on?
        buffer.hydr_shift_pump.off
      else
        buffer.logger.debug('Hydr shift pump already off')
      end
      buffer.heatpump.heating_targettemp = 60
      buffer.hp_relay.on
    end
    # of enter HW action

    # On exiting hw
    # - stop hw production
    # - Turn off hw pump in a delayed manner
    on_exit(:hw) do
      buffer.logger.debug('Deactivating hw state')
      buffer.hw_wiper.set_water_temp(65.0)
      sleep buffer.config[:circulation_maintenance_delay]
    end
    # of exit hw action
  end
  # of class BufferSM

end