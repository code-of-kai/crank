defmodule Crank.Errors.Violation do
  @moduledoc """
  Canonical representation of a Crank purity-enforcement violation.

  Every check in Crank — Credo, `@before_compile`, Boundary integration,
  `Crank.PurityTrace`, property tests — produces a `%Crank.Errors.Violation{}`
  rather than a layer-specific error. The struct is rendered by `Crank.Errors`
  into whatever the surrounding context expects: a `CompileError`, a Credo
  issue, a property-test failure, or a structured map for agent consumption.

  See the `guides/violations/` directory for per-code documentation.
  """

  @typedoc "A frozen, stable violation code (e.g., `\"CRANK_PURITY_001\"`)."
  @type code :: binary()

  @typedoc "A short rule identifier (e.g., `:turn_purity_direct`)."
  @type rule :: atom()

  @typedoc "Severity of the violation."
  @type severity :: :error | :warning

  @typedoc "Where the violation was detected in source."
  @type location :: %{
          required(:file) => Path.t() | nil,
          required(:line) => non_neg_integer() | nil,
          optional(:column) => non_neg_integer() | nil,
          optional(:function) => binary() | nil
        }

  @typedoc "The offending call, when known."
  @type violating_call :: %{
          required(:module) => module() | binary(),
          required(:function) => atom() | binary(),
          required(:arity) => non_neg_integer()
        }

  @typedoc """
  The canonical fix description. Includes a category label, optional
  before/after code snippets, optional setup snippet, and a doc URL.
  """
  @type fix :: %{
          required(:category) => binary(),
          optional(:before) => binary(),
          optional(:after) => binary(),
          optional(:setup) => binary(),
          required(:doc_url) => binary()
        }

  @type t :: %__MODULE__{
          code: code(),
          severity: severity(),
          rule: rule(),
          location: location(),
          violating_call: violating_call() | nil,
          context: binary() | nil,
          fix: fix(),
          metadata: map()
        }

  @enforce_keys [:code, :severity, :rule, :location, :fix]
  defstruct [
    :code,
    :severity,
    :rule,
    :location,
    :violating_call,
    :context,
    :fix,
    metadata: %{}
  ]
end
