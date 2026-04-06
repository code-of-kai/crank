defmodule Crank.Generators do
  @moduledoc """
  StreamData generators for property-testing Crank.

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
      Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, machine ->
        Crank.crank(machine, event)
      end)
    end
  end

  @doc "Produce a Door machine in a random reachable state."
  def door_in_random_state do
    gen all(events <- list_of(door_event(), min_length: 0, max_length: 20)) do
      events
      |> Enum.reduce_while(Crank.new(Crank.Examples.Door), fn event, machine ->
        try do
          {:cont, Crank.crank(machine, event)}
        rescue
          FunctionClauseError -> {:cont, machine}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Order machine generators (complex, total)
  # ---------------------------------------------------------------------------

  @doc "A valid event for the Order machine."
  def order_event do
    member_of(Crank.Examples.Order.events())
  end

  @doc "A random sequence of Order events."
  def order_event_sequence(max_length \\ 50) do
    list_of(order_event(), min_length: 1, max_length: max_length)
  end

  @doc "An Order machine cranked to a random reachable state."
  def order_in_random_state do
    gen all(events <- list_of(order_event(), min_length: 0, max_length: 30)) do
      Enum.reduce(events, Crank.new(Crank.Examples.Order), fn event, m ->
        Crank.crank(m, event)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Submission machine generators (Wlaschin-style struct states)
  # ---------------------------------------------------------------------------

  @doc "A valid event for the Submission machine."
  def submission_event do
    one_of([
      member_of([:validate, :bind, :decline, :note, :noop]),
      map(member_of([:bad_limit, :missing_class, :invalid_territory, :excess_exposure]),
          &{:violation, &1}),
      map(integer(1..1000), &{:add_quote, %{premium: &1}}),
      map(integer(0..9), &{:select, &1})
    ])
  end

  @doc "A random sequence of Submission events."
  def submission_event_sequence(max_length \\ 50) do
    list_of(submission_event(), min_length: 1, max_length: max_length)
  end

  @doc "A Submission machine cranked to a random reachable state."
  def submission_in_random_state do
    gen all(events <- list_of(submission_event(), min_length: 0, max_length: 30)) do
      Enum.reduce(events, Crank.new(Crank.Examples.Submission), fn event, m ->
        Crank.crank(m, event)
      end)
    end
  end
end
