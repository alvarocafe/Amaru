# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru

export solve!


#=
mutable struct HMSolver<:Solver
    nincs::Integer
    nouts::Integer
    filekey::String
    #loggers::Array{AbstractLogger,1}
    stage::Integer
    shared_data::SharedAnalysisData

    Fint::Array{Float64,1}
end

function run(solver::HMSolver, dom::Domain, bc::BC, ....)
end
=#


# Assemble the global stiffness matrix
function mount_G_RHS(dom::Domain, ndofs::Int, Δt::Float64)

    # Assembling matrix G

    R, C, V = Int64[], Int64[], Float64[]
    RHS = zeros(ndofs)

    α = 1.0 # time integration factor

    for elem in dom.elems

        ty = typeof(elem)
        has_stiffness_matrix    = hasmethod(elem_stiffness, (ty,))
        has_coupling_matrix     = hasmethod(elem_coupling_matrix, (ty,))
        has_conductivity_matrix = hasmethod(elem_conductivity_matrix, (ty,))
        has_RHS_vector          = hasmethod(elem_RHS_vector, (ty,))


        # Assemble the stiffness matrix
        if has_stiffness_matrix
            K, rmap, cmap = elem_stiffness(elem)
            nr, nc = size(K)
            for i=1:nr
                for j=1:nc
                    push!(R, rmap[i])
                    push!(C, cmap[j])
                    push!(V, K[i,j])
                end
            end
        end

        # Assemble the coupling matrices
        if has_coupling_matrix
            Cup, rmap, cmap = elem_coupling_matrix(elem)
            nr, nc = size(Cup)
            for i=1:nr
                for j=1:nc
                    # matrix Cup
                    push!(R, rmap[i])
                    push!(C, cmap[j])
                    push!(V, Cup[i,j])

                    # matrix Cup'
                    push!(R, cmap[j])
                    push!(C, rmap[i])
                    push!(V, Cup[i,j])
                end
            end
        end


        # Assemble the conductivity matrix
        if has_conductivity_matrix
            H, rmap, cmap =  elem_conductivity_matrix(elem)
            nr, nc = size(H)
            for i=1:nr
                for j=1:nc
                    push!(R, rmap[i])
                    push!(C, cmap[j])
                    push!(V, α*Δt*H[i,j])
                end
            end
            
            # Assembling RHS components
            Uw = [ node.dofdict[:uw].vals[:uw] for node in elem.nodes ]
            RHS[rmap] -= Δt*(H*Uw)
        end

        # Assemble ramaining RHS vectors
        if has_RHS_vector
            Q, map = elem_RHS_vector(elem)
            RHS[map] += Δt*Q
        end
    end

    # generating sparse matrix G
    local G
    try
        G = sparse(R, C, V, ndofs, ndofs)
    catch err
        @show ndofs
        @show err
    end

    return G, RHS
end


# Solves for a load/displacement increment
function hm_solve_step!(G::SparseMatrixCSC{Float64, Int}, DU::Vect, DF::Vect, nu::Int)
    #  [  G11   G12 ]  [ U1? ]    [ F1  ]
    #  |            |  |     | =  |     |
    #  [  G21   G22 ]  [ U2  ]    [ F2? ]

    ndofs = length(DU)
    umap  = 1:nu
    pmap  = nu+1:ndofs
    if nu == ndofs 
        @warn "solve!: No essential boundary conditions."
    end

    # Global stifness matrix
    if nu>0
        nu1 = nu+1
        G11 = G[1:nu, 1:nu]
        G12 = G[1:nu, nu1:end]
        G21 = G[nu1:end, 1:nu]
    end
    G22 = G[nu+1:end, nu+1:end]

    F1  = DF[1:nu]
    U2  = DU[nu+1:end]

    # Solve linear system
    F2 = G22*U2
    U1 = zeros(nu)
    if nu>0
        RHS = F1 - G12*U2
        try
            LUfact = lu(G11)
            U1  = LUfact\RHS
            F2 += G21*U1
        catch err
            @warn "solve!: $err"
            U1 .= NaN
        end
    end

    # Completing vectors
    DU[1:nu]     .= U1
    DF[nu+1:end] .= F2
end

