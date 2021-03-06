! DART software - Copyright 2004 - 2011 UCAR. This open source software is
! provided by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download

module assim_tools_mod

! <next few lines under version control, do not edit>
! $URL: https://proxy.subversion.ucar.edu/DAReS/DART/releases/Kodiak/assim_tools/assim_tools_mod.f90 $
! $Id: assim_tools_mod.f90 5577 2012-02-29 18:50:54Z nancy $
! $Revision: 5577 $
! $Date: 2012-02-29 12:50:54 -0600 (Wed, 29 Feb 2012) $
 
! A variety of operations required by assimilation.

use      types_mod,       only : r8, digits12, PI, missing_r8
use  utilities_mod,       only : file_exist, get_unit, check_namelist_read, do_output,    &
                                 find_namelist_in_file, register_module, error_handler,   &
                                 E_ERR, E_MSG, nmlfileunit, do_nml_file, do_nml_term,     &
                                 open_file, close_file, timestamp
use       sort_mod,       only : index_sort 
use random_seq_mod,       only : random_seq_type, random_gaussian, init_random_seq,       &
                                 random_uniform

use obs_sequence_mod,     only : obs_sequence_type, obs_type, get_num_copies, get_num_qc, &
                                 init_obs, get_obs_from_key, get_obs_def, get_obs_values, &
                                 destroy_obs
   
use          obs_def_mod, only : obs_def_type, get_obs_def_location, get_obs_def_time,    &
                                 get_obs_def_error_variance, get_obs_kind

use         obs_kind_mod, only : get_num_obs_kinds, get_obs_kind_index


use       cov_cutoff_mod, only : comp_cov_factor

use       reg_factor_mod, only : comp_reg_factor

use         location_mod, only : location_type, get_close_type, get_close_obs_destroy,    &
                                 operator(==), set_location_missing, write_location,      &
                                 LocationDims, vert_is_surface, has_vertical_localization

use ensemble_manager_mod, only : ensemble_type, get_my_num_vars, get_my_vars,             & 
                                 compute_copy_mean_var, get_var_owner_index

use mpi_utilities_mod,    only : my_task_id, broadcast_send, broadcast_recv,              & 
                                 sum_across_tasks

use adaptive_inflate_mod, only : do_obs_inflate,  do_single_ss_inflate,                   &
                                 do_varying_ss_inflate, get_inflate, set_inflate,         &
                                 get_sd, set_sd, update_inflation,                        &
                                 inflate_ens, adaptive_inflate_type,                      &
                                 deterministic_inflate, solve_quadratic

use time_manager_mod,     only : time_type, get_time

use assim_model_mod,      only : get_state_meta_data, get_close_maxdist_init,             &
                                 get_close_obs_init, get_close_obs

! GSR add routine to check if kind is assimilated ob type
use obs_kind_mod,         only : assimilate_this_obs_kind

implicit none
private

public :: filter_assim, set_assim_tools_trace

! Indicates if module initialization subroutine has been called yet
logical :: module_initialized = .false.

integer :: print_timestamps    = 0
integer :: print_trace_details = 0

! True if random sequence needs to be initialized
logical                :: first_inc_ran_call = .true.
type (random_seq_type) :: inc_ran_seq

integer                :: num_types = 0
real(r8), allocatable  :: cutoff_list(:)
logical                :: has_special_cutoffs
character(len = 129)   :: errstring

! Need to read in table for off-line based sampling correction and store it
logical                :: first_get_correction = .true.
real(r8)               :: exp_true_correl(200), alpha(200)                                                                      
! version controlled file description for error handling, do not edit
character(len=128), parameter :: &
   source   = "$URL: https://proxy.subversion.ucar.edu/DAReS/DART/releases/Kodiak/assim_tools/assim_tools_mod.f90 $", &
   revision = "$Revision: 5577 $", &
   revdate  = "$Date: 2012-02-29 12:50:54 -0600 (Wed, 29 Feb 2012) $"

!============================================================================

!---- namelist with default values

! Filter kind selects type of observation space filter
!      1 = EAKF filter
!      2 = ENKF
!      3 = Kernel filter
!      4 = particle filter
!      5 = random draw from posterior
!      6 = deterministic draw from posterior with fixed kurtosis
!      8 = Rank Histogram Filter (see Anderson 2011)
!
!  special_localization_obs_types -> Special treatment for the specified observation types
!  special_localization_cutoffs   -> Different cutoff value for each specified obs type
!
integer  :: filter_kind                     = 1
real(r8) :: cutoff                          = 0.2_r8
logical  :: sort_obs_inc                    = .false.
logical  :: spread_restoration              = .false.
logical  :: sampling_error_correction       = .false.
integer  :: adaptive_localization_threshold = -1
real(r8) :: adaptive_cutoff_floor           = 0.0_r8
integer  :: print_every_nth_obs             = 0

! since this is in the namelist, it has to have a fixed size.
integer, parameter   :: MAX_ITEMS = 300
character(len = 129) :: special_localization_obs_types(MAX_ITEMS)
real(r8)             :: special_localization_cutoffs(MAX_ITEMS)

logical              :: output_localization_diagnostics = .false.
character(len = 129) :: localization_diagnostics_file = "localization_diagnostics"

! Following only relevant for filter_kind = 8
logical  :: rectangular_quadrature          = .true.
logical  :: gaussian_likelihood_tails       = .false.

! Not in the namelist; this var disables the experimental
! linear and spherical case code in the adaptive localization 
! sections.  to try out the alternatives, set this to .false.
logical  :: only_area_adapt  = .true.

namelist / assim_tools_nml / filter_kind, cutoff, sort_obs_inc, &
   spread_restoration, sampling_error_correction,                          & 
   adaptive_localization_threshold, adaptive_cutoff_floor,                 &
   print_every_nth_obs, rectangular_quadrature, gaussian_likelihood_tails, &
   output_localization_diagnostics, localization_diagnostics_file,         &
   special_localization_obs_types, special_localization_cutoffs

!============================================================================

contains

!-------------------------------------------------------------

subroutine assim_tools_init()

integer :: iunit, io, i, j
integer :: num_special_cutoff, type_index

call register_module(source, revision, revdate)

! give these guys initial values at runtime *before* we read
! in the namelist.  this is to help detect how many items are
! actually given in the namelist.
special_localization_obs_types(:)  = 'null'
special_localization_cutoffs(:)    =  missing_r8 

! Read the namelist entry
call find_namelist_in_file("input.nml", "assim_tools_nml", iunit)
read(iunit, nml = assim_tools_nml, iostat = io)
call check_namelist_read(iunit, io, "assim_tools_nml")

! Write the namelist values to the log file
if (do_nml_file()) write(nmlfileunit, nml=assim_tools_nml)
if (do_nml_term()) write(     *     , nml=assim_tools_nml)

! FOR NOW, can only do spread restoration with filter option 1 (need to extend this)
if(spread_restoration .and. .not. filter_kind == 1) then
   write(errstring, *) 'cannot combine spread_restoration and filter_kind ', filter_kind
   call error_handler(E_ERR,'assim_tools_init:', errstring, source, revision, revdate)
endif

! allocate a list in all cases - even the ones where there is only
! a single cutoff value.  note that in spite of the name these
! are specific types (e.g. RADIOSONDE_TEMPERATURE, AIRCRAFT_TEMPERATURE)
! because that's what get_close() is passed.
num_types = get_num_obs_kinds()
allocate(cutoff_list(num_types)) 
cutoff_list(:) = cutoff
has_special_cutoffs = .false.

! Go through special-treatment observation kinds, if any.
num_special_cutoff = 0
j = 0
do i = 1, MAX_ITEMS
   if(special_localization_obs_types(i) == 'null') exit
   if(special_localization_cutoffs(i) == MISSING_R8) then
      write(errstring, *) 'cutoff value', i, ' is uninitialized.'
      call error_handler(E_ERR,'assim_tools_init:', &
                         'special cutoff namelist for types and distances do not match', &
                         source, revision, revdate, &
                         text2='kind = '//trim(special_localization_obs_types(i)), &
                         text3=trim(errstring))
   endif
   j = j + 1
enddo
num_special_cutoff = j

if (num_special_cutoff > 0) has_special_cutoffs = .true.

do i = 1, num_special_cutoff
   type_index = get_obs_kind_index(special_localization_obs_types(i))
   if (type_index < 0) then
      write(errstring, *) 'unrecognized TYPE_ in the special localization namelist:'
      call error_handler(E_ERR,'assim_tools_init:', errstring, source, revision, revdate, &
                         text2=trim(special_localization_obs_types(i)))
   endif
   cutoff_list(type_index) = special_localization_cutoffs(i)
end do

if (do_output()) then
   write(errstring, '(A,F18.6)') 'The cutoff namelist value is ', cutoff
   call error_handler(E_MSG,'assim_tools_init:', errstring)
   write(errstring, '(A)') 'cutoff is the localization half-width parameter,'
   call error_handler(E_MSG,'assim_tools_init:', errstring)
   write(errstring, '(A,F18.6)') 'so the effective localization radius is ', cutoff*2.0_r8
   call error_handler(E_MSG,'assim_tools_init:', errstring)

   if (has_special_cutoffs) then
      call error_handler(E_MSG, '', '')
      call error_handler(E_MSG,'assim_tools_init:','Observations with special localization treatment:')
      call error_handler(E_MSG,'assim_tools_init:','(type name, specified cutoff distance, effective localization radius)') 
   
      do i = 1, num_special_cutoff
         write(errstring, '(A32,F18.6,F18.6)') special_localization_obs_types(i), &
               special_localization_cutoffs(i), special_localization_cutoffs(i)*2.0_r8                     
         call error_handler(E_MSG,'assim_tools_init:', errstring)
      end do
      call error_handler(E_MSG,'assim_tools_init:','all other observation types will use the default cutoff distance')
      call error_handler(E_MSG, '', '')
   endif


   if(adaptive_localization_threshold > 0) then
      write(errstring, '(A,I10,A)') 'Using adaptive localization, threshold ', &
         adaptive_localization_threshold, ' obs'
      call error_handler(E_MSG,'assim_tools_init:', errstring)
      if(adaptive_cutoff_floor > 0.0_r8) then
         write(errstring, '(A,F18.6)') 'Minimum cutoff will not go below ', &
            adaptive_cutoff_floor
         call error_handler(E_MSG,'assim_tools_init:', 'Using adaptive localization cutoff floor.', &
                            text2=errstring)
      endif
   endif

   if(output_localization_diagnostics) then
      call error_handler(E_MSG,'assim_tools_init:', 'Writing localization diagnostics to file:')
      call error_handler(E_MSG,'assim_tools_init:', trim(localization_diagnostics_file))
   endif

   if(sampling_error_correction) then
      call error_handler(E_MSG,'assim_tools_init:', 'Using Sampling Error Correction')
   endif
endif

end subroutine assim_tools_init

!-------------------------------------------------------------

subroutine filter_assim(ens_handle, obs_ens_handle, obs_seq, keys,           &
   ens_size, num_groups, obs_val_index, inflate, ENS_MEAN_COPY, ENS_SD_COPY, &
   ENS_INF_COPY, ENS_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY,          &
   OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END, OBS_PRIOR_VAR_START,            &
   OBS_PRIOR_VAR_END, inflate_only)

type(ensemble_type),         intent(inout) :: ens_handle, obs_ens_handle
type(obs_sequence_type),     intent(in)    :: obs_seq
integer,                     intent(in)    :: keys(:)
integer,                     intent(in)    :: ens_size, num_groups, obs_val_index
type(adaptive_inflate_type), intent(inout) :: inflate
integer,                     intent(in)    :: ENS_MEAN_COPY, ENS_SD_COPY, ENS_INF_COPY
integer,                     intent(in)    :: ENS_INF_SD_COPY
integer,                     intent(in)    :: OBS_KEY_COPY, OBS_GLOBAL_QC_COPY
integer,                     intent(in)    :: OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END
integer,                     intent(in)    :: OBS_PRIOR_VAR_START, OBS_PRIOR_VAR_END
logical,                     intent(in)    :: inflate_only

