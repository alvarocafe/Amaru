# This file is part of Amaru package. See copyright license in https://github.com/NumSoftware/Amaru

mutable struct MechJoint<:Mechanical
    id    ::Int
    shape ::ShapeType
    cell  ::Cell
    nodes ::Array{Node,1}
    ips   ::Array{Ip,1}
    tag   ::TagType
    mat   ::Material
    active::Bool
    linked_elems::Array{Element,1}
    shared_data ::SharedAnalysisData

    function MechJoint()
        return new()
    end
end

# Return the shape family that works with this element
matching_shape_family(::Type{MechJoint}) = JOINT_SHAPE

function elem_init(elem::MechJoint)

    # Get linked elements
    e1 = elem.linked_elems[1]
    e2 = elem.linked_elems[2]

    # Volume from first linked element
    V1 = 0.0
    C1 = elem_coords(e1)
    for ip in e1.ips
        dNdR = e1.shape.deriv(ip.R)
        J    = dNdR*C1
        detJ = det(J)
        V1  += detJ*ip.w
    end

    # Volume from second linked element
    V2 = 0.0
    C2 = elem_coords(e2)
    for ip in e2.ips
        dNdR = e2.shape.deriv(ip.R)
        J    = dNdR*C2
        detJ = det(J)
        V2  += detJ*ip.w
    end

    # Area of joint element
    A = 0.0
    C = elem_coords(elem)
    n = div(length(elem.nodes), 2)
    C = C[1:n, :]
    fshape = elem.shape.facet_shape
    for ip in elem.ips
        # compute shape Jacobian
        dNdR = fshape.deriv(ip.R)
        J    = dNdR*C
        detJ = norm2(J)
        A += detJ*ip.w
    end

    # Calculate and save h at joint element's integration points
    h = (V1+V2)/(2.0*A)
    for ip in elem.ips
        ip.data.h = h
    end

end

function matrixT(J::Matrix{Float64})
    if size(J,1)==2
        L2 = vec(J[1,:])
        L3 = vec(J[2,:])
        L1 = cross(L2, L3)  # L1 is normal to the first element face
        normalize!(L1)
        normalize!(L2)
        normalize!(L3)
        return collect([L1 L2 L3]') # collect is used to avoid Adjoint type
    else
        L2 = vec(J)
        L1 = [ L2[2], -L2[1] ] # It follows the anti-clockwise numbering of 2D elements: L1 should be normal to the first element face
        normalize!(L1)
        normalize!(L2)
        return collect([L1 L2]')
    end
end

function elem_stiffness(elem::MechJoint)
    ndim   = elem.shared_data.ndim
    th     = elem.shared_data.thickness
    nnodes = length(elem.nodes)
    hnodes = div(nnodes, 2) # half the number of total nodes
    fshape = elem.shape.facet_shape

    C = elem_coords(elem)[1:hnodes,:]
    B = zeros(ndim, nnodes*ndim)
    K = zeros(nnodes*ndim, nnodes*ndim)

    DB = zeros(ndim, nnodes*ndim)
    J  = zeros(ndim-1, ndim)
    NN = zeros(ndim, nnodes*ndim)

    for ip in elem.ips
        # compute shape Jacobian
        N    = fshape.func(ip.R)
        dNdR = fshape.deriv(ip.R)
        
        @gemm J = dNdR*C
        detJ = norm2(J)

        # compute B matrix
        T   = matrixT(J)
        NN .= 0.0  # NN = [ -N[]  N[] ]
        for i=1:hnodes
            for dof=1:ndim
                NN[dof, (i-1)*ndim + dof              ] = -N[i]
                NN[dof, hnodes*ndim + (i-1)*ndim + dof] =  N[i]
            end
        end

        @gemm B = T*NN

        # compute K
        coef = detJ*ip.w*th
        D    = mountD(elem.mat, ip.data)
        @gemm DB = D*B
        @gemm K += coef*B'*DB
    end

    keys = (:ux, :uy, :uz)[1:ndim]
    map  = [ node.dofdict[key].eq_id for node in elem.nodes for key in keys ]
    return K, map, map
end

function elem_update!(elem::MechJoint, U::Array{Float64,1}, F::Array{Float64,1}, Δt::Float64)
    ndim   = elem.shared_data.ndim
    th     = elem.shared_data.thickness
    nnodes = length(elem.nodes)
    hnodes = div(nnodes, 2) # half the number of total nodes
    fshape = elem.shape.facet_shape
    keys   = (:ux, :uy, :uz)[1:ndim]
    map    = [ node.dofdict[key].eq_id for node in elem.nodes for key in keys ]

    dU = U[map]
    dF = zeros(nnodes*ndim)
    C = elem_coords(elem)[1:hnodes,:]
    B = zeros(ndim, nnodes*ndim)

    DB = zeros(ndim, nnodes*ndim)
    J  = zeros(ndim-1, ndim)
    NN = zeros(ndim, nnodes*ndim)
    Δω = zeros(ndim)

    for ip in elem.ips
        # compute shape Jacobian
        N    = fshape.func(ip.R)
        dNdR = fshape.deriv(ip.R)
        @gemm J = dNdR*C
        detJ = norm2(J)

        # compute B matrix
        T = matrixT(J)
        NN[:,:] .= 0.0  # NN = [ -N[]  N[] ]
        for i=1:hnodes
            for dof=1:ndim
                NN[dof, (i-1)*ndim + dof              ] = -N[i]
                NN[dof, hnodes*ndim + (i-1)*ndim + dof] =  N[i]
            end
        end
        @gemm B = T*NN

        # internal force
        @gemv Δω = B*dU
        Δσ   = stress_update(elem.mat, ip.data, Δω)
        coef = detJ*ip.w*th
        @gemv dF += coef*B'*Δσ
    end

    F[map] += dF
end

function elem_extrapolated_node_vals(elem::MechJoint)
    nips = length(elem.ips) 

    E  = extrapolator(elem.shape.basic_shape, nips)
    Sn = E*[ ip.data.σ[1] for ip in elem.ips ]
    Wn = E*[ ip.data.w[1] for ip in elem.ips ]
    N  = [ Sn Wn; Sn Wn ]

    node_vals = OrderedDict{Symbol, Array{Float64,1}}()
    node_vals[:sn] = [ Sn; Sn ]
    node_vals[:wn] = [ Wn; Wn ]

    return node_vals
end
