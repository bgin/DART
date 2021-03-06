#!/bin/csh
#
# DART software - Copyright 2004 - 2011 UCAR. This open source software is
# provided by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
# $Id: 3dvar-covar_BC.csh 4945 2011-06-02 22:29:30Z thoar $
#
# Purpose: Given a first guess ensemble mean, generate ensemble members
#          from wrf/3dvar covariances.

set echo

#--------------------------------------------
# 0) Set up various environment variables:
#--------------------------------------------

setenv NCYCLE 4                              # Number of assimilation cycles.
setenv FCST_RANGE 6                           # Forecast range (hours).
set ES = 84

set seconds = 0
set days = 146827

set infl = 1.0

# End of user modifications.

setenv FCST_RANGE_SEC `expr $FCST_RANGE \* 3600`
set seconds = `expr $seconds \+ $FCST_RANGE_SEC`
if ( $seconds >= 86400) then
   set seconds = `expr $seconds \- 86400`
   set days = `expr $days \+ 1`
endif

cp wrfinput_d01 wrf_3dvar_input

set SEED1 = 1
set ICYC = 1
# Loop over cycles
while ( $ICYC <= $NCYCLE )

   set NC = 1
# Loop over the ensemble members
   while ( $NC <= $ES )

   cp ../wrfbdy_mean_${days}_${seconds} wrfbdy_d01

@ SEED2 = ${SEED1} * 100

rm -f script.sed
cat > script.sed << EOF
 s/SEED1/${SEED1}/
 s/SEED2/${SEED2}/
EOF

 sed -f script.sed \
    namelist.3dvar.template > namelist.3dvar

      ./da_3dvar.exe >& da_3dvar.out_${days}_${seconds}_${NC}

      mv wrf_3dvar_output wrfinput_mean

      echo $infl | ./update_wrf_bc.exe >& out.update_wrf_bc_${days}_${seconds}_${NC}

      mv wrfbdy_d01 wrfbdy_${days}_${seconds}_${NC}

      @ NC ++

      @ SEED1 ++

   end

   @ ICYC ++

set seconds = `expr $seconds \+ $FCST_RANGE_SEC`
if ( $seconds >= 86400) then
   set seconds = `expr $seconds \- 86400`
   set days = `expr $days \+ 1`
endif

end

exit 0

# <next few lines under version control, do not edit>
# $URL: https://proxy.subversion.ucar.edu/DAReS/DART/releases/Kodiak/models/wrf/shell_scripts/3dvar-covar_BC.csh $
# $Revision: 4945 $
# $Date: 2011-06-02 17:29:30 -0500 (Thu, 02 Jun 2011) $