real(r8) :: obs_prior(ens_size), obs_inc(ens_size), increment(ens_size)
real(r8) :: reg_factor
real(r8) :: net_a(num_groups), reg_coef(num_groups), correl(num_groups)
real(r8) :: cov_factor, obs(1), obs_err_var, my_inflate, my_inflate_sd
real(r8) :: varying_ss_inflate, varying_ss_inflate_sd
real(r8) :: ss_inflate_base, obs_qc, cutoff_rev, cutoff_orig
real(r8) :: gamma, ens_obs_mean, ens_obs_var, ens_var_deflate
real(r8) :: r_mean, r_var
real(r8) :: orig_obs_prior_mean(num_groups), orig_obs_prior_var(num_groups)
real(r8) :: obs_prior_mean(num_groups), obs_prior_var(num_groups)
real(r8) :: close_obs_dist(obs_ens_handle%my_num_vars)
real(r8) :: close_state_dist(ens_handle%my_num_vars)
real(r8) :: last_close_obs_dist(obs_ens_handle%my_num_vars)
real(r8) :: last_close_state_dist(ens_handle%my_num_vars)

integer  :: my_num_obs, i, j, ispc, owner, owners_index, my_num_state
integer  :: my_obs(obs_ens_handle%my_num_vars), my_state(ens_handle%my_num_vars)
integer  :: this_obs_key, obs_mean_index, obs_var_index
integer  :: grp_beg(num_groups), grp_end(num_groups), grp_size, grp_bot, grp_top, group
integer  :: close_obs_ind(obs_ens_handle%my_num_vars)
integer  :: close_state_ind(ens_handle%my_num_vars)
integer  :: last_close_obs_ind(obs_ens_handle%my_num_vars)
integer  :: last_close_state_ind(ens_handle%my_num_vars)
integer  :: num_close_obs, obs_index, num_close_states, state_index
integer  :: total_num_close_obs, last_num_close_obs, last_num_close_states
integer  :: base_obs_kind, my_obs_kind(obs_ens_handle%my_num_vars)
integer  :: my_state_kind(ens_handle%my_num_vars), nth_obs
integer  :: num_close_obs_buffered, num_close_states_buffered
integer  :: num_close_obs_calls_made, num_close_states_calls_made
! GSR add new count for only the 'assimilate' type close obs in the tile
integer  :: localization_unit, secs, days, rev_num_close_obs
character(len = 102)  :: base_loc_text   ! longest location formatting possible

type(location_type)  :: my_obs_loc(obs_ens_handle%my_num_vars)
type(location_type)  :: base_obs_loc, last_base_obs_loc, last_base_states_loc
type(location_type)  :: my_state_loc(ens_handle%my_num_vars)
type(get_close_type) :: gc_obs, gc_state
type(obs_type)       :: observation
type(obs_def_type)   :: obs_def
type(time_type)      :: obs_time, this_obs_time

! for performance, local copies 
logical :: local_single_ss_inflate
logical :: local_varying_ss_inflate
logical :: local_obs_inflate
logical :: get_close_buffering

! Initialize assim_tools_module if needed
if(.not. module_initialized) then
   call assim_tools_init
   module_initialized = .true.
endif

!GSR open the dignostics file
if(output_localization_diagnostics .and. my_task_id() == 0) then
  localization_unit = open_file(localization_diagnostics_file, action = 'append')
endif

! turn on and off the close buffering
get_close_buffering = .true.

! For performance, make local copies of these settings which
! are really in the inflate derived type.
local_single_ss_inflate  = do_single_ss_inflate(inflate)
local_varying_ss_inflate = do_varying_ss_inflate(inflate)
local_obs_inflate        = do_obs_inflate(inflate)

! Default to printing nothing
nth_obs = -1

! Divide ensemble into num_groups groups
grp_size = ens_size / num_groups
do group = 1, num_groups
   grp_beg(group) = (group - 1) * grp_size + 1
   grp_end(group) = grp_beg(group) + grp_size - 1
enddo

! Put initial value of state space inflation in copy normally used for SD
! This is to avoid weird storage footprint in filter
ens_handle%copies(ENS_SD_COPY, :) = ens_handle%copies(ENS_INF_COPY, :)

! For single state or obs space inflation, the inflation is like a token
! Gets passed from the processor with a given obs on to the next
if(local_single_ss_inflate) then
   my_inflate    = ens_handle%copies(ENS_INF_COPY,    1)
   my_inflate_sd = ens_handle%copies(ENS_INF_SD_COPY, 1)
end if

! For obs space inflation, single value comes from storage in adaptive_inflate_mod
if(local_obs_inflate) then
   my_inflate    = get_inflate(inflate)
   my_inflate_sd = get_sd(inflate)
endif

! Get info on my number and indices for obs
my_num_obs = get_my_num_vars(obs_ens_handle)
call get_my_vars(obs_ens_handle, my_obs)

! Construct an observation temporary
call init_obs(observation, get_num_copies(obs_seq), get_num_qc(obs_seq))

! Get the locations for all of my observations 
Get_Obs_Locations: do i = 1, obs_ens_handle%my_num_vars
   this_obs_key = obs_ens_handle%copies(OBS_KEY_COPY, i)
   call get_obs_from_key(obs_seq, this_obs_key, observation)
   call get_obs_def(observation, obs_def)
   my_obs_loc(i)  = get_obs_def_location(obs_def)
   my_obs_kind(i) = get_obs_kind(obs_def)
   ! Need the time for regression diagnostics potentially; get from first observation
   if(i == 1) obs_time = get_obs_def_time(obs_def)
end do Get_Obs_Locations

! Get info on my number and indices for state
my_num_state = get_my_num_vars(ens_handle)
call get_my_vars(ens_handle, my_state)

! Get the location and kind of all my state variables
do i = 1, ens_handle%my_num_vars
   call get_state_meta_data(my_state(i), my_state_loc(i), my_state_kind(i))
end do

! PAR: MIGHT BE BETTER TO HAVE ONE PE DEDICATED TO COMPUTING 
! INCREMENTS. OWNING PE WOULD SHIP IT'S PRIOR TO THIS ONE
! BEFORE EACH INCREMENT.

! Get mean and variance of each group's observation priors for adaptive inflation
! Important that these be from before any observations have been used
if(local_varying_ss_inflate .or. local_single_ss_inflate) then
   do group = 1, num_groups
      obs_mean_index = OBS_PRIOR_MEAN_START + group - 1
      obs_var_index  = OBS_PRIOR_VAR_START  + group - 1
         call compute_copy_mean_var(obs_ens_handle, grp_beg(group), grp_end(group), &
           obs_mean_index, obs_var_index) 
   end do
endif

! the get_close_maxdist_init() call is quick - it just allocates space.
! it's the get_close_obs_init() call that takes time.  correct me if
! i'm confused but the obs list is different each time, so it can't 
! be skipped.  i guess the state space obs_init is redundant and we 
! could just do it once the first time - but knowing when to 
! deallocate the space is a question.

! NOTE THESE COULD ONLY BE DONE ONCE PER RUN!!! FIGURE THIS OUT.
! The computations in the two get_close_maxdist_init are redundant

! Initialize the method for getting state variables close to a given ob on my process
if (has_special_cutoffs) then
! RAS
   call get_close_maxdist_init(gc_state, 2.0_r8*cutoff, 2.0_r8*cutoff_list, special_localization_obs_types)
   !call get_close_maxdist_init(gc_state, 2.0_r8*cutoff, 2.0_r8*cutoff_list)
! RAS
else
   call get_close_maxdist_init(gc_state, 2.0_r8*cutoff)
endif
call get_close_obs_init(gc_state, my_num_state, my_state_loc)

! Initialize the method for getting obs close to a given ob on my process
if (has_special_cutoffs) then
! RAS
   call get_close_maxdist_init(gc_obs, 2.0_r8*cutoff, 2.0_r8*cutoff_list, special_localization_obs_types)
   !call get_close_maxdist_init(gc_obs, 2.0_r8*cutoff, 2.0_r8*cutoff_list)
! RAS
else
   call get_close_maxdist_init(gc_obs, 2.0_r8*cutoff)
endif
call get_close_obs_init(gc_obs, my_num_obs, my_obs_loc)

if (get_close_buffering) then
   ! Initialize last obs and state get_close lookups, to take advantage below 
   ! of sequential observations at the same location (e.g. U,V, possibly T,Q)
   ! (this is getting long enough it probably should go into a subroutine. nsc.)
   last_base_obs_loc           = set_location_missing()
   last_base_states_loc        = set_location_missing()
   last_num_close_obs          = -1
   last_num_close_states       = -1
   last_close_obs_ind(:)       = -1
   last_close_state_ind(:)     = -1
   last_close_obs_dist(:)      = 888888.0_r8   ! something big, not small
   last_close_state_dist(:)    = 888888.0_r8   ! ditto
   num_close_obs_buffered      = 0
   num_close_states_buffered   = 0
   num_close_obs_calls_made    = 0
   num_close_states_calls_made = 0
endif

