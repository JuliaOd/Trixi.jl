function rhs!(du, u, t,
              mesh::CurvedMesh{2}, equations,
              initial_condition, boundary_conditions, source_terms,
              dg::DG, cache)
  # Reset du
  @timed timer() "reset ∂u/∂t" du .= zero(eltype(du))

  # Calculate volume integral
  @timed timer() "volume integral" calc_volume_integral!(
    du, u, mesh,
    have_nonconservative_terms(equations), equations,
    dg.volume_integral, dg, cache)

  # Calculate interface fluxes
  @timed timer() "interface flux" calc_interface_flux!(
    cache, u, mesh, equations, dg)

  # Calculate boundary fluxes
  @timed timer() "boundary flux" calc_boundary_flux!(
    cache, u, t, boundary_conditions, mesh, equations, dg)

  # Calculate surface integrals
  @timed timer() "surface integral" calc_surface_integral!(
    du, mesh, equations, dg, cache)

  # Apply Jacobian from mapping to reference element
  @timed timer() "Jacobian" apply_jacobian!(
    du, mesh, equations, dg, cache)

  # Calculate source terms
  @timed timer() "source terms" calc_sources!(
    du, u, t, source_terms, equations, dg, cache)

  return nothing
end


function calc_volume_integral!(du, u,
                               mesh::Union{CurvedMesh{2}, UnstructuredQuadMesh},
                               nonconservative_terms::Val{false}, equations,
                               volume_integral::VolumeIntegralWeakForm,
                               dg::DGSEM, cache)
  @unpack derivative_dhat = dg.basis
  @unpack contravariant_vectors = cache.elements

  @threaded for element in eachelement(dg, cache)
    for j in eachnode(dg), i in eachnode(dg)
      u_node = get_node_vars(u, equations, dg, i, j, element)

      flux1 = flux(u_node, 1, equations)
      flux2 = flux(u_node, 2, equations)

      # Compute the contravariant flux by taking the scalar product of the
      # first contravariant vector Ja^1 and the flux vector
      Ja11, Ja12 = get_contravariant_vector(1, contravariant_vectors, i, j, element)
      contravariant_flux1 = Ja11 * flux1 + Ja12 * flux2

      for ii in eachnode(dg)
        integral_contribution = derivative_dhat[ii, i] * contravariant_flux1
        add_to_node_vars!(du, integral_contribution, equations, dg, ii, j, element)
      end

      # Compute the contravariant flux by taking the scalar product of the
      # second contravariant vector Ja^2 and the flux vector
      Ja21, Ja22 = get_contravariant_vector(2, contravariant_vectors, i, j, element)
      contravariant_flux2 = Ja21 * flux1 + Ja22 * flux2

      for jj in eachnode(dg)
        integral_contribution = derivative_dhat[jj, j] * contravariant_flux2
        add_to_node_vars!(du, integral_contribution, equations, dg, i, jj, element)
      end
    end
  end

  return nothing
end


function calc_interface_flux!(cache, u,
                              mesh::CurvedMesh{2},
                              equations, dg::DG)
  @unpack elements = cache

  @threaded for element in eachelement(dg, cache)
    # Interfaces in negative directions
    # Faster version of "for orientation in (1, 2)"

    # Interfaces in x-direction (`orientation` = 1)
    calc_interface_flux!(elements.surface_flux_values,
                         elements.left_neighbors[1, element],
                         element, 1, u, mesh, equations, dg, cache)

    # Interfaces in y-direction (`orientation` = 2)
    calc_interface_flux!(elements.surface_flux_values,
                         elements.left_neighbors[2, element],
                         element, 2, u, mesh, equations, dg, cache)
  end

  return nothing
end


