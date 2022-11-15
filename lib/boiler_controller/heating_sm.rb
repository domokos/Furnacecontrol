# frozen_string_literal: true

require 'rubygems'
require 'finite_machine'

module HeatingStates
  # The definition of the heating state machine
  class HeatingSM < FiniteMachine::Definition
    alias_target :controller

    event :turnon, off: :heating
    event :postheat, heating: :postheating
    event :posthw, heating: :posthwing
    event :turnoff, %i[postheating posthwing heating] => :off
    event :init, none: :off

    # Log state transitions and arm the state change relaxation timer
    on_before do |event|
        controller.logger.debug('Heating SM state change from '\
                            "#{event.from} to #{event.to}")
        controller.sm_relax_timer.reset
    end

    # Activation actions for Off satate
    on_enter(:off) do |event|
        # Perform initialization on startup
        if event.name == :init
            controller.logger.debug('Heater SM initiaization')

            # Expire the timer to allow immediate state change
            controller.sm_relax_timer.expire

            # Regular turn off
        else
            controller.logger.debug('Turning off heating')
            # Stop the mixer controller
            controller.mixer_controller.stop_control

            # Signal heater to turn off
            controller.buffer_heater.set_mode(:off)

            # Wait before turning pumps off to make sure we do not lose circulation
            controller.logger.debug('Waiting shutdown delay')
            sleep controller.config[:shutdown_delay]
        end
        # Turn off all pumps
        controller.radiator_pump.off
        controller.floor_pump.off
        controller.hydr_shift_pump.off
        controller.hot_water_pump.off

        # Close all valves
        controller.basement_floor_valve.delayed_close
        controller.basement_radiator_valve.delayed_close
        controller.living_floor_valve.delayed_close
        controller.upstairs_floor_valve.delayed_close

        # Wait for the delayed closure to happen
        controller.logger.debug('Waiting for delayed closure valves to close')
        sleep 3
    end

    # Activation actions for Heating
    on_enter(:heating) do
        controller.logger.debug('Activating "Heat" state')
        controller.mixer_controller.start_control
        # Do not control pumps or valves
    end

    # Activation actions for Post circulation heating
    on_enter(:postheating) do
        controller.logger.debug('Activating "Postheat" state')

        # Signal heater to turn off
        controller.buffer_heater.set_mode(:off)

        # Stop the mixer controller
        controller.mixer_controller.stop_control

        # Set the buffer for direct connection
        controller.buffer_heater.set_relays(:normal)

        # Hydr shift pump on
        controller.hydr_shift_pump.on

        # All other pumps off
        controller.floor_pump.off
        controller.hot_water_pump.off
        controller.radiator_pump.off

        # All valves closed
        controller.basement_radiator_valve.delayed_close
        controller.basement_floor_valve.delayed_close
        controller.living_floor_valve.delayed_close
        controller.upstairs_floor_valve.delayed_close

        # Wait for the delayed closure to happen
        controller.logger.debug('Waiting for delayed closure valves to close')
        sleep 3
    end

    # Activation actions for Post circulation heating
    on_enter(:posthwing) do
        controller.logger.debug('Activating "PostHW" state')

        # Signal heater to turn off
        controller.buffer_heater.set_mode(:off)

        # Set the buffer for direct connection
        controller.buffer_heater.set_relays(:HW)

        # Stop the mixer controller
        controller.mixer_controller.stop_control

        controller.hot_water_pump.on
        # Wait before turning pumps off to make sure we do not lose circulation
        sleep controller.config[:circulation_maintenance_delay]

        # Only HW pump on
        controller.radiator_pump.off
        controller.floor_pump.off
        controller.hydr_shift_pump.off

        # All valves are closed
        controller.basement_floor_valve.delayed_close
        controller.basement_radiator_valve.delayed_close
        controller.living_floor_valve.delayed_close
        controller.upstairs_floor_valve.delayed_close

        # Wait for the delayed closure to happen
        controller.logger.debug('Waiting for delayed closure valves to close')
        sleep 3
    end

  end
  # of class Heating SM
end