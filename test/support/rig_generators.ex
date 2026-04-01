defmodule Rig.Generators do
  @moduledoc """
  StreamData generators for property-testing Rig.

  Generators compose bottom-up:
  - Level 1: states, events (leaf atoms)
  - Level 2: event sequences (lists of valid events for a machine)
  - Level 3: machines in specific states
  """

  use ExUnitProperties

  # ---------------------------------------------------------------------------
  # Level 1: Leaf generators
  # ---------------------------------------------------------------------------

  @doc "A valid state for the Turnstile machine."
  def turnstile_state do
    member_of([:locked, :unlocked])
  end

  @doc "A valid event for the Turnstile machine."
  def turnstile_event do
    member_of([:coin, :push])
  end

  @doc "A valid state for the Door machine."
  def door_state do
    member_of([:locked, :unlocked, :opened])
  end

  @doc "A valid event for the Door machine."
  def door_event do
    member_of([:unlock, :lock, :open, :close])
  end

  # ---------------------------------------------------------------------------
  # Level 2: Event sequences
  # ---------------------------------------------------------------------------

  @doc """
  A random sequence of Turnstile events (1..max_length).
  Every event is valid for the machine — the machine may or may not
  handle it in its current state (which is the point of testing).
  """
  def turnstile_event_sequence(max_length \\ 50) do
    list_of(turnstile_event(), min_length: 1, max_length: max_length)
  end

  @doc "A random sequence of Door events."
  def door_event_sequence(max_length \\ 50) do
    list_of(door_event(), min_length: 1, max_length: max_length)
  end

  # ---------------------------------------------------------------------------
  # Level 3: Machine construction helpers
  # ---------------------------------------------------------------------------

  @doc """
  Produce a Turnstile machine that has been cranked through a random
  prefix of events, landing in some arbitrary valid state.
  """
  def turnstile_in_random_state do
    gen all(events <- list_of(turnstile_event(), min_length: 0, max_length: 20)) do
      Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, machine ->
        Rig.crank(machine, event)
      end)
    end
  end

  @doc "Produce a Door machine in a random reachable state."
  def door_in_random_state do
    gen all(events <- list_of(door_event(), min_length: 0, max_length: 20)) do
      events
      |> Enum.reduce_while(Rig.new(Rig.Examples.Door), fn event, machine ->
        try do
          {:cont, Rig.crank(machine, event)}
        rescue
          FunctionClauseError -> {:cont, machine}
        end
      end)
    end
  end
end
