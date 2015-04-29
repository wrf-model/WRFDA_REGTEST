#!/usr/bin/perl -w

##################################################################
# Run multiple sequential WPS/WRF forecasts
# Designed for use with WRFDA GEN_BE utility
# Written by Michael Kavulich, April 2015
# Based on shell script by Jon Poterjoy
# Requires executable "da_advance_time.exe" from WRFDA
##################################################################
#
#
use strict;
use Time::HiRes qw(sleep gettimeofday);
use Time::localtime;
use Sys::Hostname;
use File::Copy;
use File::Path;
use File::Basename;
use File::Compare;
use IPC::Open2;
use Net::FTP;
use Getopt::Long;

#Set needed variables

 my $Start_time;
 my $tm = localtime;
 $Start_time=sprintf "Begin : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

 print "Start time: $Start_time\n";

# Basic inputs
 my $Main_dir = "/glade/p/work/kavulich/V37/";
 my $Script_dir = `pwd`;
 chomp $Script_dir;
 my $WRF_dir="$Main_dir/WRFV3";
 my $WPS_dir="$Main_dir/WPS";
 my $GRIB_dir="/glade/p/rda/data/ds083.2/grib2/2015/2015.04";   #Where to find grib input data
 my $geog_dir="/glade/p/work/wrfhelp/WPS_GEOG/";
 my $WORKDIR="$Script_dir/WORKDIR";

# Directories for running WPS/WRF and storing output
 my $Run_dir="$WORKDIR/Run/sene_hires";
 my $Out_dir="$WORKDIR/Output/sene_hires";

 mkdir $Run_dir;
 mkdir $Out_dir;

# Start and end dates
 my $initial_date="2015-04-10_00:00:00"; #Initial time for first forecast
 my $final_date="2015-04-11_00:00:00";   #Initial time for final forecast

# Set number of WPS time stamps for each cycle
 my $WPS_times=5;

# WRF parameters
 my $INPUT_INTERVAL=21600;    #WRF input interval         IN SECONDS
 my $OUT_INTERVAL=360;        #WRF output interval        IN MINUTES
 my $FC_INTERVAL=720;          #Interval between forecasts IN MINUTES
                              # Sorry about this part     ^^^^^^^^^^ 
                              #but it's necessary due to WRF namelist conventions.
 my $WRF_DT = 20;
 my @WRF_DX = ( 4000, 1000 );
 my @WEST_EAST_GRID = ( 61, 61 );
 my @SOUTH_NORTH_GRID = ( 51, 51 );
 my @VERTICAL_GRID = ( 41, 41 );
#   my NL_ETA_LEVELS=1.000000,0.998000,0.996000,0.994000,0.992000,0.990000,0.988100,0.981800,0.974000,0.966000,0.958000,0.952000,0.943400,0.920000,0.880000,0.840000,0.800000,0.760000,0.720000,0.680000,0.640000,0.600000,0.560000,0.520000,0.480000,0.440000,0.400000,0.360000,0.320000,0.280000,0.240000,0.200000,0.160000,0.140000,0.120000,0.100000,0.080000,0.060000,0.040000,0.020000,0.00000,

 my $REF_LAT=41.75;    #AKA PHIC
 my $REF_LON=-71.;     #AKA XLONC
 my $STAND_LON=-71.;
 my $TRUELAT1=30.;
 my $TRUELAT2=60.;

# WRF options
 my @MP_PHYSICS = ( 8, 8 );
 my @RA_LW_PHYSICS = ( 4, 4 );
 my @RA_SW_PHYSICS = ( 4, 4 );
 my @RADT = ( 15, 15 );
 my @SF_SFCLAY_PHYSICS = ( 1, 1);


 my $fcst_date=$initial_date;
 my $fcst_end;