! Loop through all the (global) observations sequentially
SEQUENTIAL_OBS: do i = 1, obs_ens_handle%num_vars

   ! Some compilers do not like mod by 0, so test first.
   if (print_every_nth_obs > 0) nth_obs = mod(i, print_every_nth_obs)

   ! If requested, print out a message every Nth observation
   ! to indicate progress is being made and to allow estimates 
   ! of how long the assim will take.
   if (nth_obs == 0) then
      write(errstring, '(A,1x,I8,1x,A,I8)') 'Processing observation ', i, &
                                         ' of ', obs_ens_handle%num_vars
      if (print_timestamps == 0) then
         call error_handler(E_MSG,'filter_assim',errstring)
      else
         call timestamp(trim(errstring), pos="brief")
      endif
   endif

   ! Every pe has information about obs sequence
   call get_obs_from_key(obs_seq, keys(i), observation)
   call get_obs_def(observation, obs_def)
   base_obs_loc = get_obs_def_location(obs_def)
   obs_err_var = get_obs_def_error_variance(obs_def)
   base_obs_kind = get_obs_kind(obs_def)
   ! Get the value of the observation
   call get_obs_values(observation, obs, obs_val_index)

   ! Find out who has this observation and where it is
   call get_var_owner_index(i, owner, owners_index)

   ! Following block is done only by the owner of this observation
   !-----------------------------------------------------------------------
   if(my_task_id() == owner) then
      obs_qc = obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, owners_index)
      ! Only value of 0 for DART QC field should be assimilated
      IF_QC_IS_OKAY: if(nint(obs_qc) ==0) then
         obs_prior = obs_ens_handle%copies(1:ens_size, owners_index)

         ! Compute the prior mean and variance for this observation
         orig_obs_prior_mean = obs_ens_handle%copies(OBS_PRIOR_MEAN_START: &
            OBS_PRIOR_MEAN_END, owners_index)
         orig_obs_prior_var  = obs_ens_handle%copies(OBS_PRIOR_VAR_START:  &
            OBS_PRIOR_VAR_END, owners_index)

         ! Compute observation space increments for each group
         do group = 1, num_groups
            grp_bot = grp_beg(group)
            grp_top = grp_end(group)
            call obs_increment(obs_prior(grp_bot:grp_top), grp_size, obs(1), &
               obs_err_var, obs_inc(grp_bot:grp_top), inflate, my_inflate,   &
               my_inflate_sd, net_a(group))
         end do

         ! Compute updated values for single state space inflation
         SINGLE_SS_INFLATE: if(local_single_ss_inflate) then
            ss_inflate_base = ens_handle%copies(ENS_SD_COPY, 1)
            ! Update for each group separately
            do group = 1, num_groups
               ! If either inflation or sd is not positive, not really doing inflation
               if(my_inflate > 0.0_r8 .and. my_inflate_sd > 0.0_r8) then
                  ! For case with single spatial inflation, use gamma = 1.0_r8
                  ! See adaptive inflation module for details
                  gamma = 1.0_r8
                  ! Deflate the inflated variance; required for efficient single pass
                  ! This is one of many places that assumes linear state/obs relation
                  ! over range of ensemble; Essentially, we are removing the inflation
                  ! which has already been applied in filter to see what inflation should
                  ! have been needed.
                  ens_obs_mean = orig_obs_prior_mean(group)
                  ens_obs_var = orig_obs_prior_var(group)
                  ens_var_deflate = ens_obs_var / &
                     (1.0_r8 + gamma*(sqrt(ss_inflate_base) - 1.0_r8))**2
                  
                  ! If this is inflate_only (i.e. posterior) remove impact of this obs.
                  ! This is simulating independent observation by removing its impact.
                  if(inflate_only) then
                     r_var = 1.0_r8 / (1.0_r8 / ens_var_deflate - 1.0_r8 / obs_err_var)
                     r_mean = r_var *(ens_obs_mean / ens_var_deflate - obs(1) / obs_err_var)
                  else
                     r_mean = ens_obs_mean
                     r_var = ens_var_deflate
                  endif

                  ! Update the inflation value
                  call update_inflation(inflate, my_inflate, my_inflate_sd, &
                     r_mean, r_var, obs(1), obs_err_var, gamma)
               endif
            end do
         endif SINGLE_SS_INFLATE
      endif IF_QC_IS_OKAY

      !Broadcast the info from this obs to all other processes
      ! What gets broadcast depends on what kind of inflation is being done
      if(local_varying_ss_inflate) then
         call broadcast_send(owner, obs_prior, obs_inc, orig_obs_prior_mean, &
            orig_obs_prior_var, net_a, scalar1=obs_qc)

      else if(local_single_ss_inflate .or. local_obs_inflate) then
         call broadcast_send(owner, obs_prior, obs_inc, net_a, &
           scalar1=my_inflate, scalar2=my_inflate_sd, scalar3=obs_qc)
      else
         call broadcast_send(owner, obs_prior, obs_inc, net_a, scalar1=obs_qc)
      endif

   ! Next block is done by processes that do NOT own this observation
   !-----------------------------------------------------------------------
   else
      ! I don't store this obs; receive the obs prior and increment from broadcast
      ! Also get qc and inflation information if needed
      if(local_varying_ss_inflate) then
         call broadcast_recv(owner, obs_prior, obs_inc, orig_obs_prior_mean, &
            orig_obs_prior_var, net_a, scalar1=obs_qc)
      else if(local_single_ss_inflate .or. local_obs_inflate) then
         call broadcast_recv(owner, obs_prior, obs_inc, net_a, &
            scalar1=my_inflate, scalar2=my_inflate_sd, scalar3=obs_qc)
      else
         call broadcast_recv(owner, obs_prior, obs_inc, net_a, scalar1=obs_qc)
      endif
   endif
   !-----------------------------------------------------------------------

   ! Everybody is doing this section, cycle if qc is bad
   if(nint(obs_qc) /= 0) cycle SEQUENTIAL_OBS

   ! Can compute prior mean and variance of obs for each group just once here
   do group = 1, num_groups
      grp_bot = grp_beg(group)
      grp_top = grp_end(group)
      obs_prior_mean(group) = sum(obs_prior(grp_bot:grp_top)) / grp_size
      obs_prior_var(group) = sum((obs_prior(grp_bot:grp_top) - obs_prior_mean(group))**2) / &
         (grp_size - 1)
      if (obs_prior_var(group) < 0.0_r8) obs_prior_var(group) = 0.0_r8
   end do

   ! Need to get obs density first in case of adaptive localization
   if (.not. get_close_buffering) then
      call get_close_obs(gc_obs, base_obs_loc, base_obs_kind, my_obs_loc, my_obs_kind, &
         num_close_obs, close_obs_ind, close_obs_dist)
   else
      if (base_obs_loc == last_base_obs_loc) then
         num_close_obs     = last_num_close_obs
         close_obs_ind(:)  = last_close_obs_ind(:)
         close_obs_dist(:) = last_close_obs_dist(:)
         num_close_obs_buffered = num_close_obs_buffered + 1
      else
         call get_close_obs(gc_obs, base_obs_loc, base_obs_kind, my_obs_loc, my_obs_kind, &
            num_close_obs, close_obs_ind, close_obs_dist)
         last_base_obs_loc      = base_obs_loc
         last_num_close_obs     = num_close_obs
         last_close_obs_ind(:)  = close_obs_ind(:)
         last_close_obs_dist(:) = close_obs_dist(:)
         num_close_obs_calls_made = num_close_obs_calls_made +1
      endif
   endif

   ! set the cutoff default, keep a copy of the original value, and avoid
   ! looking up the cutoff in a list if the incoming obs is an identity ob
   ! (and therefore has a negative kind).
   if (base_obs_kind >= 0) then
      cutoff_orig = cutoff_list(base_obs_kind)
   else
      cutoff_orig = cutoff
   endif

   cutoff_rev = cutoff_orig

   ! For adaptive localization, need number of other obs close to the chosen observation
   if(adaptive_localization_threshold > 0) then

      ! this does a cross-task sum, so all tasks must make this call.
      total_num_close_obs = count_close(num_close_obs, close_obs_ind, my_obs_kind, &
                                        close_obs_dist, cutoff_rev*2.0_r8)

      ! Want expected number of close observations to be reduced to some threshold;
      ! accomplish this by cutting the size of the cutoff distance.
      if(total_num_close_obs > adaptive_localization_threshold) then

         cutoff_rev = revised_distance(cutoff_rev*2.0_r8, adaptive_localization_threshold, &
                                       total_num_close_obs, base_obs_loc, &
                                       adaptive_cutoff_floor*2.0_r8) / 2.0_r8

         if ( output_localization_diagnostics ) then

            ! to really know how many obs are left now, you have to 
            ! loop over all the obs, again, count how many kinds are 
            ! going to be assim, and explicitly check the distance and 
            ! see if it's closer than the new cutoff ( times 2 ), and
            ! then do a global sum to get the total.  since this costs, 
            ! do it only when diagnostics are requested.

            ! this does a cross-task sum, so all tasks must make this call.
            rev_num_close_obs = count_close(num_close_obs, close_obs_ind, my_obs_kind, &
                                              close_obs_dist, cutoff_rev*2.0_r8)

      
            ! GSR output the new cutoff 
            ! Here is what we might want: 
            ! time, ob index #, ob location, new cutoff, the assimilate obs count, owner (which process has this ob)
            ! obs_time, obs_val_index, base_obs_loc, cutoff_rev, total_num_close_obs, owner
            ! break up the time into secs and days, and break up the location into lat, lon and height
            ! nsc - the min info here that can't be extracted from the obs key is:
            !  key (obs#), total_num_close_obs (close w/ original cutoff), revised cutoff & new count
            if (my_task_id() == 0) then
               call get_obs_def(observation, obs_def)
               this_obs_time = get_obs_def_time(obs_def)
               call get_time(this_obs_time,secs,days)
               call write_location(-1, base_obs_loc, charstring=base_loc_text)

               write(localization_unit,'(i8,1x,i5,1x,i8,1x,A,2(f14.5,1x,i10))') i, secs, days, &
                     trim(base_loc_text), cutoff_orig, total_num_close_obs, cutoff_rev, rev_num_close_obs
            endif
         endif

      endif

   else if (output_localization_diagnostics) then
      ! if you aren't adapting but you still want to know how many obs are within the
      ! localization radius, set the diag output.  this could be large, use carefully.

      ! this does a cross-task sum, so all tasks must make this call.
      total_num_close_obs = count_close(num_close_obs, close_obs_ind, my_obs_kind, &
                                        close_obs_dist, cutoff_rev*2.0_r8)

      if (my_task_id() == 0) then
         call get_obs_def(observation, obs_def)
         this_obs_time = get_obs_def_time(obs_def)
         call get_time(this_obs_time,secs,days)
         call write_location(-1, base_obs_loc, charstring=base_loc_text)

         write(localization_unit,'(i8,1x,i5,1x,i8,1x,A,f14.5,1x,i10)') i, secs, days, &
               trim(base_loc_text), cutoff_rev, total_num_close_obs
      endif
   endif

   ! Now everybody updates their close states
   ! Find state variables on my process that are close to observation being assimilated
   if (.not. get_close_buffering) then
      call get_close_obs(gc_state, base_obs_loc, base_obs_kind, my_state_loc, my_state_kind, &
         num_close_states, close_state_ind, close_state_dist)
   else
      if (base_obs_loc == last_base_states_loc) then
         num_close_states    = last_num_close_states
         close_state_ind(:)  = last_close_state_ind(:)
         close_state_dist(:) = last_close_state_dist(:)
         num_close_states_buffered = num_close_states_buffered + 1
      else
         call get_close_obs(gc_state, base_obs_loc, base_obs_kind, my_state_loc, my_state_kind, &
            num_close_states, close_state_ind, close_state_dist)
         last_base_states_loc     = base_obs_loc
         last_num_close_states    = num_close_states
         last_close_state_ind(:)  = close_state_ind(:)
         last_close_state_dist(:) = close_state_dist(:)
         num_close_states_calls_made = num_close_states_calls_made + 1 
      endif
   endif

   ! Loop through to update each of my state variables that is potentially close
   STATE_UPDATE: do j = 1, num_close_states
      state_index = close_state_ind(j)

      ! Get the initial values of inflation for this variable if state varying inflation
      if(local_varying_ss_inflate) then
         varying_ss_inflate    = ens_handle%copies(ENS_INF_COPY,    state_index)
         varying_ss_inflate_sd = ens_handle%copies(ENS_INF_SD_COPY, state_index)
      else
         varying_ss_inflate    = 0.0_r8
         varying_ss_inflate_sd = 0.0_r8
      endif
     
      ! Compute the distance and covariance factor 
!PAR URGENT: MAKE SURE THIS INDEXING IS CORRECT; SAME FOR OTHER COMP_COV_FACTOR
      cov_factor = comp_cov_factor(close_state_dist(j), cutoff_rev, &
         base_obs_loc, base_obs_kind, my_state_loc(state_index), my_state_kind(state_index))

      ! If no weight is indicated, no more to do with this state variable
      if(cov_factor <= 0.0_r8) cycle STATE_UPDATE

      ! Loop through groups to update the state variable ensemble members
      do group = 1, num_groups
         grp_bot = grp_beg(group)
         grp_top = grp_end(group)
         ! Do update of state, correl only needed for varying ss inflate
         if(local_varying_ss_inflate .and. varying_ss_inflate > 0.0_r8 .and. &
            varying_ss_inflate_sd > 0.0_r8) then
            call update_from_obs_inc(obs_prior(grp_bot:grp_top), obs_prior_mean(group), &
               obs_prior_var(group), obs_inc(grp_bot:grp_top), &
               ens_handle%copies(grp_bot:grp_top, state_index), grp_size, &
               increment(grp_bot:grp_top), reg_coef(group), net_a(group), correl(group))
         else
            call update_from_obs_inc(obs_prior(grp_bot:grp_top), obs_prior_mean(group), &
               obs_prior_var(group), obs_inc(grp_bot:grp_top), &
               ens_handle%copies(grp_bot:grp_top, state_index), grp_size, &
               increment(grp_bot:grp_top), reg_coef(group), net_a(group))
         endif
      end do

      ! Compute an information factor for impact of this observation on this state
      if(num_groups == 1) then
          reg_factor = 1.0_r8
      else
         ! Pass the time along with the index for possible diagnostic output
         ! Compute regression factor for this obs-state pair
         reg_factor = comp_reg_factor(num_groups, reg_coef, obs_time, i, my_state(state_index))
      endif

      ! The final factor is the minimum of group regression factor and localization cov_factor
      reg_factor = min(reg_factor, cov_factor)

!PAR NEED TO TURN STUFF OFF MORE EFFICEINTLY
      ! If doing full assimilation, update the state variable ensemble with weighted increments
      if(.not. inflate_only) then
         ens_handle%copies(1:ens_size, state_index) = &
            ens_handle%copies(1:ens_size, state_index) + reg_factor * increment
      endif

      ! Compute spatially-variing state space inflation
      if(local_varying_ss_inflate) then
         ! base is the initial inflate value for this state variable
         ss_inflate_base = ens_handle%copies(ENS_SD_COPY, state_index)
         ! Loop through each group to update inflation estimate
         GroupInflate: do group = 1, num_groups
            if(varying_ss_inflate > 0.0_r8 .and. varying_ss_inflate_sd > 0.0_r8) then
               ! Gamma is less than 1 for varying ss, see adaptive inflate module
               gamma = reg_factor * abs(correl(group))
               ! Deflate the inflated variance using the INITIAL state inflate
               ! value (before these obs started gumming it up).
               ens_obs_mean = orig_obs_prior_mean(group)
               ens_obs_var =  orig_obs_prior_var(group)

               ! Remove the impact of inflation to allow efficient single pass with assim.
               ens_var_deflate = ens_obs_var / &
                  (1.0_r8 + gamma*(sqrt(ss_inflate_base) - 1.0_r8))**2
                  
               ! If this is inflate only (i.e. posterior) remove impact of this obs.
               if(inflate_only) then
                  ! It's possible that obs_error variance is smaller than posterior
                  ! Need to explain this, but fix here
                  if(obs_err_var > ens_var_deflate) then 
                     r_var  = 1.0_r8 / (1.0_r8 / ens_var_deflate - 1.0_r8 / obs_err_var)
                     r_mean = r_var *(ens_obs_mean / ens_var_deflate - obs(1) / obs_err_var)
                  else
                     r_var = ens_var_deflate
                     r_mean = ens_obs_mean
                  endif
               else
                  r_mean = ens_obs_mean
                  r_var  = ens_var_deflate
               endif

               ! IS A TABLE LOOKUP POSSIBLE TO ACCELERATE THIS?
               ! Update the inflation values
               call update_inflation(inflate, varying_ss_inflate, varying_ss_inflate_sd, &
                  r_mean, r_var, obs(1), obs_err_var, gamma)
            endif
            ! Copy updated values into ensemble obs storage
            ens_handle%copies(ENS_INF_COPY, state_index) = varying_ss_inflate
            ens_handle%copies(ENS_INF_SD_COPY, state_index) = varying_ss_inflate_sd
         end do GroupInflate
      endif

   end do STATE_UPDATE
   !------------------------------------------------------

   ! Now everybody updates their obs priors (only ones after this one)
   OBS_UPDATE: do j = 1, num_close_obs
      obs_index = close_obs_ind(j)
      ! Only have to update obs that have not yet been used
      if(my_obs(obs_index) > i) then

         ! Compute the distance and the covar_factor
         cov_factor = comp_cov_factor(close_obs_dist(j), cutoff_rev, &
            base_obs_loc, base_obs_kind, my_obs_loc(obs_index), my_obs_kind(obs_index))
         if(cov_factor <= 0.0_r8) cycle OBS_UPDATE

         ! Loop through and update ensemble members in each group
         do group = 1, num_groups
            grp_bot = grp_beg(group)
            grp_top = grp_end(group)
            call update_from_obs_inc(obs_prior(grp_bot:grp_top), obs_prior_mean(group), &
               obs_prior_var(group), obs_inc(grp_bot:grp_top), &
                obs_ens_handle%copies(grp_bot:grp_top, obs_index), grp_size, &
                increment(grp_bot:grp_top), reg_coef(group), net_a(group))
         end do

         ! Compute an information factor for impact of this observation on this state
         if(num_groups == 1) then
             reg_factor = 1.0_r8
         else
            ! Pass the time along with the index for possible diagnostic output
            ! Compute regression factor for this obs-state pair
            ! Negative indicates that this is an observation index
            reg_factor = comp_reg_factor(num_groups, reg_coef, obs_time, i, -1*my_obs(obs_index))
         endif

         ! Final weight is min of group and localization factors
         reg_factor = min(reg_factor, cov_factor)

         ! Only update state if indicated (otherwise just getting inflation)
         if(.not. inflate_only) then
            obs_ens_handle%copies(1:ens_size, obs_index) = &
              obs_ens_handle%copies(1:ens_size, obs_index) + reg_factor * increment
         endif
      endif
   end do OBS_UPDATE
end do SEQUENTIAL_OBS

! Every pe needs to get the current my_inflate and my_inflate_sd back
if(local_single_ss_inflate) then
   ens_handle%copies(ENS_INF_COPY, :) = my_inflate
   ens_handle%copies(ENS_INF_SD_COPY, :) = my_inflate_sd
end if

! Everybody needs to store the latest value for obs_inflate
if(local_obs_inflate) then
   call set_inflate(inflate, my_inflate)
   call set_sd(inflate, my_inflate_sd)
endif

! Free up the storage
call destroy_obs(observation)
call get_close_obs_destroy(gc_state)
call get_close_obs_destroy(gc_obs)

! Assure user we have done something
write(errstring, '(A,I8,A)') &
   'Processed', obs_ens_handle%num_vars, ' total observations'
if (print_trace_details >= 0) call error_handler(E_MSG,'filter_assim:',errstring)

! diagnostics for stats on saving calls by remembering obs at the same location.
! change .true. to .false. in the line below to remove the output completely.
if (get_close_buffering .and. .true.) then
   if (num_close_obs_buffered > 0 .and. do_output()) then
      print *, "Total number of calls made    to get_close_obs for obs/states:    ", &
                num_close_obs_calls_made + num_close_states_calls_made
      print *, "Total number of calls avoided to get_close_obs for obs/states:    ", &
                num_close_obs_buffered + num_close_states_buffered
      if (num_close_obs_buffered+num_close_obs_calls_made+ &
          num_close_states_buffered+num_close_states_calls_made > 0) then 
         print *, "Percent saved: ", 100.0_r8 * &
                   (real(num_close_obs_buffered+num_close_states_buffered, r8) /  &
                   (num_close_obs_calls_made+num_close_obs_buffered+ &
                    num_close_states_calls_made+num_close_states_buffered))
      endif
   endif
endif

!GSR close the localization diagnostics file
if(output_localization_diagnostics .and. my_task_id() == 0) then
  call close_file(localization_unit)
end if

end subroutine filter_assim

!-------------------------------------------------------------

subroutine obs_increment(ens_in, ens_size, obs, obs_var, obs_inc, &
   inflate, my_cov_inflate, my_cov_inflate_sd, net_a)

! Given the ensemble prior for an observation, the observation, and
! the observation error variance, computes increments and adjusts
! observation space inflation values

integer,                     intent(in)    :: ens_size
real(r8),                    intent(in)    :: ens_in(ens_size), obs, obs_var
real(r8),                    intent(out)   :: obs_inc(ens_size)
type(adaptive_inflate_type), intent(inout) :: inflate
real(r8),                    intent(inout) :: my_cov_inflate, my_cov_inflate_sd
real(r8),                    intent(out)   :: net_a

real(r8) :: ens(ens_size), inflate_inc(ens_size)
real(r8) :: prior_mean, prior_var, new_val(ens_size)
integer  :: i, ens_index(ens_size), new_index(ens_size)

real(r8) :: rel_weights(ens_size)

! Copy the input ensemble to something that can be modified
ens = ens_in

! Null value of net spread change factor is 1.0
net_a = 0.0_r8

! Compute prior variance and mean from sample
prior_mean = sum(ens) / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)

