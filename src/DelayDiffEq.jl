__precompile__()

module DelayDiffEq

using Reexport
@reexport using OrdinaryDiffEq

using DataStructures, RecursiveArrayTools, MuladdMacro,
      DiffEqDiffTools, ForwardDiff, NLSolversBase, Roots

import OrdinaryDiffEq: initialize!, perform_step!, loopfooter!, loopheader!, alg_maximum_order,
                       handle_tstop!, ODEIntegrator, savevalues!, postamble!,
                       handle_callback_modifiers!, reeval_internals_due_to_modification!,
                       handle_discontinuities!, find_callback_time, apply_callback!,
                       initialize_callbacks!, tstop_saveat_disc_handling

import DiffEqBase: solve, solve!, init, resize!, u_cache, user_cache, du_cache, full_cache,
                   deleteat!, terminate!, u_modified!, get_proposed_dt, set_proposed_dt!,
                   has_reinit, reinit!, auto_dt_reset!

using OrdinaryDiffEq: Rosenbrock23Cache, Rosenbrock32Cache, ImplicitEulerCache,
    TrapezoidCache

using DiffEqBase: check_error!

include("discontinuity_type.jl")
include("integrator_type.jl")
include("integrator_utils.jl")
include("integrator_interface.jl")
include("interpolants.jl")
include("history_function.jl")
include("algorithms.jl")
include("callbacks.jl")
include("alg_utils.jl")
include("solve.jl")
include("utils.jl")

export Discontinuity, MethodOfSteps

end # module