@inline function calc_interface_flux!(surface_flux_values, left_element, right_element,
                                      orientation, u,
                                      mesh::CurvedMesh{2}, equations,
                                      dg::DG, cache)
  # This is slow for LSA, but for some reason faster for Euler (see #519)
  if left_element <= 0 # left_element = 0 at boundaries
    return nothing
  end

  @unpack surface_flux = dg
  @unpack contravariant_vectors, inverse_jacobian = cache.elements

  right_direction = 2 * orientation
  left_direction = right_direction - 1

  for i in eachnode(dg)
    if orientation == 1
      u_ll = get_node_vars(u, equations, dg, nnodes(dg), i, left_element)
      u_rr = get_node_vars(u, equations, dg, 1,          i, right_element)

      # If the mapping is orientation-reversing, the contravariant vectors' orientation 
      # is reversed as well. The normal vector must be oriented in the direction 
      # from `left_element` to `right_element`, or the numerical flux will be computed
      # incorrectly (downwind direction).
      sign_jacobian = sign(inverse_jacobian[1, i, right_element])

      # First contravariant vector Ja^1 as SVector
      normal_vector = sign_jacobian * get_contravariant_vector(1, contravariant_vectors,
                                                               1, i, right_element)
    else # orientation == 2
      u_ll = get_node_vars(u, equations, dg, i, nnodes(dg), left_element)
      u_rr = get_node_vars(u, equations, dg, i, 1,          right_element)

      # See above
      sign_jacobian = sign(inverse_jacobian[i, 1, right_element])

      # Second contravariant vector Ja^2 as SVector
      normal_vector = sign_jacobian * get_contravariant_vector(2, contravariant_vectors,
                                                               i, 1, right_element)
    end

    # If the mapping is orientation-reversing, the normal vector will be reversed (see above).
    # However, the flux now has the wrong sign, since we need the physical flux in normal direction.
    flux = sign_jacobian * surface_flux(u_ll, u_rr, normal_vector, equations)

    for v in eachvariable(equations)
      surface_flux_values[v, i, right_direction, left_element] = flux[v]
      surface_flux_values[v, i, left_direction, right_element] = flux[v]
    end
  end

  return nothing
end


# TODO: Taal dimension agnostic
function calc_boundary_flux!(cache, u, t, boundary_condition::BoundaryConditionPeriodic,
                             mesh::CurvedMesh{2}, equations, dg::DG)
  @assert isperiodic(mesh)
end


function calc_boundary_flux!(cache, u, t, boundary_condition,
                             mesh::CurvedMesh{2}, equations, dg::DG)
  calc_boundary_flux!(cache, u, t,
                      (boundary_condition, boundary_condition,
                       boundary_condition, boundary_condition),
                      mesh, equations, dg)
end


function calc_boundary_flux!(cache, u, t, boundary_conditions::Union{NamedTuple,Tuple},
                             mesh::CurvedMesh{2}, equations, dg::DG)
  @unpack surface_flux = dg
  @unpack surface_flux_values = cache.elements
  linear_indices = LinearIndices(size(mesh))

  for cell_y in axes(mesh, 2)
    # Negative x-direction
    direction = 1
    element = linear_indices[begin, cell_y]

    for j in eachnode(dg)
      calc_boundary_flux_by_direction!(surface_flux_values, u, t, 1,
                                       boundary_conditions[direction],
                                       mesh, equations, dg, cache,
                                       direction, (1, j), (j,), element)
    end

    # Positive x-direction
    direction = 2
    element = linear_indices[end, cell_y]

    for j in eachnode(dg)
      calc_boundary_flux_by_direction!(surface_flux_values, u, t, 1,
                                       boundary_conditions[direction],
                                       mesh, equations, dg, cache,
                                       direction, (nnodes(dg), j), (j,), element)
    end
  end

  for cell_x in axes(mesh, 1)
    # Negative y-direction
    direction = 3
    element = linear_indices[cell_x, begin]

    for i in eachnode(dg)
      calc_boundary_flux_by_direction!(surface_flux_values, u, t, 2,
                                       boundary_conditions[direction],
                                       mesh, equations, dg, cache,
                                       direction, (i, 1), (i,), element)
    end

    # Positive y-direction
    direction = 4
    element = linear_indices[cell_x, end]

    for i in eachnode(dg)
      calc_boundary_flux_by_direction!(surface_flux_values, u, t, 2,
                                       boundary_conditions[direction],
                                       mesh, equations, dg, cache,
                                       direction, (i, nnodes(dg)), (i,), element)
    end
  end
end


function apply_jacobian!(du,
                         mesh::Union{CurvedMesh{2}, UnstructuredQuadMesh},
                         equations, dg::DG, cache)
  @unpack inverse_jacobian = cache.elements

  @threaded for element in eachelement(dg, cache)
    for j in eachnode(dg), i in eachnode(dg)
      factor = -inverse_jacobian[i, j, element]

      for v in eachvariable(equations)
        du[v, i, j, element] *= factor
      end
    end
  end

  return nothing
end