! If observation space inflation is being done, compute the initial 
! increments and update the inflation factor and its standard deviation
! as needed. my_cov_inflate < 0 means don't do any of this.
if(do_obs_inflate(inflate)) then
   ! If my_cov_inflate_sd is <= 0, just retain current my_cov_inflate setting
   if(my_cov_inflate_sd > 0.0_r8) & 
      ! Gamma set to 1.0 because no distance for observation space
      call update_inflation(inflate, my_cov_inflate, my_cov_inflate_sd, prior_mean, &
         prior_var, obs, obs_var, gamma = 1.0_r8)

   ! Now inflate the ensemble and compute a preliminary inflation increment
   call inflate_ens(inflate, ens, prior_mean, my_cov_inflate, prior_var)
   ! Keep the increment due to inflation alone 
   inflate_inc = ens - ens_in

   ! Need to recompute variance if non-deterministic inflation (mean is unchanged)
   if(.not. deterministic_inflate(inflate)) &
      prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)
endif

! If both obs_var and prior_var are 0 don't know what to do
if(obs_var == 0.0_r8 .and. prior_var == 0.0_r8) call error_handler(E_ERR,&
   'obs_increment', 'Both obs_var and prior_var are zero. This is inconsistent', &
           source, revision, revdate)

! Call the appropriate filter option to compute increments for ensemble
if(filter_kind == 1) then
   call obs_increment_eakf(ens, ens_size, prior_mean, prior_var, &
      obs, obs_var, obs_inc, net_a)
else if(filter_kind == 2) then
   call obs_increment_enkf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
else if(filter_kind == 3) then
   call obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
else if(filter_kind == 4) then
   call obs_increment_particle(ens, ens_size, obs, obs_var, obs_inc)
else if(filter_kind == 5) then
   call obs_increment_ran_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
else if(filter_kind == 6) then
   call obs_increment_det_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
else if(filter_kind == 7) then
   call obs_increment_boxcar(ens, ens_size, obs, obs_var, obs_inc, rel_weights)
else if(filter_kind == 8) then
   call obs_increment_boxcar2(ens, ens_size, prior_mean, prior_var, &
      obs, obs_var, obs_inc)
else 
   call error_handler(E_ERR,'obs_increment', &
              'Illegal value of filter_kind in assim_tools namelist [1-8 OK]', &
              source, revision, revdate)
endif

! Add in the extra increments if doing observation space covariance inflation
if(do_obs_inflate(inflate)) obs_inc = obs_inc + inflate_inc

! To minimize regression errors, may want to sort to minimize increments
! This makes sense for any of the non-deterministic algorithms
! By doing it here, can take care of both standard non-deterministic updates
! plus non-deterministic obs space covariance inflation. This is expensive, so
! don't use it if it's not needed.
if(sort_obs_inc) then
   new_val = ens_in + obs_inc
   ! Sorting to make increments as small as possible
   call index_sort(ens_in, ens_index, ens_size)
   call index_sort(new_val, new_index, ens_size)
   do i = 1, ens_size
      obs_inc(ens_index(i)) = new_val(new_index(i)) - ens_in(ens_index(i))
   end do
end if

! Get the net change in spread if obs space inflation was used
if(do_obs_inflate(inflate)) net_a = net_a * sqrt(my_cov_inflate)

end subroutine obs_increment



subroutine obs_increment_eakf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc, a)
!========================================================================
!
! EAKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_mean, prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
real(r8), intent(out) :: a

real(r8) :: new_mean, var_ratio

! Compute the new mean
if (obs_var /= 0.0_r8) then
   var_ratio = obs_var / (prior_var + obs_var)
   new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)
! If obs is a delta function, it becomes new value
else
   var_ratio = 0.0_r8
   new_mean  = obs
endif

! Compute sd ratio and shift ensemble
a = sqrt(var_ratio)
obs_inc = a * (ens - prior_mean) + new_mean - ens

end subroutine obs_increment_eakf


subroutine obs_increment_ran_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
!========================================================================
!
! Forms a random sample of the Gaussian from the update equations.
! This is very close to what a true 'ENSEMBLE' Kalman Filter would 
! look like. Note that outliers, multimodality, etc., get tossed.

integer,   intent(in)  :: ens_size
real(r8),  intent(in)  :: prior_mean, prior_var
real(r8),  intent(in)  :: ens(ens_size), obs, obs_var
real(r8),  intent(out) :: obs_inc(ens_size)

real(r8) :: new_mean, var_ratio
real(r8) :: temp_mean, temp_var, new_ens(ens_size), new_var
integer  :: i

if (obs_var /= 0.0_r8) then
   var_ratio = obs_var / (prior_var + obs_var)
   new_var = var_ratio * prior_var
   new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)
else
   var_ratio = 0.0_r8
   new_var = var_ratio * prior_var
   new_mean  = obs
endif

! Now, just form a random sample from the updated distribution
! Then adjust the mean (what about adjusting the variance?)!
! Definitely need to sort with this; sort is done in main obs_increment
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq)
   first_inc_ran_call = .false.
endif

do i = 1, ens_size
   new_ens(i) = random_gaussian(inc_ran_seq, new_mean, sqrt(prior_var*var_ratio))
end do

! Adjust the mean of the new ensemble
temp_mean = sum(new_ens) / ens_size
new_ens(:) = new_ens(:) - temp_mean + new_mean

! Compute prior variance and mean from sample
temp_var  = sum((new_ens - new_mean)**2) / (ens_size - 1)
! Adjust the variance, also
new_ens = (new_ens - new_mean) * sqrt(new_var / temp_var) + new_mean

! Get the increments
obs_inc = new_ens - ens

end subroutine obs_increment_ran_kf



subroutine obs_increment_det_kf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
!========================================================================
!
! Does a deterministic ensemble layout for the updated Gaussian.
! Note that all outliers, multimodal behavior, etc. get tossed.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: prior_mean, prior_var
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: new_mean, var_ratio, temp_var, new_ens(ens_size), new_var
integer :: i

if (obs_var /= 0.0_r8) then
   var_ratio = obs_var / (prior_var + obs_var)
   new_var = var_ratio * prior_var
   new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)
else
   if (prior_var /= 0.0_r8) then
      var_ratio = 0.0_r8
      new_var = var_ratio * prior_var
      new_mean  = obs
   else
      call error_handler(E_ERR,'obs_increment_det_kf', &
           'Both obs_var and prior_var are zero. This is inconsistent', &
           source, revision, revdate)
   endif