"""
    solve!(D, bcs, options...) -> Bool

Performs one stage finite element analysis of a mechanical domain `D`
subjected to an array of boundary conditions `bcs`.

Available options are:

`verbose=true` : If true, provides information of the analysis steps

`tol=1e-2` : Tolerance for the absolute error in forces

`nincs=1` : Number of increments

`autoinc=false` : Sets automatic increments size. The first increment size will be `1/nincs`

`maxits=5` : The maximum number of Newton-Rapson iterations per increment

`saveincs=false` : If true, saves output files according to `nouts` option

`nouts=0` : Number of output files per analysis

`scheme= :FE` : Predictor-corrector scheme at iterations. Available schemes are `:FE` and `:ME`

"""
function hm_solve!(dom::Domain, bcs::Array; time_span::Float64=NaN, end_time::Float64=NaN, nincs::Int=1, maxits::Int=5, autoinc::Bool=false, 
    tol::Number=1e-2, verbose::Bool=true, silent::Bool=false, nouts::Int=0,
    scheme::Symbol = :FE)

    # Arguments checking
    saveincs = nouts>0
    silent && (verbose=false)

    if !silent
        printstyled("Hydromechanical FE analysis: Stage $(dom.stage+1)\n", bold=true, color=:cyan)
        tic = time()
    end

    if !isnan(end_time)
        time_span = end_time - dom.shared_data.t
    end

    # Get dofs organized according to boundary conditions
    dofs, nu = configure_dofs!(dom, bcs) # unknown dofs first
    ndofs = length(dofs)
    umap  = 1:nu         # map for unknown displacements and pw
    pmap  = nu+1:ndofs   # map for prescribed displacements and pw
    dom.ndofs = length(dofs)
    silent || println("  unknown dofs: $nu")
    
    # Get array with all integration points
    ips = [ ip for elem in dom.elems for ip in elem.ips ]

    # Setup for fisrt stage
    if dom.nincs == 0
        # Setup initial quantities at dofs
        for (i,dof) in enumerate(dofs)
            dof.vals[dof.name]    = 0.0
            dof.vals[dof.natname] = 0.0
        end

        # Tracking nodes, ips, elements, etc.
        update_loggers!(dom)  

        # Save first output file
        if saveincs 
            save(dom, "$(dom.filekey)-0.vtk", verbose=false)
            silent || printstyled("  $(dom.filekey)-0.vtk file written (Domain)\n", color=:green)
        end
    end


    # Backup the last converged state at ips. TODO: make backup to a vector of states
    for ip in ips
        ip.data0 = deepcopy(ip.data)
    end

    # Incremental analysis
    t    = dom.shared_data.t # current time
    tend = t + time_span  # end time
    Δt = time_span/nincs # initial Δt value

    dT = time_span/nouts  # output time increment for saving vtk file
    T  = t + dT        # output time for saving the next vtk file

    ttol = 1e-9    # time tolerance
    inc  = 1       # increment counter
    iout = dom.nouts     # file output counter
    F    = zeros(ndofs)  # total internal force for current stage
    U    = zeros(ndofs)  # total displacements for current stage
    R    = zeros(ndofs)  # vector for residuals of natural values
    ΔFin = zeros(ndofs)  # vector of internal natural values for current increment
    ΔUa  = zeros(ndofs)  # vector of essential values (e.g. displacements) for this increment
    ΔUi  = zeros(ndofs)  # vector of essential values for current iteration

    uw_map = [ dof.eq_id for dof in dofs if dof.name == :uw ]
    uz_map = [ dof.eq_id for dof in dofs if dof.name == :uz ]

    Fex  = zeros(ndofs)  # vector of external loads
    Uex  = zeros(ndofs)  # vector of external essential values

    Uex, Fex = get_bc_vals(dom, bcs, t) # get values at time t  #TODO pick internal forces and displacements instead!
    
    for (i,dof) in enumerate(dofs)
        U[i] = dof.vals[dof.name]
        F[i] = dof.vals[dof.natname]
    end
