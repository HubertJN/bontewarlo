!----------------------------------------------------------------------!
! Wang-Landau module                                                   !
!                                                                      !
! H. Naguszewski, Warwick                                         2024 !
!----------------------------------------------------------------------!

module wang_landau
  use initialise
  use kinds
  use shared_data
  use c_functions
  use random_site
  use metropolis
  use mpi

  implicit none

contains

  subroutine wl_main(setup, wl_setup, my_rank)
    ! Rank of this processor
    integer, intent(in) :: my_rank
    integer :: ierror, num_proc

    ! Input file data types
    type(run_params) :: setup
    type(wl_params) :: wl_setup

    ! Loop integers and error handling variable
    integer :: i, j, ierr

    ! Temperature and temperature steps
    real(real64) :: temp, beta

    ! wl variables and arrays
    integer :: bins, resets
    real(real64) :: bin_width, energy_to_ry, wl_f, wl_f_prev, tolerance, flatness_tolerance
    real(real64) :: target_energy, min_val, flatness, acceptance
    real(real64), allocatable :: bin_edges(:), wl_hist(:), wl_logdos(:)
    logical :: first_reset, hist_reset

    ! window variables
    integer, allocatable :: window_indices(:, :)
    integer :: num_windows, num_walkers

    ! mpi variables
    real(real64) :: start, end, time_max, time_min
    integer :: mpi_bins, mpi_start_idx, mpi_end_idx, bin_overlap, mpi_index, mpi_start_idx_buffer, mpi_end_idx_buffer
    integer, allocatable :: intervals(:,:)
    real(real64) :: scale_factor, scale_count, wl_logdos_min
    real(real64), allocatable :: mpi_bin_edges(:), mpi_wl_hist(:), wl_logdos_buffer(:), wl_logdos_write(:)

    ! Minimum value in array to be considered
    min_val = wl_setup%tolerance*1e-1_real64

    ! Get number of MPI processes
    call MPI_COMM_SIZE(MPI_COMM_WORLD, num_proc, ierror)

    ! Check if number of MPI processes is divisible by number of windows
    bins = wl_setup%bins
    num_windows = wl_setup%num_windows
    num_walkers = num_proc/num_windows
    if (MOD(num_proc, num_windows) /= 0) then
      if (my_rank == 0) then
        write (6, '(72("~"))')
        write (6, '(5("~"),x,"Error: Number of MPI processes not divisible by num_windows",x,6("~"))')
        write (6, '(72("~"))')
      end if
      call MPI_FINALIZE(ierror)
      call EXIT(0)
    end if

    ! Get start and end indices for energy windows
    allocate (window_indices(num_windows, 2))
    allocate(intervals(num_windows, 2))
    
    call divide_range(1, bins, num_windows, intervals)
    bin_overlap = wl_setup%bin_overlap
    do i = 1, num_windows
      window_indices(i, 1) = max((i - 1)*(bins/num_windows) + 1 - bin_overlap, 1)
      window_indices(i, 2) = min(i*(bins/num_windows) + bin_overlap, bins)
    end do

    mpi_index = my_rank/num_walkers + 1
    mpi_start_idx = window_indices(mpi_index, 1)
    mpi_end_idx = window_indices(mpi_index, 2)
    mpi_bins = mpi_end_idx - mpi_start_idx + 1

    ! Allocate arrays
    allocate (bin_edges(bins + 1))
    allocate (wl_hist(bins))
    allocate (wl_logdos(bins))
    allocate (wl_logdos_buffer(bins))

    ! MPI arrays
    allocate (mpi_bin_edges(mpi_bins + 1))
    allocate (mpi_wl_hist(mpi_bins))

    if (my_rank == 0) then
      allocate (wl_logdos_write(bins))
    end if

    call divide_range(1, bins, num_windows, intervals)
    call  exit()

    !  Set temperature in appropriate units for simulation
    temp = setup%T*k_b_in_Ry
    beta = 1.0_real64/temp

    ! Conversion meV/atom to Rydberg
    energy_to_ry = setup%n_atoms/(eV_to_Ry*1000)

    ! Create energy bins and set mpi bins
    j = 1
    bin_width = (wl_setup%energy_max - wl_setup%energy_min)/real(wl_setup%bins)*energy_to_ry
    do i = 1, bins + 1
      bin_edges(i) = wl_setup%energy_min*energy_to_ry + (i - 1)*bin_width
    end do
    do i = mpi_start_idx, mpi_end_idx + 1
      mpi_bin_edges(j) = bin_edges(i)
      j = j + 1
    end do

    ! Target energy for burn in
    target_energy = (mpi_bin_edges(1) + mpi_bin_edges(SIZE(mpi_bin_edges)))/2

    ! Initialize
    wl_hist = 0.0_real64; wl_logdos = 0.0_real64; wl_f = wl_setup%wl_f; wl_f_prev = wl_f
    flatness = 0.0_real64; first_reset = .False.; hist_reset = .True.
    mpi_wl_hist = 0.0_real64; wl_logdos_buffer = 0.0_real64

    ! Set up the lattice
    call initial_setup(setup, config)
    call lattice_shells(setup, shells, config)

    if (my_rank == 0) then
      write (6, '(/,72("-"),/)')
      write (6, '(24("-"),x,"Commencing Simulation!",x,24("-"),/)')
      print *, "Number of atoms", setup%n_atoms
    end if
    call comms_wait()

    !---------!
    ! Burn in !
    !---------!
    call wl_burn_in(setup, config, target_energy, MINVAL(mpi_bin_edges), MAXVAL(mpi_bin_edges))
    call comms_wait()
    if (my_rank == 0) then
      write (*, *)
      write (6, '(27("-"),x,"Burn-in complete",x,27("-"),/)')
      write (*, *)
    end if

    !--------------------!
    ! Main Wang-Landau   !
    !--------------------!
    resets = 1
    tolerance = wl_setup%tolerance
    flatness_tolerance = wl_setup%flatness
    do while (wl_f > tolerance)
      if (hist_reset .eqv. .True.) then
        ! Start timer
        start = mpi_wtime()
        hist_reset = .False.
      end if
      acceptance = run_wl_sweeps(setup, wl_setup, config, temp, bins, bin_edges, mpi_start_idx, mpi_end_idx, &
                                 mpi_wl_hist, wl_logdos, wl_f)

      flatness = minval(mpi_wl_hist)/(sum(mpi_wl_hist)/mpi_bins)

      if (first_reset .eqv. .False. .and. minval(mpi_wl_hist) > 10) then ! First reset after system had time to explore
        first_reset = .True.
        mpi_wl_hist = 0.0_real64
      else
        !Check if we're flatness_tolerance% flat
        if (flatness > flatness_tolerance .and. minval(mpi_wl_hist) > 10) then
          !Reset the histogram
          mpi_wl_hist = 0.0_real64
          hist_reset = .True.
          !Reduce f
          wl_f = wl_f*1/2
          ! End timer
          end = mpi_wtime()

          wl_logdos = wl_logdos - minval(wl_logdos, MASK=(wl_logdos > 0.0_real64))!wl_logdos_min
          wl_logdos = ABS(wl_logdos * merge(0, 1, wl_logdos < 0.0_real64))

          !Average DoS across walkers
          do i = 1, num_windows
            if (mpi_index == i) then
              if (my_rank /= (i - 1)*num_walkers) then
                call MPI_Send(wl_logdos, bins, MPI_DOUBLE_PRECISION, (i - 1)*num_walkers, i, MPI_COMM_WORLD, ierror)
              end if
              call comms_wait()
              if (my_rank == (i - 1)*num_walkers) then
                do j = 1, num_walkers - 1
                  call MPI_Recv(wl_logdos_buffer, bins, MPI_DOUBLE_PRECISION, (i - 1)*num_walkers + j, i, MPI_COMM_WORLD, &
                                MPI_STATUS_IGNORE, ierror)
                  wl_logdos = wl_logdos + wl_logdos_buffer
                end do
              end if
              call comms_wait()
              if (my_rank == (i - 1)*num_walkers) then
                wl_logdos = wl_logdos/num_walkers
                do j = 1, num_walkers - 1
                  call MPI_Send(wl_logdos, bins, MPI_DOUBLE_PRECISION, (i - 1)*num_walkers + j, i, MPI_COMM_WORLD, &
                                ierror)
                end do
              else
                call MPI_Recv(wl_logdos_buffer, bins, MPI_DOUBLE_PRECISION, (i - 1)*num_walkers, i, MPI_COMM_WORLD, &
                              MPI_STATUS_IGNORE, ierror)
                wl_logdos = wl_logdos_buffer
              end if
            end if
          end do
        end if
      end if

      if (hist_reset .eqv. .True.) then
        call MPI_REDUCE(end - start, time_min, 1, MPI_DOUBLE_PRECISION, MPI_MIN, 0, MPI_COMM_WORLD, ierror)
        call MPI_REDUCE(end - start, time_max, 1, MPI_DOUBLE_PRECISION, MPI_MAX, 0, MPI_COMM_WORLD, ierror)
        call comms_wait()

        if (my_rank == 0) then
          wl_logdos_write = wl_logdos
          write (6, '(a,i0,a,f6.2,a,f12.10,a,f8.2,a,f8.2,a)', advance='no') "Rank: ", my_rank, " Flatness: ", flatness*100, &
            "% W-L F: ", wl_f_prev, " Time min:", time_min, "s Time max:", time_max, "s"
          wl_f_prev = wl_f
          write (*, *)
        end if

        ! MPI send and recieve calls for combining window DoS
        do i = 2, num_windows
          if (my_rank == (i - 1)*num_walkers) then
            call MPI_Send(wl_logdos, bins, MPI_DOUBLE_PRECISION, 0, 0, MPI_COMM_WORLD, ierror)
            call MPI_Send(mpi_start_idx, 1, MPI_INT, 0, 1, MPI_COMM_WORLD, ierror)
            call MPI_Send(mpi_end_idx, 1, MPI_INT, 0, 2, MPI_COMM_WORLD, ierror)
          end if
          if (my_rank == 0) then
            call MPI_Recv(wl_logdos_buffer, bins, MPI_DOUBLE_PRECISION, (i - 1)*num_walkers, 0, MPI_COMM_WORLD, &
                          MPI_STATUS_IGNORE, ierror)
            call MPI_Recv(mpi_start_idx_buffer, 1, MPI_INT, (i - 1)*num_walkers, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE, ierror)
            call MPI_Recv(mpi_end_idx_buffer, 1, MPI_INT, (i - 1)*num_walkers, 2, MPI_COMM_WORLD, MPI_STATUS_IGNORE, ierror)
            scale_factor = 0.0_real64
            scale_count = 0.0_real64
            do j = 0, bin_overlap - 1
            if (wl_logdos_buffer(mpi_start_idx_buffer + j) > min_val .and. wl_logdos_write(mpi_start_idx_buffer + j) > min_val) then
              scale_factor = scale_factor + wl_logdos_write(mpi_start_idx_buffer + j) - wl_logdos_buffer(mpi_start_idx_buffer + j)
              scale_count = scale_count + 1.0_real64
            end if
            end do
            scale_factor = scale_factor/scale_count
            do j = mpi_start_idx_buffer + bin_overlap, mpi_end_idx_buffer
              wl_logdos_write(j) = wl_logdos_buffer(j) + scale_factor
            end do
          end if
        end do

        if (my_rank == 0) then
          ! Write output files
          call ncdf_writer_1d("wl_dos_bins.dat", ierr, bin_edges)
          call ncdf_writer_1d("wl_dos.dat", ierr, wl_logdos_write)
          call ncdf_writer_1d("wl_hist.dat", ierr, wl_hist)
        end if
      end if
    end do

    if (my_rank == 0) then
      write (*, *)
      write (6, '(25("-"),x,"Simulation Complete!",x,25("-"))')
    end if

  end subroutine wl_main

  integer function bin_index(energy, bin_edges, bins) result(index)
    integer, intent(in) :: bins
    real(real64), intent(in) :: energy
    real(real64), dimension(:), intent(in) :: bin_edges
    real(real64) :: bin_range

    bin_range = bin_edges(bins + 1) - bin_edges(1)
    index = int(((energy - bin_edges(1))/(bin_range))*real(bins)) + 1
  end function bin_index

  function run_wl_sweeps(setup, wl_setup, config, temp, bins, bin_edges, &
                         mpi_start_idx, mpi_end_idx, mpi_wl_hist, wl_logdos, wl_f) result(acceptance)
    integer(int16), dimension(:, :, :, :) :: config
    class(run_params), intent(in) :: setup
    class(wl_params), intent(in) :: wl_setup
    integer, intent(in) :: bins, mpi_start_idx, mpi_end_idx
    real(real64), dimension(:), intent(in) :: bin_edges
    real(real64), dimension(:), intent(inout) :: mpi_wl_hist, wl_logdos
    real(real64), intent(in) :: wl_f, temp

    integer, dimension(4) :: rdm1, rdm2
    real(real64) :: e_swapped, e_unswapped, delta_e, beta
    integer :: acceptance, i, ibin, jbin
    integer(int16) :: site1, site2

    ! Set inverse temp
    beta = 1.0_real64/temp

    ! Establish total energy before any moves
    e_unswapped = setup%full_energy(config)
    e_swapped = e_unswapped
    acceptance = 0.0_real64

    do i = 1, wl_setup%mc_sweeps*setup%n_atoms

      ! Make one MC trial
      ! Generate random numbers
      rdm1 = setup%rdm_site()
      rdm2 = setup%rdm_site()

      ! Get what is on those sites
      site1 = config(rdm1(1), rdm1(2), rdm1(3), rdm1(4))
      site2 = config(rdm2(1), rdm2(2), rdm2(3), rdm2(4))

      call pair_swap(config, rdm1, rdm2)

      ! Calculate energy if different species
      if (site1 /= site2) then
        e_swapped = setup%full_energy(config)
      end if

      ibin = bin_index(e_unswapped, bin_edges, bins)
      jbin = bin_index(e_swapped, bin_edges, bins)

      ! Only compute energy change if within limits where V is defined and within MPI region
      if (jbin > mpi_start_idx - 1 .and. jbin < mpi_end_idx + 1) then
        ! Add change in V into diff_energy
        delta_e = e_swapped - e_unswapped

        ! Accept or reject move
        if (genrand() .lt. exp((wl_logdos(ibin) - wl_logdos(jbin)))) then
          acceptance = acceptance + 1
          e_unswapped = e_swapped
        else
          call pair_swap(config, rdm1, rdm2)
          jbin = ibin
        end if
        mpi_wl_hist(jbin - mpi_start_idx + 1) = mpi_wl_hist(jbin - mpi_start_idx + 1) + 1.0_real64
        wl_logdos(jbin) = wl_logdos(jbin) + wl_f
      else
        ! reject and reset
        call pair_swap(config, rdm1, rdm2)
      end if
    end do

  end function run_wl_sweeps

  subroutine wl_burn_in(setup, config, target_energy, min_e, max_e)
    integer(int16), dimension(:, :, :, :) :: config
    class(run_params), intent(in) :: setup
    real(real64), intent(in) :: target_energy, min_e, max_e

    integer, dimension(4) :: rdm1, rdm2
    real(real64) :: e_swapped, e_unswapped, delta_e
    integer(int16) :: site1, site2

    ! Establish total energy before any moves
    e_unswapped = setup%full_energy(config)

    do while (.True.)
      if (e_unswapped > min_e .and. e_unswapped < max_e) then
        exit
      end if
      ! Make one MC trial
      ! Generate random numbers
      rdm1 = setup%rdm_site()
      rdm2 = setup%rdm_site()

      ! Get what is on those sites
      site1 = config(rdm1(1), rdm1(2), rdm1(3), rdm1(4))
      site2 = config(rdm2(1), rdm2(2), rdm2(3), rdm2(4))

      if (site1 /= site2) then
        call pair_swap(config, rdm1, rdm2)
        e_swapped = setup%full_energy(config)

        delta_e = e_swapped - e_unswapped

        ! Accept or reject move
        if (e_swapped > target_energy .and. delta_e < 0) then
          e_unswapped = e_swapped
        else if (e_swapped < target_energy .and. delta_e > 0) then
          e_unswapped = e_swapped
        else if (genrand() .lt. 0.001_real64) then ! to prevent getting stuck in local minimum
          e_unswapped = e_swapped
        else
          call pair_swap(config, rdm1, rdm2)
        end if
      end if
    end do
  end subroutine wl_burn_in

  subroutine divide_range(start, finish, num_intervals, intervals)
    integer, intent(in) :: num_intervals
    integer, intent(in) :: start, finish
    integer, intent(out) :: intervals(num_intervals, 2)
    real(real64) :: factor, index
    integer :: i

    intervals(1,1) = start
    intervals(num_intervals,2) = finish

    factor = real((finish-1))/real(((num_intervals+1)**2-1))

    print*, FLOOR(factor*(1**2-1)+1)

    do i = 2, num_intervals
      print*, FLOOR(factor*(i**2-1)+1)
      index = FLOOR(factor*(i**2-1)+1)
      print*, index
      intervals(i-1,2) = index
      intervals(i,1) = index + 1
    end do
    print*, intervals(:,1)
    print*, intervals(:,2)
  end subroutine divide_range

end module wang_landau