endif

! Want a symmetric distribution with kurtosis 3 and variance new_var and mean new_mean
if(ens_size /= 20) then
   write(*, *) 'EXPERIMENTAL version obs_increment_det_kf only works for ens_size 20 now'
   stop
endif

! This has kurtosis of 3.0, verify again from initial uniform
!new_ens(1) = -2.146750_r8
!new_ens(2) = -1.601447_r8
!new_ens(3) = -1.151582_r8
!new_ens(4) = -0.7898650_r8
!new_ens(5) = -0.5086292_r8
!new_ens(6) = -0.2997678_r8
!new_ens(7) = -0.1546035_r8
!new_ens(8) = -6.371084E-02_r8
!new_ens(9) = -1.658448E-02_r8
!new_ens(10) = -9.175255E-04_r8

! This has kurtosis of 3.0, verify again from initial inverse gaussian
!new_ens(1) = -2.188401_r8
!new_ens(2) = -1.502174_r8
!new_ens(3) = -1.094422_r8
!new_ens(4) = -0.8052422_r8
!new_ens(5) = -0.5840152_r8
!new_ens(6) = -0.4084518_r8
!new_ens(7) = -0.2672727_r8
!new_ens(8) = -0.1547534_r8
!new_ens(9) = -6.894587E-02_r8
!new_ens(10) = -1.243549E-02_r8

! This has kurtosis of 2.0, verify again 
new_ens(1) = -1.789296_r8
new_ens(2) = -1.523611_r8
new_ens(3) = -1.271505_r8
new_ens(4) = -1.033960_r8
new_ens(5) = -0.8121864_r8
new_ens(6) = -0.6077276_r8
new_ens(7) = -0.4226459_r8
new_ens(8) = -0.2598947_r8
new_ens(9) = -0.1242189_r8
new_ens(10) = -2.539018E-02_r8

! This has kurtosis of 1.7, verify again 
!new_ens(1) = -1.648638_r8
!new_ens(2) = -1.459415_r8
!new_ens(3) = -1.272322_r8
!new_ens(4) = -1.087619_r8
!new_ens(5) = -0.9056374_r8
!new_ens(6) = -0.7268229_r8
!new_ens(7) = -0.5518176_r8
!new_ens(8) = -0.3816142_r8
!new_ens(9) = -0.2179997_r8
!new_ens(10) = -6.538583E-02_r8
do i = 11, 20
   new_ens(i) = -1.0_r8 * new_ens(20 + 1 - i)
end do

! Right now, this ensemble has mean 0 and some variance
! Compute prior variance and mean from sample
temp_var  = sum((new_ens)**2) / (ens_size - 1)

! Adjust the variance of this ensemble to match requirements and add in the mean
new_ens = new_ens * sqrt(new_var / temp_var) + new_mean

! Get the increments
obs_inc = new_ens - ens

end subroutine obs_increment_det_kf




subroutine obs_increment_particle(ens, ens_size, obs, obs_var, obs_inc)
!------------------------------------------------------------------------
!
! A observation space only particle filter implementation for a
! two step sequential update filter. Second version, 2 October, 2003.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: a, weight(ens_size), rel_weight(ens_size), cum_weight(0:ens_size)
real(r8) :: base, frac, new_val(ens_size), weight_sum
integer  :: i, j, indx(ens_size)

! The factor a is not defined for particle filters
a = -1.0_r8

! Begin by computing a weight for each of the prior ensemble members
do i = 1, ens_size
   weight(i) = exp(-1.0_r8 * (ens(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Compute relative weight for each ensemble member
weight_sum = sum(weight)
do i = 1, ens_size
   rel_weight(i) = weight(i) / weight_sum
end do

! Compute cumulative weights at boundaries
cum_weight(0) = 0.0_r8
do i = 1, ens_size
   cum_weight(i) = cum_weight(i - 1) + rel_weight(i)
!   write(*,'(1x,i3,3(e10.4,1x))') i, weight(i), rel_weight(i), cum_weight(i)
end do
! Fix up for round-off error if any
cum_weight(ens_size) = 1.0_r8

! Do a deterministic implementation: just divide interval into ens_size parts and see
! which interval this is in (careful to offset; not start at 0)
base = 1.0_r8 / (ens_size * 2.0_r8)

do i = 1, ens_size

   frac = base + (i - 1.0_r8) / ens_size

   ! Now search in the cumulative range to see where this frac falls
   ! Can make this search more efficient by limiting base
   do j = 1, ens_size
      if(cum_weight(j - 1) < frac .and. frac < cum_weight(j)) then
         indx(i) = j
!         write(*, *) i, frac, 'gets index ', j
         goto 111
      end if
   end do

111 continue

end do

! Set the new values for the ensemble members
do i = 1, ens_size
   new_val(i) = ens(indx(i))
!   write(*, *) 'new_val ', i, new_val(i)
end do

! Generate increments
obs_inc = new_val - ens

end subroutine obs_increment_particle



subroutine obs_increment_enkf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc)
!========================================================================
! subroutine obs_increment_enkf(ens, ens_size, obs, obs_var, obs_inc)
!

! ENKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_mean, prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: a, obs_var_inv, prior_var_inv, new_var, new_mean(ens_size)
! real(r8) :: sx, s_x2
real(r8) :: temp_mean, temp_obs(ens_size)
integer  :: i

! The factor a is not defined for kernel filters
a = -1.0_r8

! Compute mt_rinv_y (obs error normalized by variance)
obs_var_inv = 1.0_r8 / obs_var

prior_var_inv = 1.0_r8 / prior_var
new_var       = 1.0_r8 / (prior_var_inv + obs_var_inv)

! If this is first time through, need to initialize the random sequence
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq)
   first_inc_ran_call = .false.
endif

! Generate perturbed obs
do i = 1, ens_size
    temp_obs(i) = random_gaussian(inc_ran_seq, obs, sqrt(obs_var))
end do

! Move this so that it has original obs mean
temp_mean = sum(temp_obs) / ens_size
temp_obs(:) = temp_obs(:) - temp_mean + obs

! Loop through pairs of priors and obs and compute new mean
do i = 1, ens_size
   new_mean(i) = new_var * (prior_var_inv * ens(i) + temp_obs(i) / obs_var)
   obs_inc(i)  = new_mean(i) - ens(i)
end do

! Can also adjust mean (and) variance of final sample; works fine
!sx         = sum(new_mean)
!s_x2       = sum(new_mean * new_mean)
!temp_mean = sx / ens_size
!temp_var  = (s_x2 - sx**2 / ens_size) / (ens_size - 1)
!new_mean = (new_mean - temp_mean) * sqrt(new_var / temp_var) + updated_mean
!obs_inc = new_mean - ens


end subroutine obs_increment_enkf



subroutine obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
!========================================================================
! subroutine obs_increment_kernel(ens, ens_size, obs, obs_var, obs_inc)
!

! Kernel version of obs increment

integer, intent(in)             :: ens_size
real(r8), intent(in)            :: ens(ens_size), obs, obs_var
real(r8), intent(out)           :: obs_inc(ens_size)

real(r8) :: obs_var_inv
real(r8) :: prior_mean, prior_cov_inv, new_cov, prior_cov
real(r8) :: sx, s_x2
real(r8) :: weight(ens_size), new_mean(ens_size)
real(r8) :: cum_weight, total_weight, cum_frac(ens_size)
real(r8) :: unif, norm, new_member(ens_size)

integer :: i, j, kernel

! Compute mt_rinv_y (obs error normalized by variance)
obs_var_inv = 1.0_r8 / obs_var

! Compute prior mean and covariance
sx         = sum(ens)
s_x2       = sum(ens * ens)
prior_mean = sx / ens_size
prior_cov  = sum((ens - prior_mean)**2) / (ens_size - 1)

prior_cov     = prior_cov / 10.0_r8     ! For kernels, scale the prior covariance
prior_cov_inv = 1.0_r8 / prior_cov

! Compute new covariance once for these kernels
new_cov = 1.0_r8 / (prior_cov_inv + obs_var_inv)

! New mean is computed ens_size times as is weight
do i = 1, ens_size
   new_mean(i) = new_cov*(prior_cov_inv * ens(i) + obs / obs_var)
   weight(i) =  2.71828_r8 ** (-0.5_r8 * (ens(i)**2 * prior_cov_inv + &
      obs**2 * obs_var_inv - new_mean(i)**2 / new_cov))
end do

! Compute total weight
total_weight = sum(weight)
cum_weight   = 0.0_r8
do i = 1, ens_size
   cum_weight  = cum_weight + weight(i)
   cum_frac(i) = cum_weight / total_weight
end do

! If this is first time through, need to initialize the random sequence
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq)
   first_inc_ran_call = .false.
endif

! Generate a uniform random number and a Gaussian for each new member
do i = 1, ens_size
   unif = random_uniform(inc_ran_seq)
   ! Figure out which kernel it's in
   do j = 1, ens_size
      if(unif < cum_frac(j)) then
         kernel = j
         goto 10
      end if
   end do
10 continue

   ! Next calculate a unit normal in this kernel
   norm = random_gaussian(inc_ran_seq, 0.0_r8, sqrt(new_cov))
   ! Now generate the new ensemble member
   new_member(i) = new_mean(kernel) + norm
end do

! Generate the increments
obs_inc = new_member - ens

end subroutine obs_increment_kernel



subroutine update_from_obs_inc(obs, obs_prior_mean, obs_prior_var, obs_inc, &
               state, ens_size, state_inc, reg_coef, net_a, correl_out)
!========================================================================

! Does linear regression of a state variable onto an observation and
! computes state variable increments from observation increments

integer,            intent(in)    :: ens_size
real(r8),           intent(in)    :: obs(ens_size), obs_inc(ens_size)
real(r8),           intent(in)    :: obs_prior_mean, obs_prior_var
real(r8),           intent(in)    :: state(ens_size)
real(r8),           intent(out)   :: state_inc(ens_size), reg_coef
real(r8),           intent(inout) :: net_a
real(r8), optional, intent(inout) :: correl_out

real(r8) :: obs_state_cov, intermed
real(r8) :: restoration_inc(ens_size), state_mean, state_var, correl
real(r8) :: factor, exp_true_correl, mean_factor

! For efficiency, just compute regression coefficient here unless correl is needed
state_mean = sum(state) / ens_size
obs_state_cov = sum( (state - state_mean) * (obs - obs_prior_mean) ) / (ens_size - 1)

if (obs_prior_var > 0.0_r8) then
   reg_coef = obs_state_cov/obs_prior_var
else
   reg_coef = 0.0_r8
endif

! If correl_out is present, need correl for adaptive inflation
! Also needed for file correction below.

! WARNING: we have had several different numerical problems in this
! section, especially with users running in single precision floating point.
! Be very cautious if changing any code in this section, taking into
! account underflow and overflow for 32 bit floats.

if(present(correl_out) .or. sampling_error_correction) then
   if (obs_state_cov == 0.0_r8 .or. obs_prior_var <= 0.0_r8) then
      correl = 0.0_r8
   else
      state_var = sum((state - state_mean)**2) / (ens_size - 1)
      if (state_var <= 0.0_r8) then
         correl = 0.0_r8
      else
         intermed = sqrt(obs_prior_var) * sqrt(state_var)
         if (intermed <= 0.0_r8) then
            correl = 0.0_r8
         else
            correl = obs_state_cov / intermed
         endif
      endif
   endif
   if(correl >  1.0_r8) correl =  1.0_r8
   if(correl < -1.0_r8) correl = -1.0_r8
endif
if(present(correl_out)) correl_out = correl


! BEGIN TEST OF CORRECTION FROM FILE +++++++++++++++++++++++++++++++++++++++++++++++++
! Get the expected actual correlation and the regression weight reduction factor
if(sampling_error_correction) then
   call get_correction_from_file(ens_size, correl, mean_factor, exp_true_correl)
   ! Watch out for division by zero; if correl is really small regression is safely 0
   if(abs(correl) > 0.001_r8) then
      reg_coef = reg_coef * (exp_true_correl / correl) * mean_factor
   else
      reg_coef = 0.0_r8
   endif
   correl = exp_true_correl
endif

! END TEST OF CORRECTION FROM FILE +++++++++++++++++++++++++++++++++++++++++++++++++



! Then compute the increment as product of reg_coef and observation space increment
state_inc = reg_coef * obs_inc


