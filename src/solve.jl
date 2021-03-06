function init(prob::AbstractDDEProblem{uType,tType,lType,isinplace}, alg::algType,
              timeseries_init=uType[], ts_init=tType[], ks_init=[];
              d_discontinuities::Vector{Discontinuity{tType}}=Discontinuity{tType}[],
              dtmax = (prob.constant_lags == nothing || isempty(prob.constant_lags)) ?
              prob.tspan[2]-prob.tspan[1] : tType(7*minimum(prob.constant_lags)),
              dt=zero(tType), saveat=tType[], tstops = tType[],
              save_idxs=nothing, save_everystep=isempty(saveat),
              save_start=true, save_end = true,
              dense=save_everystep && !(typeof(alg) <: FunctionMap),
              minimal_solution=true, discontinuity_interp_points::Int=10,
              discontinuity_abstol=tType(1//Int64(10)^12), discontinuity_reltol=0,
              initial_order=agrees(prob.h, prob.u0, prob.p, prob.tspan[1]) ? 1 : 0,
              initialize_integrator = true, initialize_save = true,
              callback=nothing, kwargs...) where
    {uType,tType,lType,isinplace,algType<:AbstractMethodOfStepsAlgorithm}

    neutral = prob.neutral
    constant_lags = prob.constant_lags
    dependent_lags = prob.dependent_lags
    p = prob.p

    # no fixed-point iterations for constrained algorithms,
    # and thus `dtmax` should match minimal lag
    if isconstrained(alg) && constant_lags != nothing && !isempty(constant_lags)
        dtmax = min(dtmax, constant_lags...)
    end

    # bootstrap the integrator using an ODE problem, but do not initialize it since
    # ODE solvers only accept functions f(du,u,p,t) or f(u,p,t) without history function
    ode_prob = ODEProblem{isinplace}(prob.f, prob.u0, prob.tspan, p,
                                     mass_matrix = prob.mass_matrix)
    integrator = init(ode_prob, alg.alg; initialize_integrator=false,
                      dt=one(tType), dtmax=dtmax, kwargs...)

    # ensure that ODE integrator satisfies tprev + dt == t
    integrator.dt = zero(integrator.dt)
    integrator.dtcache = zero(integrator.dt)

    # create new solution based on this integrator with an interpolation function of the
    # expected form f(du,u,p,t) or f(u,p,t) which already includes information about the
    # history function of the DDE problem, the current solution of the integrator, and
    # the extrapolation of the integrator for the future
    interp_h = HistoryFunction(prob.h, integrator.sol, integrator)
    if isinplace
        interp_f = (du,u,p,t) -> prob.f(du,u,interp_h,p,t)
    else
        interp_f = (u,p,t) -> prob.f(u,interp_h,p,t)
    end

    if typeof(alg.alg) <: OrdinaryDiffEq.OrdinaryDiffEqCompositeAlgorithm
        interp_data = OrdinaryDiffEq.CompositeInterpolationData(integrator.sol.interp,
                                                                interp_f)
    else
        interp_data = OrdinaryDiffEq.InterpolationData(integrator.sol.interp,
                                                       interp_f)
    end

    if typeof(alg.alg) <: OrdinaryDiffEq.OrdinaryDiffEqCompositeAlgorithm
        sol = build_solution(prob, integrator.sol.alg, integrator.sol.t, integrator.sol.u,
                             dense=integrator.sol.dense, k=integrator.sol.k,
                             interp=interp_data, alg_choice=integrator.sol.alg_choice,
                             calculate_error = false)
    else
        sol = build_solution(prob, integrator.sol.alg, integrator.sol.t, integrator.sol.u,
                             dense=integrator.sol.dense, k=integrator.sol.k,
                             interp=interp_data, calculate_error = false)
    end

    # use this improved solution together with the given history function and the integrator
    # to create a problem function of the DDE with all available history information that is
    # of the form f(du,u,p,t) or f(u,p,t) such that ODE algorithms can be applied
    dde_h = HistoryFunction(prob.h, sol, integrator)
    if isinplace
        dde_f = (du,u,p,t) -> prob.f(du,u,dde_h,p,t)
    else
        dde_f = (u,p,t) -> prob.f(u,dde_h,p,t)
    end

    # absolut tolerance for fixed-point iterations has to be of same type as elements of u
    # in particular important for calculations with units
    if typeof(alg.fixedpoint_abstol) <: Void
        fixedpoint_abstol_internal = map(eltype(uType), integrator.opts.abstol)
    else
        fixedpoint_abstol_internal = map(eltype(uType), alg.fixedpoint_abstol)
    end

    # use norm of ODE integrator if no norm for fixed-point iterations is specified
    if typeof(alg.fixedpoint_norm) <: Void
        fixedpoint_norm = integrator.opts.internalnorm
    end

    # derive unitless types
    uEltypeNoUnits = typeof(recursive_one(integrator.u))
    tTypeNoUnits = typeof(recursive_one(prob.tspan[1]))

    # relative tolerance for fixed-point iterations has to be of same type as elements of u
    # without units
    # in particular important for calculations with units
    if typeof(alg.fixedpoint_reltol) <: Void
        fixedpoint_reltol_internal = map(uEltypeNoUnits, integrator.opts.reltol)
    else
        fixedpoint_reltol_internal = map(uEltypeNoUnits, alg.fixedpoint_reltol)
    end

    # create separate copies u and uprev, not pointing to integrator.u or integrator.uprev,
    # containers for residuals and to cache uprev with correct dimensions and types
    # in particular for calculations with units residuals have to be unitless
    if typeof(integrator.u) <: AbstractArray
        u = recursivecopy(integrator.u)
        uprev = recursivecopy(integrator.uprev)
        resid = similar(integrator.u, uEltypeNoUnits)
    else
        u = deepcopy(integrator.u)
        uprev = deepcopy(integrator.uprev)
        resid = one(uEltypeNoUnits)
    end

    # create uprev2 in same way as in OrdinaryDiffEq
    if integrator.uprev === integrator.uprev2
        uprev2 = uprev
    else
        if uType <: Array
            uprev2 = copy(uprev)
        else
            uprev2 = deepcopy(uprev)
        end
    end

    # check if all indices should be returned
    if !(typeof(save_idxs) <: Void) && collect(save_idxs) == collect(1:length(integrator.u))
        save_idxs = nothing # prevents indexing of ODE solution and saves memory
    end

    # new cache with updated u, uprev, uprev2, and function f
    if typeof(alg.alg) <: OrdinaryDiffEq.OrdinaryDiffEqCompositeAlgorithm
        caches = map((x,y) -> build_linked_cache(x, y, u, uprev, uprev2, dde_f,
                                                 prob.tspan[1], dt, p),
                     integrator.cache.caches, alg.alg.algs)
        dde_cache = OrdinaryDiffEq.CompositeCache(caches, alg.alg.choice_function, 1)
    else
        dde_cache = build_linked_cache(integrator.cache, alg.alg, u, uprev, uprev2, dde_f,
                                       prob.tspan[1], dt, p)
    end

    # filter provided discontinuities
    filter!(x -> x.order ≤ alg_maximum_order(alg) + 1, d_discontinuities)

    # retrieve time stops, time points at which solutions is saved, and discontinuities
    tstops_internal, saveat_internal, d_discontinuities_internal =
        tstop_saveat_disc_handling(tstops, saveat, d_discontinuities, integrator.tdir,
                                   prob.tspan, initial_order, alg_maximum_order(alg), constant_lags, tType)

    # create array of tracked discontinuities
    # used to find propagated discontinuities with callbacks and to keep track of all
    # passed discontinuities
    if initial_order ≤ alg_maximum_order(alg)
        tracked_discontinuities = [Discontinuity(prob.tspan[1], initial_order)]
    else
        tracked_discontinuities = Discontinuity{tType}[]
    end

    # create additional callback to track dependent delays
    if !(typeof(dependent_lags) <: Void) && !isempty(dependent_lags)
        discontinuity_callback = DiscontinuityCallback(dependent_lags,
                                                       tracked_discontinuities,
                                                       discontinuity_interp_points,
                                                       discontinuity_abstol,
                                                       discontinuity_reltol,
                                                       initialize!)
        callbacks = CallbackSet(callback, prob.callback, discontinuity_callback)
    else
        callbacks = CallbackSet(callback, prob.callback)
    end

    # separate options of integrator and ODE integrator since ODE integrator always saves
    # every step and every index (necessary for history function)
    opts = OrdinaryDiffEq.DEOptions(integrator.opts.maxiters,
                                    integrator.opts.timeseries_steps, save_everystep,
                                    integrator.opts.adaptive, integrator.opts.abstol,
                                    integrator.opts.reltol, integrator.opts.gamma,
                                    integrator.opts.qmax, integrator.opts.qmin,
                                    integrator.opts.qsteady_max,
                                    integrator.opts.qsteady_min,
                                    integrator.opts.failfactor, integrator.opts.dtmax,
                                    integrator.opts.dtmin, integrator.opts.internalnorm,
                                    save_idxs, tstops_internal, saveat_internal,
                                    d_discontinuities_internal,
                                    tstops, saveat, d_discontinuities,
                                    integrator.opts.userdata, integrator.opts.progress,
                                    integrator.opts.progress_steps,
                                    integrator.opts.progress_name,
                                    integrator.opts.progress_message,
                                    integrator.opts.timeseries_errors,
                                    integrator.opts.dense_errors, integrator.opts.beta1,
                                    integrator.opts.beta2, integrator.opts.qoldinit,
                                    dense && integrator.opts.dense, save_start, save_end,
                                    callbacks, integrator.opts.isoutofdomain,
                                    integrator.opts.unstable_check,
                                    integrator.opts.verbose, integrator.opts.calck,
                                    integrator.opts.force_dtmin,
                                    integrator.opts.advance_to_tstop,
                                    integrator.opts.stop_at_next_tstop)

    # reduction of solution only possible if no dense interpolation required and only
    # selected time points saved, and all constant and no dependent lags are given
    # WARNING: can impact quality of solution if not all constant lags specified
    minimal_solution = minimal_solution && !opts.dense && !opts.save_everystep &&
        constant_lags != nothing && !isempty(constant_lags) &&
        (typeof(dependent_lags) <: Void || isempty(dependent_lags))

    # need copy of heap of additional time points (nodes will be deleted!) in order to
    # remove unneeded time points of ODE solution as soon as possible and keep track
    # of passed time points
    if minimal_solution
        saveat_copy = deepcopy(opts.saveat)
    else
        saveat_copy = nothing
    end

    # create DDE integrator combining the new defined problem function with history
    # information, the new solution, the parameters of the ODE integrator, and
    # parameters of fixed-point iteration
    # do not initialize fsalfirst and fsallast
    dde_int = DDEIntegrator{typeof(integrator.alg),uType,tType,typeof(p),
                            typeof(integrator.eigen_est),
                            typeof(fixedpoint_abstol_internal),
                            typeof(fixedpoint_reltol_internal),typeof(resid),tTypeNoUnits,
                            typeof(integrator.tdir),typeof(integrator.k),typeof(sol),
                            typeof(dde_f),typeof(integrator.prog),typeof(dde_cache),
                            typeof(integrator),typeof(fixedpoint_norm),typeof(opts),
                            typeof(saveat_copy),fsal_typeof(integrator)}(
                                sol, u, integrator.k, integrator.t, dt, dde_f, p, uprev,
                                uprev2, integrator.tprev, 1, 1, fixedpoint_abstol_internal,
                                fixedpoint_reltol_internal, resid, fixedpoint_norm,
                                alg.max_fixedpoint_iters, saveat_copy,
                                tracked_discontinuities, integrator.alg,
                                integrator.dtcache,
                                integrator.dtchangeable, integrator.dtpropose,
                                integrator.tdir, integrator.eigen_est,
                                integrator.EEst, integrator.qold,
                                integrator.q11, integrator.erracc, integrator.dtacc,
                                integrator.success_iter, integrator.iter,
                                integrator.saveiter, integrator.saveiter_dense,
                                integrator.prog, dde_cache, integrator.kshortsize,
                                integrator.force_stepfail, integrator.just_hit_tstop,
                                integrator.last_stepfail, integrator.event_last_time,
                                integrator.accept_step,
                                integrator.isout, integrator.reeval_fsal,
                                integrator.u_modified, opts, integrator)

    # if time step is not set and DDE integrator has adaptive step size,
    # automatically determine initial time step
    if iszero(dde_int.dt) && dde_int.opts.adaptive
        auto_dt_reset!(dde_int)
    end

    # initialize DDE integrator and callbacks
    if initialize_integrator
        initialize_callbacks!(dde_int, initialize_save)
        initialize!(dde_int)
        typeof(alg.alg) <: OrdinaryDiffEq.CompositeAlgorithm &&
            copyat_or_push!(dde_int.sol.alg_choice, 1, dde_int.cache.current)
    end

    dde_int
end

function solve!(integrator::DDEIntegrator)
    # step over all stopping time points, similar to solving with ODE integrators
    @inbounds while !isempty(integrator.opts.tstops)
        while integrator.tdir * integrator.t < integrator.tdir * top(integrator.opts.tstops)
            # apply step or adapt step size
            loopheader!(integrator)

            # abort integration following same criteria as for ODEs:
            # maxiters exceeded, dt <= dtmin, integration unstable
            OrdinaryDiffEq.@ode_exit_conditions

            # calculate next step
            perform_step!(integrator)

            # calculate proposed next step size, handle callbacks, and update solution
            loopfooter!(integrator)

            if isempty(integrator.opts.tstops)
                break
            end
        end

        # remove hit or passed stopping time points
        handle_tstop!(integrator)
    end

    # clean up solution
    postamble!(integrator)

    # create array of time points and values that form solution
    sol_array = build_solution_array(integrator)

    # create interpolation data of solution
    interp = build_solution_interpolation(integrator, sol_array)

    # obtain DDE problem
    prob = integrator.sol.prob

    # calculate analytical solutions to problem if existent
    if has_analytic(prob.f)
        if typeof(integrator.opts.save_idxs) <: Void
            u_analytic = [prob.f(Val{:analytic}, integrator.sol[1], integrator.p, t) for t in sol_array.t]
        else
            u_analytic = [@view(prob.f(
                Val{:analytic}, integrator.sol[1], integrator.p, t)[integrator.opts.save_idxs])
                          for t in sol_array.t]
        end
        errors = Dict{Symbol,eltype(integrator.u)}()
    else
        u_analytic = nothing
        errors = nothing
    end

    # combine arrays of time points and values, interpolation data, and analytical solution
    # to solution
    if typeof(prob.u0) <: Tuple
      N = length((size(ArrayPartition(prob.u0))..., length(sol_array.u)))
    else
      N = length((size(prob.u0)..., length(sol_array.u)))
    end

    if typeof(integrator.alg) <: OrdinaryDiffEq.OrdinaryDiffEqCompositeAlgorithm
        sol = OrdinaryDiffEq.ODECompositeSolution{
            eltype(sol_array),N,typeof(sol_array.u),typeof(u_analytic),
            typeof(errors),typeof(sol_array.t),typeof(interp.ks),
            typeof(prob),typeof(integrator.sol.alg),typeof(interp)}(
                sol_array.u, u_analytic, errors, sol_array.t, interp.ks,
                prob, integrator.sol.alg, interp, interp.alg_choice,
                interp.dense, integrator.sol.tslocation, :Success)
    else
        sol = ODESolution{
            eltype(sol_array),N,typeof(sol_array.u),typeof(u_analytic),
            typeof(errors),typeof(sol_array.t),typeof(interp.ks),
            typeof(prob),typeof(integrator.sol.alg),typeof(interp)}(
                sol_array.u, u_analytic, errors, sol_array.t, interp.ks,
                prob, integrator.sol.alg, interp, interp.dense,
                integrator.sol.tslocation, :Success)
    end

    # calculate errors of solution
    if sol.u_analytic != nothing
        calculate_solution_errors!(sol; fill_uanalytic=false,
                                   timeseries_errors=integrator.opts.timeseries_errors,
                                   dense_errors=integrator.opts.dense_errors)
    end

    return sol
end

function solve(prob::AbstractDDEProblem{uType,tType,lType,isinplace}, alg::algType,
               timeseries_init=uType[], ts_init=tType[], ks_init=[]; kwargs...) where
    {uType,tType,isinplace,algType<:AbstractMethodOfStepsAlgorithm,lType}

    integrator = init(prob, alg, timeseries_init, ts_init, ks_init; kwargs...)
    solve!(integrator)
end

function initialize_callbacks!(dde_int::DDEIntegrator, initialize_save = true)
    u = dde_int.u
    integrator = dde_int.integrator
    # set up additional initial values of newly created DDE integrator
    # (such as fsalfirst) and its callbacks

    dde_int.u_modified = true

    u_modified = initialize!(integrator.opts.callback,dde_int.t,u,dde_int)

    # if the user modifies u, we need to fix previous values before initializing
    # FSAL in order for the starting derivatives to be correct
    if u_modified

        if isinplace
            recursivecopy!(dde_int.uprev,dde_int.u)
        else
            dde_int.uprev = dde_int.u
        end

        if OrdinaryDiffEq.alg_extrapolates(dde_int.alg)
            if isinplace
                recursivecopy!(dde_int.uprev2,dde_int.uprev)
            else
                dde_int.uprev2 = dde_int.uprev
            end
        end

        # update heap of discontinuities
        # discontinuity is assumed to be of order 0, i.e. solution x is discontinuous
        push!(dde_int.opts.d_discontinuities, Discontinuity(dde_int.t, 0))

        # reset this as it is now handled so the integrators should proceed as normal
        reeval_internals_due_to_modification!(dde_int,Val{false})

        if initialize_save &&
          (any((c)->c.save_positions[2],integrator.opts.callback.discrete_callbacks) ||
          any((c)->c.save_positions[2],integrator.opts.callback.continuous_callbacks))
          savevalues!(dde_int,true)
        end

        # recompute initial time step
        auto_dt_reset!(dde_int)
    end

    # reset this as it is now handled so the integrators should proceed as normal
    dde_int.u_modified = false
end

function tstop_saveat_disc_handling(tstops, saveat, d_discontinuities, tdir, tspan, initial_order, alg_maximum_order, constant_lags, tType)
    # add discontinuities propagated from initial discontinuity
    if initial_order ≤ alg_maximum_order && constant_lags != nothing && !isempty(constant_lags)
        maxlag = tspan[2] - tspan[1]
        d_discontinuities_internal = unique(
            Discontinuity{tType}[d_discontinuities;
                                 (Discontinuity(tspan[1] + lag, initial_order + 1)
                                  for lag in constant_lags if lag < maxlag)...])
    else
        d_discontinuities_internal = unique(d_discontinuities)
    end

    return OrdinaryDiffEq.tstop_saveat_disc_handling(tstops, saveat, d_discontinuities_internal, tdir, tspan, tType)
end
