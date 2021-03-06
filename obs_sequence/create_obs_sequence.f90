! DART software - Copyright 2004 - 2011 UCAR. This open source software is
! provided by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download

program create_obs_sequence

! <next few lines under version control, do not edit>
! $URL: https://proxy.subversion.ucar.edu/DAReS/DART/releases/Kodiak/obs_sequence/create_obs_sequence.f90 $
! $Id: create_obs_sequence.f90 4933 2011-06-01 17:55:44Z thoar $
! $Revision: 4933 $
! $Date: 2011-06-01 12:55:44 -0500 (Wed, 01 Jun 2011) $

use    utilities_mod, only : timestamp, register_module, open_file, close_file, &
                             initialize_utilities 
use obs_sequence_mod, only : obs_sequence_type, interactive_obs, write_obs_seq, &
                             interactive_obs_sequence, static_init_obs_sequence
use  assim_model_mod, only : static_init_assim_model

implicit none

! version controlled file description for error handling, do not edit
character(len=128), parameter :: &
   source   = "$URL: https://proxy.subversion.ucar.edu/DAReS/DART/releases/Kodiak/obs_sequence/create_obs_sequence.f90 $", &
   revision = "$Revision: 4933 $", &
   revdate  = "$Date: 2011-06-01 12:55:44 -0500 (Wed, 01 Jun 2011) $"

type(obs_sequence_type) :: seq
character(len = 129)    :: file_name

! Record the current time, date, etc. to the logfile
call initialize_utilities('create_obs_sequence')
call register_module(source,revision,revdate)

! Initialize the assim_model module, need this to get model
! state meta data for locations of identity observations
call static_init_assim_model()

! Initialize the obs_sequence module
call static_init_obs_sequence()

! Interactive creation of an observation sequence
seq = interactive_obs_sequence()

! Write the sequence to a file
write(*, *) 'Input filename for sequence (  set_def.out   usually works well)'
read(*, *) file_name
call write_obs_seq(seq, file_name)

! Clean up
call timestamp(string1=source,string2=revision,string3=revdate,pos='end')

end program create_obs_sequence