! Spread restoration algorithm option
if(spread_restoration) then
   ! Don't use this to reduce spread at present (should revisit this line)
   if(net_a > 1.0_r8) net_a = 1.0_r8

   ! Default restoration increment is 0.0
   restoration_inc = 0.0_r8

   ! Compute the factor by which to inflate
   ! These come from correl_error.f90 in system_simulation and the files ens??_pairs and
   ! ens_pairs_0.5 in work under system_simulation. Assume a linear reduction from 1
   ! as a function of the net_a. Assume that the slope of this reduction is a function of
   ! the reciprocal of the ensemble_size (slope = 0.80 / ens_size). These are empirical
   ! for now. See also README in spread_restoration_paper documentation.
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) * (0.8_r8 / ens_size)) - 1.0_r8
   factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) / (-2.4711_r8 + 1.6386_r8 * ens_size)) - 1.0_r8
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a**2 - 1.0_r8) * (-0.0111_r8 + .8585_r8 / ens_size)) - 1.0_r8

   ! Variance restoration
   state_mean = sum(state) / ens_size
   restoration_inc = factor * (state - state_mean)
   state_inc = state_inc + restoration_inc
endif

!! NOTE: if requested to be returned, correl_out is set further up in the
!! code, before the sampling error correction, if enabled, is applied.
!! this means it's returning a different larger value than the correl 
!! being returned here.  it's used by the adaptive inflation and so the
!! inflation will see a slightly different correlation value.  it isn't
!! clear that this is a bad thing; it means the inflation might be a bit
!! larger than it would otherwise.  before we move any code this would
!! need to be studied to see what the real impact would be.

end subroutine update_from_obs_inc


!------------------------------------------------------------------------

subroutine get_correction_from_file(ens_size, scorrel, mean_factor, expected_true_correl)

integer,   intent(in) :: ens_size
real(r8),  intent(in) :: scorrel
real(r8), intent(out) :: mean_factor, expected_true_correl

! Reads in a regression error file for a give ensemble_size and uses interpolation
! to get correction factor into the file

integer             :: iunit, i, low_indx, high_indx
real(r8)            :: temp, temp2, correl, fract, low_correl, low_exp_correl, low_alpha
real(r8)            :: high_correl, high_exp_correl, high_alpha
character(len = 20) :: correction_file_name

if(first_get_correction) then
   ! Compute the file name for this ensemble size
   if(ens_size < 10) then
      write(correction_file_name, 11) 'final_full.', ens_size
   else if(ens_size < 100) then
      write(correction_file_name, 21) 'final_full.', ens_size
   else if(ens_size < 1000) then
      write(correction_file_name, 31) 'final_full.', ens_size
   else if(ens_size < 10000) then
      write(correction_file_name, 41) 'final_full.', ens_size
   else
      write(errstring,*)'Trying to use ',ens_size,' model states -- too many.'
      call error_handler(E_ERR,'get_correction_from_file','Use less than 10000 ens members.',&
         source,revision,revdate, text2=errstring)

    11   format(a11, i1)
    21   format(a11, i2)
    31   format(a11, i3)
    41   format(a11, i4)
   endif
 
   ! Make sure that the correction file exists, else an error
   if(.not. file_exist(correction_file_name)) then
      write(errstring,*) 'Correction file ', correction_file_name, ' does not exist'
      call error_handler(E_ERR,'get_correction_from_file',errstring,source,revision,revdate)
   endif

   ! Read in file to get the expected value of the true correlation given the sample
   iunit = get_unit()
   open(unit = iunit, file = correction_file_name)
   do i = 1, 200
      read(iunit, *) temp, temp2, exp_true_correl(i), alpha(i)
   end do
   close(iunit)

   first_get_correction = .false.
endif

! Interpolate to get values of expected correlation and mean_factor
if(scorrel < -1.0_r8) then
   correl = -1.0_r8
   mean_factor = 1.0_r8
else if(scorrel > 1.0_r8) then
   correl = 1.0_r8
   mean_factor = 1.0_r8
else if(scorrel <= -0.995_r8) then
   fract = (scorrel + 1.0_r8) / 0.005_r8
   correl = (exp_true_correl(1) + 1.0_r8) * fract - 1.0_r8
   mean_factor = (alpha(1) - 1.0_r8) * fract + 1.0_r8
else if(scorrel >= 0.995_r8) then
   fract = (scorrel - 0.995_r8) / 0.005_r8
   correl = (1.0_r8 - exp_true_correl(200)) * fract + exp_true_correl(200)
   mean_factor = (1.0_r8 - alpha(200)) * fract + alpha(200)
else
   ! given the ifs above, the floor() computation below for low_indx 
   ! should always result in a value in the range 1 to 199.  but if this
   ! code is compiled with r8=r4 (single precision reals) it turns out
   ! to be possible to get values a few bits below 0 which results in
   ! a very large negative integer.  the limit tests below ensure the
   ! index stays in a legal range.
   low_indx = floor((scorrel + 0.995_r8) / 0.01_r8 + 1.0_r8)
   if (low_indx <   1) low_indx =   1
   if (low_indx > 199) low_indx = 199
   low_correl = -0.995_r8 + (low_indx - 1) * 0.01_r8
   low_exp_correl = exp_true_correl(low_indx)
   low_alpha = alpha(low_indx)
   high_indx = low_indx + 1
   high_correl = low_correl + 0.01_r8
   high_exp_correl = exp_true_correl(high_indx)
   high_alpha = alpha(high_indx)
   fract = (scorrel - low_correl) / (high_correl - low_correl)
   correl = (high_exp_correl - low_exp_correl) * fract + low_exp_correl
   mean_factor = (high_alpha - low_alpha) * fract + low_alpha
endif

expected_true_correl = correl 

! Don't want Monte Carlo interpolation problems to put us outside of a
! ratio between 0 and 1 for expected_true_correl / sample_correl
! If they have different signs, expected should just be 0
if(expected_true_correl * scorrel <= 0.0_r8) then
   expected_true_correl = 0.0_r8
else if(abs(expected_true_correl) > abs(scorrel)) then
   ! If same sign, expected should not be bigger in absolute value
   expected_true_correl = scorrel
endif 

end subroutine get_correction_from_file



subroutine obs_increment_boxcar(ens, ens_size, obs, obs_var, obs_inc, rel_weight)
!------------------------------------------------------------------------
!
! An observation space update that uses a set of boxcar kernels plus two
! half-gaussians on the wings to represent the prior distribution. If N is
! the ensemble size, 1/(N+1) of the mass is placed between each ensemble
! member. This is reminiscent of the ranked historgram approach for 
! evaluating ensembles. The prior distribution on the wings is 
! represented by a half gaussian with mean being the outermost ensemble
! member (left or right) and variance being somewhat arbitrarily chosen
! as half the total ensemble sample variance. A particle
! filter like algorithm is then used for the update. The weight associated
! with each prior ensemble member is computed by evaluating the likelihood.
! For the interior, the domain for each boxcar is divided in half and each
! half is associated with the nearest ensemble member. The updated mass in
! each half box is the product of the prior mass and the ensemble weight.
! In the wings, the observation likelihood gaussian is convolved with the
! prior gaussian to get an updated weighted gaussian that is assumed to 
! represent the posterior outside of the outermost ensemble members. The
! updated ensemble members are chosen so that 1/(N+1) of the updated
! mass is between each member and also on the left and right wings. This
! algorithm is able to deal well with outliers, bimodality and other
! non-gaussian behavior in observation space. It could also be modified to
! deal with non-gaussian likelihoods in the future.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
real(r8), intent(out) :: rel_weight(ens_size)

integer  :: i, e_ind(ens_size), lowest_box, j
real(r8) :: a
real(r8) :: sx, prior_mean, prior_var, prior_var_d2
real(r8) :: var_ratio, new_var, new_sd, umass, left_weight, right_weight
real(r8) :: mass(2*ens_size), weight(ens_size), cumul_mass(0:2*ens_size)
real(r8) :: new_mean_left, new_mean_right, prod_weight_left, prod_weight_right
real(r8) :: new_ens(ens_size), mass_sum, const_term
real(r8) :: x(1:2*ens_size - 1), sort_inc(ens_size)

! The factor a is not defined for this filter for now (could it be???)
a = -1.0_r8

! The relative weights could be used for a multi-dimensional particle-type
! update using update_ens_from_weights. There are algorithmic challenges
! with outliers so this is not currently a supported option. For now,
! rel_weight is simply set to 0 and is unused elsewhere.
rel_weight = 0.0_r8

! Do an index sort of the ensemble members; Need sorted ensemble
call index_sort(ens, e_ind, ens_size)

! Prior distribution is boxcar in the central bins with 1/(n+1) density
! in each intermediate bin. BUT, distribution on the wings is a normal with
! 1/(n + 1) of the mass on each side.

