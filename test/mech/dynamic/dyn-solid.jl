using Amaru

# Mesh generation

blocks = [
    Block3D( [0 0 0; 0.2 2.0 0.2], nx=2, ny=12, nz=2, cellshape=HEX8),
]

mesh = Mesh(blocks, verbose=true)
#tag!(mesh.points[1], 1)
tag!(mesh.cells    , 10) # all cells
#tag!(mesh.ips[:(x>0)], 1000)


# Domain definition

materials = [
    MaterialBind(10, ElasticSolid(E=30e6, nu=0.2, rho=24.0) ),
]

dom = Domain(mesh, materials)

# Finite element modeling

bcs = [
    NodeBC(:(y==0 && z==0), :(ux=0, uy=0, uz=0) ),
    NodeBC(:(y==2 && z==0), :(uz=0) ),
    NodeBC(:(y==1 && z==0.2), :(fz=-10) ),
]


dynsolve!(dom, bcs, time_span=0.1, nincs=50, verbose=true, filekey="dyn", nouts=50, autoinc=true, alpha=4.2038, beta=174.2803e-6)
#dynsolve!(dom, bcs, time_span=0.1, nincs=50, verbose=true, filekey="dyn", nouts=100, autoinc=true)