#
    #Uex[umap] .= 0.0
    #Fex[pmap] .= 0.0

    #@show round.(F,10)

    while t < tend - ttol

        verbose && printstyled("  increment $inc from t=$(round(t,sigdigits=9)) to t=$(round(t+Δt,sigdigits=9)) (dt=$(round(Δt,sigdigits=9))):\n", bold=true, color=:blue) # color 111

        # Get forces and displacements from boundary conditions
        dom.shared_data.t = t + Δt
        UexN, FexN = get_bc_vals(dom, bcs, t+Δt) # get values at time t+Δt

        ΔUex = UexN - U
        ΔFex = FexN - F

        ΔUex[umap] .= 0.0
        ΔFex[pmap] .= 0.0

        #ΔUex = UexN - Uex
        #ΔFex = FexN - Fex

        R   .= ΔFex    # residual
        ΔUa .= 0.0
        ΔUi .= ΔUex    # essential values at iteration i

        # Newton Rapshon iterations
        residue   = 0.0
        converged = false
        maxfails  = 3    # maximum number of it. fails with residual change less than 90%
        nfails    = 0    # counter for iteration fails
        local G::SparseMatrixCSC{Float64,Int64}
        local RHS::Array{Float64,1}
        for it=1:maxits
            if it>1; ΔUi .= 0.0 end # essential values are applied only at first iteration
            lastres = residue # residue from last iteration

            # Try FE step
            verbose && print("    assembling... \r")
            G, RHS = mount_G_RHS(dom, ndofs, it==1 ? Δt : 0.0 ) # TODO: check for Δt after iter 1

            R .+= RHS

            # Solve
            verbose && print("    solving...   \r")
            hm_solve_step!(G, ΔUi, R, nu)   # Changes unknown positions in ΔUi and R

            # Update
            verbose && print("    updating... \r")

            # Restore the state to last converged increment
            for ip in ips; ip.data = deepcopy(ip.data0) end

            # Get internal forces and update data at integration points (update ΔFin)
            ΔFin .= 0.0
            ΔUt   = ΔUa + ΔUi
            for elem in dom.elems  
                elem_update!(elem, ΔUt, ΔFin, Δt)
            end

            residue = maximum(abs, (ΔFex-ΔFin)[umap] ) 

            # Update accumulated displacement
            ΔUa .+= ΔUi

            # Residual vector for next iteration
            R = ΔFex - ΔFin  #
            R[pmap] .= 0.0  # Zero at prescribed positions
            #@show maximum(abs, R[uw_map])
            #@show maximum(abs, R[uz_map])

            if verbose
                printstyled("    it $it  ", bold=true)
                @printf(" residue: %-10.4e\n", residue)
            else
                if !silent
                    printstyled("  increment $inc: ", bold=true, color=:blue)
                    printstyled("  it $it  ", bold=true)
                    @printf("residue: %-10.4e  \r", residue)
                end
            end

            if residue < tol;        converged = true ; break end
            if isnan(residue);       converged = false; break end
            if it > maxits;          converged = false; break end
            if residue > 0.9*lastres;  nfails += 1 end
            if nfails == maxfails;     converged = false; break end
        end

        if converged
            U .+= ΔUa
            F .+= ΔFin
            Uex .= UexN
            Fex .= FexN

            # Backup converged state at ips
            for ip in ips; ip.data0 = deepcopy(ip.data) end

            # Update nodal variables at dofs
            for (i,dof) in enumerate(dofs)
                dof.vals[dof.name]    += ΔUa[i]
                dof.vals[dof.natname] += ΔFin[i]
            end

            update_loggers!(dom) # Tracking nodes, ips, elements, etc.

            # Check for saving output file
            Tn = t + Δt
            if Tn+ttol>=T && saveincs
                iout += 1
                save(dom, "$(dom.filekey)-$iout.vtk", verbose=false)
                T = Tn - mod(Tn, dT) + dT
                silent || verbose || print("                                             \r")
                silent || printstyled("  $(dom.filekey)-$iout.vtk file written (Domain)\n", color=:green)
            end

            # Update time t and Δt
            inc += 1
            t   += Δt

            # Get new Δt
            if autoinc
                Δt = min(1.5*Δt, 1.0/nincs)
                Δt = round(Δt, digits=-ceil(Int, log10(Δt))+3)  # round to 3 significant digits
                Δt = min(Δt, 1.0-t)
            end
        else
            if autoinc
                silent || println("    increment failed.")
                #Δt *= 0.5
                #Δt = round(Δt, -ceil(Int, log10(Δt))+3)  # round to 3 significant digits
                Δt = round(0.5*Δt, sigdigits=3)
                if Δt < ttol
                    printstyled("solve!: solver did not converge\n", color=:red)
                    return false
                end
            else
                printstyled("solve!: solver did not converge\n", color=:red)
                return false
            end
        end
    end

    # time spent
    if !silent
        h, r = divrem(time()-tic, 3600)
        m, r = divrem(r, 60)
        println("  time spent: $(h)h $(m)m $(round(r,digits=3))s")
    end

    # Update number of used increments at domain
    dom.nincs += inc
    dom.nouts = iout
    dom.stage += 1

    return true

end