#Need a subroutine to convert WRF-format dates to numbers for comparison
 sub wrf2num {
    my ($wrf_date) = @_;
    $wrf_date =~ s/\D//g;
    return $wrf_date;
 }

 while ( &wrf2num($fcst_date) <= &wrf2num($final_date) ) {

#
#      S_YEAR=`echo ${fcst_date} | cut -c1-4`
#      S_MONTH=`echo ${fcst_date} | cut -c5-6`
#      S_DAY=`echo ${fcst_date} | cut -c7-8`
#      S_HOUR=`echo ${fcst_date} | cut -c9-10`
#      S_MINUTE=00
#      S_SECOND=00
#
#      # Set end date
#      RUN_DAYS=00
#      RUN_HOURS=24
#      RUN_MINUTES=00
#      RUN_SECONDS=00
#
#      set_time $S_YEAR $S_MONTH $S_DAY $S_HOUR $S_MINUTE $S_SECOND  \
#               $RUN_DAYS $RUN_HOURS $RUN_MINUTES $RUN_SECONDS "+"
#
#      EC_YEAR="$E_YEAR"
#      EC_MONTH="$E_MONTH"
#      EC_DAY="$E_DAY"
#      EC_HOUR="$E_HOUR"
#      EC_MINUTE="$E_MINUTE"
#      EC_SECOND="$E_SECOND"
#
    print "\n==================================================\n\n";
    print "New forecast\n";
    print "  Start Time : $fcst_date\n";
    $fcst_end = `./da_advance_time.exe $fcst_date ${FC_INTERVAL}m -w`;
    chomp($fcst_end);
    print "  End Time   : $fcst_end\n";


    # Separate out the individual components of each date
    my $syear  = substr("$fcst_date", 0, 4);
    my $smonth = substr("$fcst_date", 5, 2);
    my $sday   = substr("$fcst_date", 8, 2);
    my $shour  = substr("$fcst_date", 11, 2);
    my $smin   = substr("$fcst_date", 14, 2);
    my $ssec   = substr("$fcst_date", 17);

    my $eyear  = substr("$fcst_end", 0, 4);
    my $emonth = substr("$fcst_end", 5, 2);
    my $eday   = substr("$fcst_end", 8, 2);
    my $ehour  = substr("$fcst_end", 11, 2);
    my $emin   = substr("$fcst_end", 14, 2);
    my $esec   = substr("$fcst_end", 17);
#    print "$syear $smonth $sday $shour $smin $ssec\n";


    print "Setting up working directory for forecast\n";

    rmtree("$Run_dir/$fcst_date");
    mkpath("$Run_dir/$fcst_date");
#    chdir "$Run_dir/$fcst_date";

    # Get WPS files
    ! system("cp $WPS_dir/Vtable $WPS_dir/geogrid/src/geogrid.exe $WPS_dir/ungrib/src/ungrib.exe $WPS_dir/metgrid/src/metgrid.exe $Run_dir/$fcst_date/") or die "Error copying WPS files: $!\n";

    # Get WRF files; use glob since we need everything
    my @WRF_files = glob("$WRF_dir/run/*");
    copy("$WRF_dir/run/*","$Run_dir/$fcst_date/");

    foreach my $file (@WRF_files) {
       copy("$file","$Run_dir/$fcst_date/");
    }

    chdir "$Run_dir/$fcst_date";


#      cp -rf ${wps_code}/ungrib/src/ungrib.exe ./
#      cp -rf ${wps_code}/metgrid/src/metgrid.exe ./
#      cp -rf ${wps_code}/geogrid/src/geogrid.exe ./
#      rm -r -f namelist.wps
#      rm -f *.log
#
#      # Get WRF files
#      cp -rf ${wrf_code}/run/* ./
#      rm -f wrf.exe real.exe
#      cp -rf ${wrf_code}/main/wrf.exe ./
#      cp -rf ${wrf_code}/main/real.exe ./
#      rm -r -f namelist.input
#      
#      echo '===================================='
#      echo ' Create Namelists '
#      echo '===================================='
#      echo ' '
#
#cat > namelist.wps << EOF
#&share
# wrf_core = 'ARW',
# max_dom = 1,
# start_date = '${S_YEAR}-${S_MONTH}-${S_DAY}_${S_HOUR}:${S_MINUTE}:${S_SECOND}','${S_YEAR}-${S_MONTH}-${S_DAY}_${S_HOUR}:${S_MINUTE}:${S_SECOND}',
# end_date   = '${EC_YEAR}-${EC_MONTH}-${EC_DAY}_${EC_HOUR}:${EC_MINUTE}:${EC_SECOND}','${EC_YEAR}-${EC_MONTH}-${EC_DAY}_${EC_HOUR}:${EC_MINUTE}:${EC_SECOND}',
# interval_seconds = $INTERVAL_INPUT
# io_form_geogrid = 2,
# debug_level = 0
##/
#
#&geogrid
# parent_id         =   1,   1,
# parent_grid_ratio =   1,   3,
# i_parent_start    =   1,  15,
# j_parent_start    =   1,  11,
# s_we              =   1,   1,
# e_we              =  ${WEST_EAST_GRID_NUMBER_1}, ${WEST_EAST_GRID_NUMBER_2},
# s_sn              =   1,   1,
# e_sn              =  ${SOUTH_NORTH_GRID_NUMBER_1}, ${SOUTH_NORTH_GRID_NUMBER_2},
# geog_data_res     = '2m','30s',
# dx = ${WRF_DX_1},
# dy = ${WRF_DX_1},
# map_proj = 'lambert',
# ref_lat   = $PHIC,
# ref_lon   = $XLONC,
# truelat1  = $TRUELAT1,
# truelat2  = $TRUELAT2,
# stand_lon = $STANLON,
# geog_data_path = '${geog_dir}'
# opt_geogrid_tbl_path = '${Run_dir}/${fcst_date}/geogrid/'
#/
#
#&ungrib
# out_format = 'WPS',
# prefix = 'FILE',
#/
#
#&metgrid
# fg_name = 'FILE'
# io_form_metgrid = 2, 
# opt_metgrid_tbl_path = '${Run_dir}/${fcst_date}/metgrid/',
#/
#
#&mod_levs
# press_pa = 201300 , 200100 , 100000 ,
#             97500 ,  95000 ,  92500 ,  90000 ,
#             85000 ,  80000 ,  75000 ,  70000 ,
#             65000 ,  60000 ,  55000 ,  50000 ,
#             45000 ,  40000 ,  35000 ,  30000 ,
#             25000 ,  20000 ,  15000 ,  10000 ,
#              7000 ,   5000 ,   3000 ,    2000,  1000 
#/
#
#EOF
#
#cat > namelist.input << EOF
# &time_control
# run_days                            = $RUN_DAYS,
# run_hours                           = $RUN_HOURS,
# run_minutes                         = $RUN_MINUTES,
# run_seconds                         = $RUN_SECONDS,
# start_year                          = $S_YEAR,
# start_month                         = $S_MONTH
# start_day                           = $S_DAY, 
# start_hour                          = $S_HOUR,
# start_minute                        = $S_MINUTE,
# start_second                        = $S_SECOND,
# end_year                            = $EC_YEAR, 
# end_month                           = $EC_MONTH,
# end_day                             = $EC_DAY,  
# end_hour                            = $EC_HOUR, 
# end_minute                          = $EC_MINUTE,
# end_second                          = $EC_SECOND,
# interval_seconds                    = $INTERVAL_INPUT
# input_from_file                     = .true.,
# history_interval                    = $INTERVAL_OUTPUT,
# frames_per_outfile                  = 1,
# restart                             = .false.,
# restart_interval                    = 500000,
# io_form_history                     = 2,
# io_form_restart                     = 2,
# io_form_input                       = 2,
# io_form_boundary                    = 2,
# debug_level                         = 0,
# /
#
# &domains
# time_step                           = $WRF_DT,
# time_step_fract_num                 = 0,
# time_step_fract_den                 = 1,
# max_dom                             = 1,
# e_we                                = $WEST_EAST_GRID_NUMBER_1,
# e_sn                                = $SOUTH_NORTH_GRID_NUMBER_1,
# e_vert                              = $VERTICAL_GRID_NUMBER,
# dx                                  = $WRF_DX_1,
# dy                                  = $WRF_DX_1,
#! eta_levels                          = $NL_ETA_LEVELS
# smooth_option                       = 1,
# p_top_requested                     = 5000,
# num_metgrid_levels                  = 27,
# num_metgrid_soil_levels             = 4,
# grid_id                             = 1,
# parent_id                           = 0,
# i_parent_start                      = 1,
# j_parent_start                      = 1,
# parent_grid_ratio                   = 1,
# parent_time_step_ratio              = 1,
# feedback                            = 1,
# interp_type                         = 1,
# t_extrap_type                       = 1,
# force_sfc_in_vinterp                = 3,
# adjust_heights                      = .false.,
#  /
#
# &physics
# mp_physics                          = $MP_PHYSICS,
# ra_lw_physics                       = $RA_LW_PHYSICS,
# ra_sw_physics                       = $RA_SW_PHYSICS,
# radt                                = $RADT,
# sf_sfclay_physics                   = $SF_SFCLAY_PHYSICS,
# sf_surface_physics                  = 1,
# bl_pbl_physics                      = 1,
# bldt                                = 0,
# cu_physics                          = 1,
# cudt                                = 5,
# isfflx                              = 1,
# ifsnow                              = 1,
# icloud                              = 1,
# surface_input_source                = 1,
# num_soil_layers                     = 5,
# sf_urban_physics                    = 0,
# /
#
# &fdda
# /
#
# &dynamics
# w_damping                           = 1,
# diff_opt                            = 1,
# km_opt                              = 4,
# diff_6th_opt                        = 0,
# diff_6th_factor                     = 0.12,
# base_temp                           = 290.
# damp_opt                            = 0,
# zdamp                               = 5000.,
# dampcoef                            = 0.01,
# khdif                               = 0,
# kvdif                               = 0,
# non_hydrostatic                     = .true.,
# moist_adv_opt                       = 1,
# scalar_adv_opt                      = 1,
# /
#
# &bdy_control
# spec_bdy_width                      = 5,
# spec_zone                           = 1,
# relax_zone                          = 4,
# specified                           = .true.,
# nested                              = .false.,
# /
#
# &grib2
# /
#
# &namelist_quilt
# nio_tasks_per_group = 0,
# nio_groups = 1,
# /
#
#
#EOF
#
#      echo '===================================='
#      echo ' Link FNL data '
#      echo '===================================='
#      echo ' '
## link fnl gridded data
#      S1_YEAR="$S_YEAR"
#      S1_MONTH="$S_MONTH"
#      S1_DAY="$S_DAY"
#      S1_HOUR="$S_HOUR"
#      S1_MINUTE="$S_MINUTE"
#      S1_SECOND="$S_SECOND"
#
#      INT_DAYS=00
#      INT_HOURS=06
#      INT_MINUTES=00
#      INT_SECONDS=00
#
#      NT=1
#      while [ ${NT} -le ${fnl_times} ]; do     # link fnl data for IC and BC
#         ln -fs ${gfs_dir}/fnl_${S1_YEAR}${S1_MONTH}${S1_DAY}_${S1_HOUR}_00* .
#         set_time $S1_YEAR $S1_MONTH $S1_DAY $S1_HOUR $S1_MINUTE $S1_SECOND  \
#                $INT_DAYS $INT_HOURS $INT_MINUTES $INT_SECONDS "+"
#
#         E1_YEAR="$E_YEAR"
#         E1_MONTH="$E_MONTH"
#         E1_DAY="$E_DAY"
#         E1_HOUR="$E_HOUR"
#         E1_MINUTE="$E_MINUTE"
#         E1_SECOND="$E_SECOND"
#         S1_YEAR="$E1_YEAR"
#         S1_MONTH="$E1_MONTH"
#         S1_DAY="$E1_DAY"
#         S1_HOUR="$E1_HOUR"
#         S1_MINUTE="$E1_MINUTE"
#         S1_SECOND="$E1_SECOND"
#         let "NT += 1"
#      done
#
#      echo '===================================='
#      echo ' Run WPS '
#      echo '===================================='
#      echo ' '
#
#cat > ${Run_dir}/${fcst_date}/run_wps.sh  << EOF
##!/bin/bash
##
##$ -V
##$ -cwd
##$ -N run_wps_${fcst_date}
##$ -e run_wps_${fcst_date}.e
##$ -o run_wps_${fcst_date}.o
##$ -j y
##$ -sync y
##$ -A TG-ATM090042
##$ -pe 16way 16
##$ -q serial
##$ -l h_rt=12:00:00
#
#   cd ${Run_dir}/${fcst_date}
#
#   ./geogrid.exe >& geogrid.log
#   wait
#   echo "geogrid.exe complete"
#
#   ln -sf ${Run_dir}/${fcst_date}/ungrib/Variable_Tables/Vtable.GFS ${Run_dir}/${fcst_date}/Vtable
#   link_grib.csh ./fnl_*
#
#   ./ungrib.exe >& ungrib.log
#   wait
#   echo "ungrib.exe complete"
#
#   ./metgrid.exe >& metgrid.log
#   wait
#   echo "metgrid.exe complete"
#
#   mpirun -np 4 real.exe >& real.log
#   wait
#   echo "real.exe complete"
#EOF
#
#
#      chmod +x run_wps.sh
#      run_wps.sh
#      wait
#
#mv rsl.out.0000 rsl.out.0000_real
#mv rsl.out.0001 rsl.out.0001_real
#mv rsl.out.0002 rsl.out.0002_real
#mv rsl.out.0003 rsl.out.0003_real
#mv rsl.error.0000 rsl.error.0000_real
#mv rsl.error.0001 rsl.error.0001_real
#mv rsl.error.0002 rsl.error.0002_real
#mv rsl.error.0003 rsl.error.0003_real
#
#
#      echo '===================================='
#      echo ' Run WRF '
#      echo '===================================='
#      echo ' '
#
#cat > ${Run_dir}/${fcst_date}/run_wrf.sh  << EOF
##!/bin/bash
##
##$ -V
##$ -cwd
##$ -N wrf_${fcst_date}
##$ -e wrf_${fcst_date}.e
##$ -o wrf_${fcst_date}.o
##$ -j y
##$ -sync y
##$ -A TG-ATM090042
##$ -pe 16way 128
##$ -q normal
##$ -l h_rt=2:00:00
#
#cd ${Run_dir}/${fcst_date}
#mpirun -n 6 wrf.exe > print_wrf.log
#wait 
#echo "wrf.exe complete"
#EOF
#      
#      rm -f rsl*
#      chmod +x run_wrf.sh
#      run_wrf.sh &
#      wait
#
#      # Copy forecasts to output directory
#      mkdir -p ${out_dir}/${fcst_date}
#      cp ${Run_dir}/${fcst_date}/wrfout_d0* ${out_dir}/${fcst_date}/
#
#      my fcst_date=`${script_dir}/da_advance_time.exe ${fcst_date} ${INTERVAL}h`
#
##      mv ${Run_dir}/${fcst_date}/wrfout_d01_${S_YEAR}-${S_MONTH}-${S_DAY}_${S_HOUR}:${S_MINUTE}:${S_SECOND} ${out_dir}/${fcst_date}
#      
##      set_time $S_YEAR $S_MONTH $S_DAY $S_HOUR $S_MINUTE $S_SECOND  \
##               00 12 00 00 "-"
#
##      E1_YEAR="$E_YEAR"
##      E1_MONTH="$E_MONTH"
##      E1_DAY="$E_DAY"
##      E1_HOUR="$E_HOUR"
##      E1_MINUTE="$E_MINUTE"
##      E1_SECOND="$E_SECOND"
#
##      mv ${Run_dir}/${fcst_date}/wrfout_d01_${E1_YEAR}-${E1_MONTH}-${E1_DAY}_${E1_HOUR}:${E1_MINUTE}:${E1_SECOND} ${out_dir}/${fcst_date}
##      fcst_date="${E1_YEAR}${E1_MONTH}${E1_DAY}${E1_HOUR}"
#
#

#    $fcst_date = `./da_advance_time.exe ${fcst_date} ${FC_INTERVAL}h -w`;
    chdir $Script_dir;
    $fcst_date = $fcst_end;

    print "New forecast date: $fcst_date\n";
 } # End while loop


 print "\nScript finished!\n";
 my $Finish_time;
 $tm = localtime;
 $Finish_time=sprintf "Begin : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

 print "Finish time: $Finish_time\n";