! Begin by computing a weight for each of the prior ensemble membersA
! This is just evaluating the gaussian likelihood
const_term = 1.0_r8 / (sqrt(2.0_r8 * PI) * sqrt(obs_var))
do i = 1, ens_size
   weight(i) = const_term * exp(-1.0_r8 * (ens(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Compute the points that bound all the updated mass boxes; start with ensemble
do i = 1, ens_size
   x(2*i - 1) = ens(e_ind(i))
end do
! Compute the mid-point interior boundaries; these are halfway between ensembles
do i = 2, 2*ens_size - 2, 2
   x(i) = (x(i - 1) + x(i + 1)) / 2.0_r8
end do

! Compute the s.d. of the ensemble for getting the gaussian wings
sx         = sum(ens)
prior_mean = sx / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)

! Need to normalize the wings so they have 1/(ens_size + 1) mass outside
! Since 1/2 of a normal is outside, need to multiply by 2 / (ens_size + 1)

! Need some sort of width for the boundary kernel, try 1/2 the VAR for now
prior_var_d2 = prior_var / 2.0_r8

! Compute the product of the obs error gaussian with the prior gaussian (EAKF)
! Left wing first
var_ratio = obs_var / (prior_var_d2 + obs_var)
new_var = var_ratio * prior_var_d2
new_sd = sqrt(new_var)
new_mean_left  = var_ratio * (ens(e_ind(1))  + prior_var_d2*obs / obs_var)
new_mean_right  = var_ratio * (ens(e_ind(ens_size))  + prior_var_d2*obs / obs_var)
! REMEMBER, this product has an associated weight which must be taken into account
! See Anderson and Anderson for this weight term (or tutorial kernel filter)
prod_weight_left =  2.71828_r8 ** (-0.5_r8 * (ens(e_ind(1))**2 / prior_var_d2 + &
      obs**2 / obs_var - new_mean_left**2 / new_var)) / sqrt(2.0_r8 * PI)

prod_weight_right =  2.71828_r8 ** (-0.5_r8 * (ens(e_ind(ens_size))**2 / prior_var_d2 + &
      obs**2 / obs_var - new_mean_right**2 / new_var)) / sqrt(2.0_r8 * PI)

! Split into 2*ens_size domains; mass in each is computed
! Start by computing mass in the outermost (gaussian) regions
mass(1) = norm_cdf(ens(e_ind(1)), new_mean_left, new_sd) * &
   prod_weight_left * (2.0_r8 / (ens_size + 1.0_r8))
mass(2*ens_size) = (1.0_r8 - norm_cdf(ens(e_ind(ens_size)), new_mean_right, &
   new_sd)) * prod_weight_right * (2.0_r8 / (ens_size + 1.0_r8))

! Compute mass in the inner half boxes that have ensemble point on the left
do i = 2, 2*ens_size - 2, 2
   mass(i) = (1.0_r8 / (2.0_r8 * (ens_size + 1.0_r8))) * weight(e_ind(i/2))
end do

! Now right inner half boxes
do i = 3, 2*ens_size - 1, 2
   mass(i) = (1.0_r8 / (2.0_r8 * (ens_size + 1.0_r8))) * weight(e_ind(i/2 + 1))
end do

! Now normalize the mass in the different bins
mass_sum = sum(mass)
mass = mass / mass_sum

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(0) = 0.0_r8
do i = 1, 2*ens_size
   cumul_mass(i) = cumul_mass(i - 1) + mass(i)
end do

! Get resampled ensemble, Need 1/(ens_size + 1) between each
umass = 1.0_r8 / (ens_size + 1.0_r8)

! Begin search at bottom of lowest box, but then update for efficiency
lowest_box = 1

! Find each new ensemble members location
do i = 1, ens_size
   ! If it's in the inner or outer range have to use normal
   if(umass < cumul_mass(1)) then
      ! In the first normal box
      left_weight = (1.0_r8 / mass_sum) * prod_weight_left * (2.0_r8 / (ens_size + 1.0_r8))
      call weighted_norm_inv(left_weight, new_mean_left, new_sd, umass, new_ens(i))
   else if(umass > cumul_mass(2*ens_size - 1)) then
      ! In the last normal box; Come in from the outside
      right_weight = (1.0_r8 / mass_sum) * prod_weight_right * (2.0_r8 / (ens_size + 1.0_r8))
      call weighted_norm_inv(right_weight, new_mean_right, new_sd, 1.0_r8 - umass, new_ens(i))
      new_ens(i) = new_mean_right + (new_mean_right - new_ens(i))
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, 2 * ens_size - 2
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then
            new_ens(i) = x(j) + ((umass - cumul_mass(j)) / (cumul_mass(j+1) - cumul_mass(j))) * &
               (x(j + 1) - x(j))
            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
   ! Want equally partitioned mass in update with exception that outermost boxes have half
   umass = umass + 1.0_r8 / (ens_size + 1.0_r8)
end do

! Can now compute sorted increments
do i = 1, ens_size
   sort_inc(i) = new_ens(i) - ens(e_ind(i))
end do

! Now, need to convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = sort_inc(i)
end do

end subroutine obs_increment_boxcar



subroutine obs_increment_boxcar2(ens, ens_size, prior_mean, prior_var, &
   obs, obs_var, obs_inc)
!------------------------------------------------------------------------
! 
! Revised 14 November 2008
!
! Does observation space update by approximating the prior distribution by
! a rank histogram. Prior and posterior are assumed to have 1/(n+1) probability
! mass between each ensemble member. The tails are assumed to be gaussian with
! a variance equal to sample variance of the entire ensemble and a mean 
! selected so that 1/(n+1) of the mass is in each tail.
!
! The likelihood between the extreme ensemble members is approximated by
! quadrature. Two options are available and controlled by the namelist entry
! rectangular_quadrature. If this namelist is true than the likelihood between
! a pair of ensemble members is assumed to be uniform with the average of
! the likelihood computed at the two ensemble members. If it is false then
! the likelihood between two ensemble members is approximated by a line
! connecting the values of the likelihood computed at each of the ensemble
! members (trapezoidal quadrature). 
!
! Two options are available for approximating the likelihood on the tails.
! If gaussian_likelihood_tails is true that the likelihood is assumed to
! be N(obs, obs_var) on the tails. If this is false, then the likelihood
! on the tails is taken to be uniform (to infinity) with the value at the
! outermost ensemble members.
!
! A product of the approximate prior and approximate posterior is taken
! and new ensemble members are located so that 1/(n+1) of the mass is between
! each member and on the tails.

! This code is still under development. Please contact Jeff Anderson at
! jla@ucar.edu if you are interested in trying it. 

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_mean, prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

integer  :: i, e_ind(ens_size), lowest_box, j
real(r8) :: prior_sd, var_ratio, umass, left_amp, right_amp
real(r8) :: left_sd, left_var, right_sd, right_var, left_mean, right_mean
real(r8) :: mass(ens_size + 1), like(ens_size), cumul_mass(0:ens_size + 1)
real(r8) :: nmass(ens_size + 1)
real(r8) :: new_mean_left, new_mean_right, prod_weight_left, prod_weight_right
real(r8) :: new_var_left, new_var_right, new_sd_left, new_sd_right
real(r8) :: new_ens(ens_size), mass_sum
real(r8) :: x(ens_size)
real(r8) :: like_dense(2:ens_size), height(2:ens_size)
real(r8) :: dist_for_unit_sd
real(r8) :: a, b, c, hright, hleft, r1, r2, adj_r1, adj_r2

! Do an index sort of the ensemble members; Will want to do this very efficiently
call index_sort(ens, e_ind, ens_size)

do i = 1, ens_size
   ! The boundaries of the interior bins are just the sorted ensemble members
   x(i) = ens(e_ind(i))
   ! Compute likelihood for each ensemble member; just evaluate the gaussian
   ! No need to compute the constant term since relative likelihood is what matters
   like(i) = exp(-1.0_r8 * (x(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Prior distribution is boxcar in the central bins with 1/(n+1) density
! in each intermediate bin. BUT, distribution on the tails is a normal with
! 1/(n + 1) of the mass on each side.

! Can now compute the mean likelihood density in each interior bin
do i = 2, ens_size
   like_dense(i) = ((like(i - 1) + like(i)) / 2.0_r8)
end do

! Compute the s.d. of the ensemble for getting the gaussian tails
prior_sd = sqrt(prior_var)

! For unit normal, find distance from mean to where cdf is 1/(n+1)
! Lots of this can be done once in first call and then saved
call weighted_norm_inv(1.0_r8, 0.0_r8, 1.0_r8, &
   1.0_r8 / (ens_size + 1.0_r8), dist_for_unit_sd)
dist_for_unit_sd = -1.0_r8 * dist_for_unit_sd

! Have variance of tails just be sample prior variance
! Mean is adjusted so that 1/(n+1) is outside
left_mean = x(1) + dist_for_unit_sd * prior_sd
left_var = prior_var
left_sd = prior_sd
! Same for right tail
right_mean = x(ens_size) - dist_for_unit_sd * prior_sd
right_var = prior_var
right_sd = prior_sd

if(gaussian_likelihood_tails) then
   !*************** Block to do Gaussian-Gaussian on tail **************
   ! Compute the product of the obs likelihood gaussian with the priors 
   ! Left tail gaussian first
   var_ratio = obs_var / (left_var + obs_var)
   new_var_left = var_ratio * left_var
   new_sd_left = sqrt(new_var_left)
   new_mean_left  = var_ratio * (left_mean  + left_var*obs / obs_var)
   ! REMEMBER, this product has an associated weight which must be taken into account
   ! See Anderson and Anderson for this weight term (or tutorial kernel filter)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_left =  exp(-0.5_r8 * (left_mean**2 / left_var + &
         obs**2 / obs_var - new_mean_left**2 / new_var_left)) / &
         sqrt(left_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(1) = norm_cdf(x(1), new_mean_left, new_sd_left) * prod_weight_left

   ! Same for the right tail
   var_ratio = obs_var / (right_var + obs_var)
   new_var_right = var_ratio * right_var
   new_sd_right = sqrt(new_var_right)
   new_mean_right  = var_ratio * (right_mean  + right_var*obs / obs_var)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_right =  exp(-0.5_r8 * (right_mean**2 / right_var + &
         obs**2 / obs_var - new_mean_right**2 / new_var_right)) / &
         sqrt(right_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(ens_size + 1) = (1.0_r8 - norm_cdf(x(ens_size), new_mean_right, &
      new_sd_right)) * prod_weight_right
   !************ End Block to do Gaussian-Gaussian on tail **************
else
   !*************** Block to do flat tail for likelihood ****************
   ! Flat tails: THIS REMOVES ASSUMPTIONS ABOUT LIKELIHOOD AND CUTS COST
   new_var_left = left_var
   new_sd_left = left_sd
   new_mean_left = left_mean
   prod_weight_left = like(1)
   mass(1) = like(1) / (ens_size + 1.0_r8) 

   ! Same for right tail
   new_var_right = right_var
   new_sd_right = right_sd
   new_mean_right = right_mean
   prod_weight_right = like(ens_size)
   mass(ens_size + 1) = like(ens_size) / (ens_size + 1.0_r8)
   !*************** End block to do flat tail for likelihood ****************
endif

! The mass in each interior box is the height times the width
! The height of the likelihood is like_dense
! For the prior, mass is 1/(n+1),   and mass = height x width so...
! The height of the prior is 1 / ((n+1) width);   multiplying by width leaves 1/(n+1)

! In prior, have 1/(n+1) mass in each bin, multiply by mean likelihood density
! to get approximate mass in updated bin 
do i = 2, ens_size
   mass(i) = like_dense(i) / (ens_size + 1.0_r8)
   ! Height of prior in this bin is mass/width; Only needed for trapezoidal
   ! If two ensemble members are the same, set height to -1 as flag
   if(x(i) == x(i - 1)) then 
      height(i) = -1.0_r8
   else
      height(i) = 1.0_r8 / ((ens_size + 1.0_r8) * (x(i) - x(i-1)))
   endif
end do

! Now normalize the mass in the different bins to get a pdf
mass_sum = sum(mass)
nmass = mass / mass_sum

! Get the weight for the final normalized tail gaussians
! This is the same as left_amp=(ens_size + 1)*nmass(1)
left_amp = prod_weight_left / mass_sum
! This is the same as right_amp=(ens_size + 1)*nmass(ens_size + 1)
right_amp = prod_weight_right / mass_sum

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(0) = 0.0_r8
do i = 1, ens_size + 1
   cumul_mass(i) = cumul_mass(i - 1) + nmass(i)
end do

! Begin intenal box search at bottom of lowest box, update for efficiency
lowest_box = 1

! Find each new ensemble members location
do i = 1, ens_size
   ! Each update ensemble member has 1/(n+1) mass before it
   umass = (1.0_r8 * i) / (ens_size + 1.0_r8)

   ! If it is in the inner or outer range have to use normal
   if(umass < cumul_mass(1)) then
      ! It's in the left tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(left_amp, new_mean_left, new_sd_left, &
         umass, new_ens(i))
   else if(umass > cumul_mass(ens_size)) then
      ! It's in the right tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(right_amp, new_mean_right, new_sd_right, &
         1.0_r8 - umass, new_ens(i))
      ! Coming in from the right, use symmetry after pretending its on left
      new_ens(i) = new_mean_right + (new_mean_right - new_ens(i))
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, ens_size - 1
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then

            if(rectangular_quadrature) then
               !********* Block for rectangular quadrature *******************
               ! Linearly interpolate in mass
               new_ens(i) = x(j) + ((umass - cumul_mass(j)) / &
                  (cumul_mass(j+1) - cumul_mass(j))) * (x(j + 1) - x(j))
               !********* End block for rectangular quadrature *******************

            else

               !********* Block for trapezoidal interpolation *******************
               ! Assume that mass has linear profile, quadratic interpolation
               ! If two ensemble members are the same, just keep that value
               if(height(j + 1) < 0) then
                  new_ens(i) = x(j)
               else
                  ! Height on left side and right side
                  hleft = height(j + 1) * like(j) / mass_sum
                  hright = height(j + 1) * like(j + 1) / mass_sum
                  ! Will solve a quadratic for desired x-x(j)
                  ! a is 0.5(hright - hleft) / (x(j+1) - x(j))
                  a = 0.5_r8 * (hright - hleft) / (x(j+1) - x(j))
                  ! b is hleft
                  b = hleft
                  ! c is cumul_mass(j) - umass
                  c = cumul_mass(j) - umass
                  ! Use stable quadratic solver
                  call solve_quadratic(a, b, c, r1, r2)
                  adj_r1 = r1 + x(j)
                  adj_r2 = r2 + x(j)
                  if(adj_r1 >= x(j) .and. adj_r1 <= x(j+1)) then
                     new_ens(i) = adj_r1
                  elseif (adj_r2 >= x(j) .and. adj_r2 <= x(j+1)) then
                     new_ens(i) = adj_r2
                  else
                     errstring = 'Did not get a satisfactory quadratic root' 
                     call error_handler(E_ERR, 'obs_increment_boxcar2', errstring, &
                        source, revision, revdate)
                  endif
               endif
               !********* End block for quadratic interpolation *******************
            
            endif

            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
end do

! Convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = new_ens(i) - x(i)
end do

end subroutine obs_increment_boxcar2




subroutine update_ens_from_weights(ens, ens_size, rel_weight, ens_inc)
!------------------------------------------------------------------------
! Given relative weights for an ensemble, compute increments for the
! ensemble members. Assumes that prior distributon is equal uniform mass
! between each ensemble member. On the edges, have a normal with the
! sample mean and s.d. BUT normalized by a factor alpha so that only
! 1/(2*ens_size) of the total mass lies on each flank.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), rel_weight(ens_size)
real(r8), intent(out) :: ens_inc(ens_size)

integer  :: i, j, lowest_box
integer  :: e_ind(ens_size)
real(r8) :: x(1:2*ens_size - 1), cumul_mass(1:2*ens_size - 1), new_ens(ens_size)
real(r8) :: sort_inc(ens_size), updated_mass(2 * ens_size)
real(r8) :: sx, prior_mean, prior_var, prior_sd, mass
real(r8) :: total_mass_left, total_mass_right, alpha(2)

! Do an index sort of the ensemble members
call index_sort(ens, e_ind, ens_size)

! Have half boxes between all ensembles in the interior
! Total number of mass boxes is 2*ens_size

! Compute the points that bound all the updated mass boxes; start with ensemble
do i = 1, ens_size
   x(2*i - 1) = ens(e_ind(i))
end do
! Compute the mid-point interior boundaries; these are halfway between ensembles
do i = 2, 2*ens_size - 2, 2
   x(i) = (x(i - 1) + x(i + 1)) / 2.0_r8
end do

! Compute the mean and s.d. of the prior ensemble to handle wings
sx         = sum(ens)
prior_mean = sx / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)
prior_sd = sqrt(prior_var)

! Need to normalize the wings so they have 1/(2*ens_size) mass outside
! Use cdf to find out how much mass is left of 1st member, right of last
total_mass_left = norm_cdf(ens(e_ind(1)), prior_mean, prior_sd)
total_mass_right = 1.0_r8 - norm_cdf(ens(e_ind(ens_size)), prior_mean, prior_sd)

! Find the mass in each division given the initial equal partition and the weights
updated_mass(1) = rel_weight(e_ind(1)) / (2.0_r8 * ens_size)
updated_mass(2 * ens_size) = rel_weight(e_ind(ens_size)) / (2.0_r8 * ens_size)
do i = 2, 2*ens_size - 2, 2
   updated_mass(i) = rel_weight(e_ind(i / 2)) / (2.0_r8 * ens_size)
end do
do i = 3, 2*ens_size - 1, 2
   updated_mass(i) = rel_weight(e_ind((i+1) / 2)) / (2.0_r8 * ens_size)
end do

! Normalize the mass; (COULD IT EVER BE 0 necessitating error check?)
updated_mass = updated_mass / sum(updated_mass)

! Find a normalization factor to get tail mass right
if(total_mass_left > 0.0_r8) then
   alpha(1) = updated_mass(1) / total_mass_left
else
   alpha(1) = 0.0_r8
endif
if(total_mass_right > 0.0_r8) then
   alpha(2) = updated_mass(2 * ens_size) / total_mass_right
else
   alpha(2) = 0.0_r8
endif

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(1) = updated_mass(1)
do i = 2, 2*ens_size - 1
   cumul_mass(i) = cumul_mass(i - 1) + updated_mass(i)
end do

! Get resampled position an inefficient way
! Need 1/ens_size between each EXCEPT for outers which get half of this
mass = 1.0_r8 / (2.0_r8 * ens_size)

do i = 1, ens_size
   ! If it's in the inner or outer range have to use normal
   if(mass < cumul_mass(1)) then
      ! In the first normal box
      call weighted_norm_inv(alpha(1), prior_mean, prior_sd, mass, new_ens(i))
   else if(mass > cumul_mass(2*ens_size - 1)) then
      ! In the last normal box; Come in from the outside
      call weighted_norm_inv(alpha(2), prior_mean, prior_sd, 1.0_r8 - mass, new_ens(i))
      new_ens(i) = prior_mean + (prior_mean - new_ens(i))
   else
      ! In one of the inner uniform boxes. Make this much more efficient search?
      lowest_box = 1
      FIND_BOX:do j = lowest_box, 2 * ens_size - 2
         ! Find the box that this mass is in
         if(mass >= cumul_mass(j) .and. mass <= cumul_mass(j + 1)) then
            new_ens(i) = x(j) + ((mass - cumul_mass(j)) / (cumul_mass(j+1) - cumul_mass(j))) * &
               (x(j + 1) - x(j))
            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
   ! Want equally partitioned mass in update with exception that outermost boxes have half
   mass = mass + 1.0_r8 / ens_size
end do

! Can now compute sorted increments
do i = 1, ens_size
   sort_inc(i) = new_ens(i) - ens(e_ind(i))
end do

! Now, need to convert to increments for unsorted
do i = 1, ens_size
   ens_inc(e_ind(i)) = sort_inc(i)
end do

end subroutine update_ens_from_weights


!------------------------------------------------------------------------

function norm_cdf(x_in, mean, sd)

! Approximate cumulative distribution function for normal
! with mean and sd evaluated at point x_in
! Only works for x>= 0.

real(r8)             :: norm_cdf
real(r8), intent(in) :: x_in, mean, sd

real(digits12) :: x, p, b1, b2, b3, b4, b5, t, density, nx

! Convert to a standard normal
nx = (x_in - mean) / sd

x = abs(nx) 


! Use formula from Abramowitz and Stegun to approximate
p = 0.2316419_digits12
b1 = 0.319381530_digits12
b2 = -0.356563782_digits12
b3 = 1.781477937_digits12
b4 = -1.821255978_digits12
b5 = 1.330274429_digits12

t = 1.0_digits12 / (1.0_digits12 + p * x)

density = (1.0_digits12 / sqrt(2.0_digits12 * PI)) * exp(-x*x / 2.0_digits12)

norm_cdf = 1.0_digits12 - density * &
   ((((b5 * t + b4) * t + b3) * t + b2) * t + b1) * t

if(nx < 0.0_digits12) norm_cdf = 1.0_digits12 - norm_cdf

!write(*, *) 'cdf is ', norm_cdf

end function norm_cdf


!------------------------------------------------------------------------

subroutine weighted_norm_inv(alpha, mean, sd, p, x)

! Find the value of x for which the cdf of a N(mean, sd) multiplied times
! alpha has value p.

real(r8), intent(in)  :: alpha, mean, sd, p
real(r8), intent(out) :: x

real(r8) :: np

! Can search in a standard normal, then multiply by sd at end and add mean
! Divide p by alpha to get the right place for weighted normal
np = p / alpha

! Find spot in standard normal
call norm_inv(np, x)

! Add in the mean and normalize by sd
x = mean + x * sd

end subroutine weighted_norm_inv


!------------------------------------------------------------------------

subroutine norm_inv(p, x)

real(r8), intent(in)  :: p
real(r8), intent(out) :: x

! normal inverse
! translate from http://home.online.no/~pjacklam/notes/invnorm
! a routine written by john herrero

real(r8) :: p_low,p_high
real(r8) :: a1,a2,a3,a4,a5,a6
real(r8) :: b1,b2,b3,b4,b5
real(r8) :: c1,c2,c3,c4,c5,c6
real(r8) :: d1,d2,d3,d4
real(r8) :: q,r
a1 = -39.69683028665376_digits12
a2 =  220.9460984245205_digits12
a3 = -275.9285104469687_digits12
a4 =  138.357751867269_digits12
a5 = -30.66479806614716_digits12
a6 =  2.506628277459239_digits12
b1 = -54.4760987982241_digits12
b2 =  161.5858368580409_digits12
b3 = -155.6989798598866_digits12
b4 =  66.80131188771972_digits12
b5 = -13.28068155288572_digits12
c1 = -0.007784894002430293_digits12
c2 = -0.3223964580411365_digits12
c3 = -2.400758277161838_digits12
c4 = -2.549732539343734_digits12
c5 =  4.374664141464968_digits12
c6 =  2.938163982698783_digits12
d1 =  0.007784695709041462_digits12
d2 =  0.3224671290700398_digits12
d3 =  2.445134137142996_digits12
d4 =  3.754408661907416_digits12
p_low  = 0.02425_digits12
p_high = 1_digits12 - p_low
! Split into an inner and two outer regions which have separate fits
if(p < p_low) then
   q = sqrt(-2.0_digits12 * log(p))
   x = (((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else if(p > p_high) then
   q = sqrt(-2.0_digits12 * log(1.0_digits12 - p))
   x = -(((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else 
   q = p - 0.5_digits12
   r = q*q
   x = (((((a1*r + a2)*r + a3)*r + a4)*r + a5)*r + a6)*q / &
      (((((b1*r + b2)*r + b3)*r + b4)*r + b5)*r + 1.0_digits12)
endif

end subroutine norm_inv

!------------------------------------------------------------------------

subroutine set_assim_tools_trace(execution_level, timestamp_level)
 integer, intent(in) :: execution_level
 integer, intent(in) :: timestamp_level

! set module local vars from the calling code to indicate how much
! output we should generate from this code.  execution level is
! intended to make it easier to figure out where in the code a crash
! is happening; timestamp level is intended to help with gross levels
! of overall performance profiling.  eventually, a level of 1 will
! print out only basic info; level 2 will be more detailed.
! (right now, only > 0 prints anything and it doesn't matter how
! large the value is.)


print_trace_details = execution_level
print_timestamps    = timestamp_level

end subroutine set_assim_tools_trace

!--------------------------------------------------------------------

function revised_distance(orig_dist, newcount, oldcount, base, cutfloor)
 real(r8),            intent(in) :: orig_dist
 integer,             intent(in) :: newcount, oldcount
 type(location_type), intent(in) :: base
 real(r8),            intent(in) :: cutfloor

 real(r8)                        :: revised_distance
 
! take the ratio of the old and new counts, and revise the
! original cutoff distance to match.

! for now, only allow the code to do a 2d area adaption.
! to experiment with other schemes, set this local variable
! to .false. at the top of the file and recompile.

if (only_area_adapt) then

   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

   ! allow user to set a minimum cutoff, so even if there are very dense
   ! observations the cutoff distance won't go below this floor.
   if (revised_distance < cutfloor) revised_distance = cutfloor
   return

endif

! alternatives for different dimensionalities and schemes

! Change the cutoff radius to get the appropriate number 
if (LocationDims == 1) then
   ! linear (be careful of cyclic domains; if > domain, this is
   ! not going to be right)
   revised_distance = orig_dist * real(newcount, r8) / oldcount

else if (LocationDims == 2) then
   ! do an area scaling
   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

else if (LocationDims == 3) then
   ! do either a volume or area scaling (depending on whether we are
   ! localizing in the vertical or not.)   if surface obs, assume a hemisphere
   ! and shrink more.

   if (has_vertical_localization()) then
      ! cube root for volume
      revised_distance = orig_dist * ((real(newcount, r8) / oldcount) &
                                      ** 0.33333333333333333333_r8)

      ! Cut the adaptive localization threshold in half again for 'surface' obs
      if (vert_is_surface(base)) then
         revised_distance = revised_distance * (0.5_r8 ** 0.33333333333333333333_r8)
      endif
   else
      ! do an area scaling, even if 3d obs
      revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

      ! original code was:
      !cutoff_rev =  sqrt((2.0_r8*cutoff)**2 * adaptive_localization_threshold / &
      !   total_num_close_obs) / 2.0_r8

      ! original comment
      ! Need to get thinning out of assim_tools and into something about locations
   endif
else
   call error_handler(E_ERR, 'revised_distance', 'unknown locations dimension, not 1, 2 or 3', &
      source, revision, revdate)
endif

! allow user to set a minimum cutoff, so even if there are very dense
! observations the cutoff distance won't go below this floor.
if (revised_distance < cutfloor) revised_distance = cutfloor

end function revised_distance

!--------------------------------------------------------------------

function count_close(num_close, index_list, my_kinds, dist, maxdist)
 integer, intent(in)  :: num_close, index_list(:), my_kinds(:)
 real(r8), intent(in) :: dist(:), maxdist
 integer :: count_close

! return the total number of items from the index_list which
! are kinds which are going to be assimilated, and within distance.
! this excludes items on the eval list only, not listed, or
! items too far away.   this routine does a global communication
! so if any MPI tasks make this call, all must.

integer :: k, thiskind, local_count

local_count = 0
do k=1, num_close

   ! only accept items closer than limit
   if (dist(k) > maxdist) cycle

   ! include identity obs, plus kinds on assim list.
   ! you have to do the if tests separately because fortran allows
   ! both parts of an if(a .or. b) test to be eval'd at the same time.
   ! you'd be using a negative index if it was an identity obs.
   thiskind = my_kinds(index_list(k))
   if (thiskind < 0) then
      local_count = local_count + 1
   else if (assimilate_this_obs_kind(thiskind)) then
      local_count = local_count + 1
   endif
end do

! broadcast sums from all tasks to compute new total
call sum_across_tasks(local_count, count_close)

end function count_close

!--------------------------------------------------------------------

!========================================================================
! end module assim_tools_mod
!========================================================================

end module assim_tools_mod
