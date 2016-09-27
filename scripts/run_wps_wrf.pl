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
 my $Main_dir = "/glade/p/work/kavulich/V38";
 my $Script_dir = `pwd`;
 chomp $Script_dir;
 my $WRF_dir="$Main_dir/WRFV3";
 my $WPS_dir="$Main_dir/WPS";
 my @GRIB_dir;
# $GRIB_dir[0]="/glade/p/rda/data/ds609.0/2015/";   #Where to find grib input data
#If your forecasts span multiple months, put the subsequent directory names in subsequent array values. Should work for indefinitely long runs
 $GRIB_dir[0]="/glade/p/rda/data/ds083.2/grib2/2016/2016.05";
 $GRIB_dir[1]="/glade/p/rda/data/ds083.2/grib2/2015/2015.12";
 my $Data_type = "FNL"; # Valid choices: FNL, NAM

 my $geog_dir="/glade/p/work/wrfhelp/WPS_GEOG/";
 my $alt_Vtable=""; #Set this if you are not using GFS/FNL data, or want to do something strange
# my $alt_Vtable="$WPS_dir/ungrib/Variable_Tables/Vtable.GFS";
# my $alt_Vtable="/glade/p/work/kavulich/V371/WPS/ungrib/Variable_Tables/Vtable.GFS";
 my $WORKDIR="/glade/scratch/kavulich/GEN_BE_FORECASTS";

# Directories for running WPS/WRF and storing output
 my $Case_name="hawaii_gpsztd";
 my $Run_dir="$WORKDIR/Run/$Case_name";
 my $Out_dir="$WORKDIR/Output/$Case_name";

# Start and end dates
 my $initial_date="2008-02-01_00:00:00"; #Initial time for first forecast
 my $final_date="2008-03-01_00:00:00";   #Initial time for final forecast

# Set number of WPS time stamps for each cycle
 my $WPS_times=3;
 my $run_wps=0;  # Set to 0 to skip WPS step
 my $run_real=1; # Set to 0 to skip real.ext step
 my $run_wrf=1;  # Set to 0 to skip WRF step

# real.exe parameters
 my $NUM_METGRID_LEVELS=32; #GFS Default 27 (upped to 32 in April 2016); NAM default 40
 my $NUM_METGRID_SOIL_LEVELS=4; #GFS Default "4"; prior to early 2005 it was "2"

# WRF/WPS parameters
 my $METEM_INTERVAL=21600;   #WPS output interval               IN SECONDS
 my $OUT_INTERVAL=720;       #WRF output interval               IN MINUTES
 my $FC_INTERVAL=720;        #Interval between forecasts        IN MINUTES
 my $GRIB_INTERVAL=6;        #WPS GRIB input interval           IN HOURS
                             # I'm so, so sorry about this part ^^^^^^^^^^ 
                             # but it's necessary due to WPS/WRF namelist conventions
 my $RUN_DAYS = 0;           # Don't make this a month or longer or bad things will happen!
 my $RUN_HOURS = 6;
 my $RUN_MINUTES = 0;
 my $NUM_DOMAINS = 1; #For NUM_DOMAINS > 1, be sure that the appropriate variables are all set for all domains below!
 my $WRF_DT = 360;
 my @WRF_DX = ( 60000, 20000 );
 my @WEST_EAST_GRID = ( 90, 220 );
 my @SOUTH_NORTH_GRID = ( 60, 151 );
 my @VERTICAL_GRID = ( 41, 41 );
 my @PARENT_GRID_RATIO = ( 1, 3 );
 my @I_PARENT_START = ( 1, 71 );
 my @J_PARENT_START = ( 1, 125 );
# my $NL_ETA_LEVELS="1.000 0.9880 0.9765 0.9620 0.9440 0.9215 0.8945 0.8587 0.8161 0.7735 0.7309 0.6724 0.6010 0.5358 0.4763 0.4222 0.3730 0.3283 0.2878 0.2512 0.2182 0.1885 0.1619 0.1380 0.1166 0.0977 0.0808 0.0659 0.0528 0.0412 0.0312 0.0224 0.0148 0.0083 0.0026 0.0000";
# my $NL_ETA_LEVELS="1.000000,0.998000,0.996000,0.994000,0.992000,0.990000,0.988100,0.981800,0.974000,0.966000,0.958000,0.952000,0.943400,0.920000,0.880000,0.840000,0.800000,0.760000,0.720000,0.680000,0.640000,0.600000,0.560000,0.520000,0.480000,0.440000,0.400000,0.360000,0.320000,0.280000,0.240000,0.200000,0.160000,0.140000,0.120000,0.100000,0.080000,0.060000,0.040000,0.020000,0.00000";
 my $MAP_PROJ="lambert"; #"lambert", "polar", etc.
 my $REF_LAT=40.00001;    #AKA PHIC AKA CEN_LAT
 my $REF_LON=-95.;     #AKA XLONC AKA CEN_LON
 my $STAND_LON=-95.;
 my $TRUELAT1=40.;
 my $TRUELAT2=0.;
 my $POLE_LAT=90.;
 my $POLE_LON=0.;

# WRF options
 my @PARENT_TIME_STEP_RATIO = ( 1, 3 );
 my @MP_PHYSICS = ( 3, 4 );
 my @RA_LW_PHYSICS = ( 1, 24 );
 my @RA_SW_PHYSICS = ( 1, 24 );
 my $RADT = 60;
 my @SF_SFCLAY_PHYSICS = ( 1, 1);
 my @SF_SURFACE_PHYSICS = ( 1, 2);
 my @BL_PBL_PHYSICS = ( 1, 1);
 my @CU_PHYSICS = ( 1, 1);
 my $PTOP = 3000;

# Job submission options
 my $MAX_JOBS = 50;
 my $NUM_PROCS = 64;
 my $NUM_PROCS_REAL = 1;
 my $JOBQUEUE = "regular";
 my $JOBQUEUE_REAL = "caldera";
 my $PROJECT = "P64000400";


############################################
#   Only options above should be edited!   #
############################################

# Check there are no problem values
 if (($NUM_PROCS_REAL > 16) and ($JOBQUEUE_REAL eq "caldera"))
     { die "\nERROR ERROR ERROR\nCaldera queue has a max NUM_PROCS of 16\nYou specified NUM_PROCS_REAL = $NUM_PROCS_REAL\nERROR ERROR ERROR\n\n"};
 if (($NUM_PROCS > 16) and ($JOBQUEUE eq "caldera")) 
     { die "\nERROR ERROR ERROR\nCaldera queue has a max NUM_PROCS of 16\nYou specified NUM_PROCS = $NUM_PROCS\nERROR ERROR ERROR\n\n"};

# If old data exists, ask to overwrite
 if (-d $Out_dir) {
    my $go_on='';
    print "$Out_dir already exists, do you want to risk overwriting old data?\a\n";
    while ($go_on eq "") {
       $go_on = <STDIN>;
       chop($go_on);
       if ($go_on =~ /N/i) {
          die "Choose another value for \$Out_dir.\n";
       } elsif ($go_on =~ /Y/i) {
       } else {
          print "Invalid input: ".$go_on;
          $go_on='';
       }
    }
 }

 mkdir $Run_dir;
 mkdir $Out_dir;

# Remove old FAIL file if it exists
 unlink "FAIL";

 my $fcst_date=$initial_date;
 my $job_feedback; #For getting feedback from bsub
 my $jobid;        #For making sure we submit jobs in the right order


 my $monthnum = 0; #For multi-month runs, keep track of which month we're in
 my $straddle = 0; #For forecasts which straddle two months, we'll set this flag. You'll see why below

 while ( &wrf2num($fcst_date) <= &wrf2num($final_date) ) {
    &run_checks; #Run failure and job number checks before starting new forecast

    #Start new forecast
    print "\n==================================================\n\n";
    print "New forecast\n";
    print "  Start Time : $fcst_date\n";
    my $fcst_end = `./da_advance_time.exe $fcst_date ${RUN_DAYS}d${RUN_HOURS}h${RUN_MINUTES}m -w`;
    chomp($fcst_end);
    print "  End Time   : $fcst_end\n";

    # Separate out the individual components of each date
    my $syear  = substr("$fcst_date", 0, 4) or die "Invalid start date format!\n";
    my $smonth = substr("$fcst_date", 5, 2);
    my $sday   = substr("$fcst_date", 8, 2);
    my $shour  = substr("$fcst_date", 11, 2);
    my $smin   = substr("$fcst_date", 14, 2);
    my $ssec   = substr("$fcst_date", 17);

    my $eyear  = substr("$fcst_end", 0, 4) or die "Invalid end date format!\n";
    my $emonth = substr("$fcst_end", 5, 2);
    my $eday   = substr("$fcst_end", 8, 2);
    my $ehour  = substr("$fcst_end", 11, 2);
    my $emin   = substr("$fcst_end", 14, 2);
    my $esec   = substr("$fcst_end", 17);

    print "Setting up working directory for forecast:\n$Run_dir/$fcst_date\n\n";

    my $fcst_dirname = substr(&wrf2num($fcst_date),0,10);

    unless ($run_wps == 0) {
       rmtree("$Run_dir/$fcst_date");
       mkpath("$Run_dir/$fcst_date");

       # Get WPS files
       ! system("cp $WPS_dir/link_grib.csh $WPS_dir/geogrid/src/geogrid.exe $WPS_dir/ungrib/src/ungrib.exe $WPS_dir/metgrid/src/metgrid.exe $Run_dir/$fcst_date/") or die "Error copying WPS files: $!\n";

       if ($alt_Vtable ne "") {
          print "Using alternate Vtable: $alt_Vtable\n";
          copy ("$alt_Vtable","$Run_dir/$fcst_date/Vtable");
       } else {
          if ($Data_type eq "FNL") {
             print "Using standard $Data_type Vtable: $WPS_dir/ungrib/Variable_Tables/Vtable.GFS\n";
             copy ("$WPS_dir/ungrib/Variable_Tables/Vtable.GFS","$Run_dir/$fcst_date/Vtable");
          } elsif ($Data_type eq "NAM") {
             print "Using standard $Data_type Vtable: $WPS_dir/ungrib/Variable_Tables/Vtable.NAM\n";
             copy ("$WPS_dir/ungrib/Variable_Tables/Vtable.NAM","$Run_dir/$fcst_date/Vtable");
          }
       }
    }

    unless ($run_wrf == 0) {
       # Get WRF files; use glob since we need everything
       my @WRF_files = glob("$WRF_dir/run/*");
       copy ("$WRF_dir/run/*","$Run_dir/$fcst_date/");

       foreach my $file (@WRF_files) {
          copy("$file","$Run_dir/$fcst_date/");
       }
    }

    chdir "$Run_dir/$fcst_date";
    unlink "namelist.wps" unless ($run_wps == 0);
    unlink "namelist.input" unless ( ($run_real == 0) and ($run_wrf == 0) );
    unless ($run_real == 0) {
       chmod 0755, "real.exe" or die "Couldn't change the permission to real.exe: $!";
    }
    unless ($run_wrf == 0) {
       chmod 0755, "wrf.exe" or die "Couldn't change the permission to wrf.exe: $!";
    }

    #Create namelists
    print "Creating namelists\n";

# WPS NAMELIST
    unless ($run_wps == 0) {
       open NL, ">namelist.wps" or die "Can not open namelist.wps for writing: $! \n";
       print NL "&share\n";
       print NL "wrf_core = 'ARW',\n";
       print NL " max_dom = $NUM_DOMAINS,\n";
       print NL " start_date = '$fcst_date','$fcst_date',\n";
       print NL " end_date   = '$fcst_end','$fcst_end',\n";
       print NL " interval_seconds = $METEM_INTERVAL\n";
       print NL " io_form_geogrid = 2,\n";
       print NL " debug_level = 0\n";
#       print NL " nocolons                 = true,\n";
       print NL "/\n";
       print NL "&geogrid\n";
       print NL " parent_id         =   1,   1,\n";
       print NL " parent_grid_ratio =   $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
       print NL " i_parent_start    =   $I_PARENT_START[0],  $I_PARENT_START[1],\n";
       print NL " j_parent_start    =   $J_PARENT_START[0],  $J_PARENT_START[1],\n";
       print NL " e_we              =  $WEST_EAST_GRID[0], $WEST_EAST_GRID[1],\n";
       print NL " e_sn              =  $SOUTH_NORTH_GRID[0], $SOUTH_NORTH_GRID[1],\n";
       print NL " geog_data_res     = '2m','30s',\n";
       print NL " dx = $WRF_DX[0],\n";
       print NL " dy = $WRF_DX[0],\n";
       print NL " map_proj = '$MAP_PROJ',\n";
       print NL " ref_lat   = $REF_LAT,\n";
       print NL " ref_lon   = $REF_LON,\n";
       print NL " truelat1  = $TRUELAT1,\n";
       print NL " truelat2  = $TRUELAT2,\n";
       print NL " stand_lon = $STAND_LON,\n";
       print NL " geog_data_path = '$geog_dir'\n";
       print NL " opt_geogrid_tbl_path = '$WPS_dir/geogrid/'\n";
       print NL "/\n";
       print NL "&ungrib\n";
       print NL " out_format = 'WPS',\n";
       print NL " prefix = 'FILE',\n";
       print NL "/\n";
       print NL "&metgrid\n";
       print NL " fg_name = 'FILE'\n";
       print NL " io_form_metgrid = 2, \n";
       print NL " opt_metgrid_tbl_path = '$WPS_dir/metgrid/',\n";
       print NL "/\n";
       close NL;
    }

# WRF NAMELIST
    unless ( ($run_real == 0) and ($run_wrf == 0) ) {
       open NL, ">namelist.input" or die "Can not open namelist.input for writing: $! \n";
       print NL "&time_control\n";
       print NL " run_days                 = $RUN_DAYS,\n";
       print NL " run_hours                = $RUN_HOURS,\n";
       print NL " run_minutes              = $RUN_MINUTES,\n";
       print NL " run_seconds              = 0,\n";
       print NL " start_year               = $syear,$syear\n";
       print NL " start_month              = $smonth,$smonth\n";
       print NL " start_day                = $sday,$sday\n";
       print NL " start_hour               = $shour,$shour\n";
       print NL " start_minute             = $smin,$smin\n";
       print NL " start_second             = $ssec,$ssec\n";
       print NL " end_year                 = $eyear,$eyear\n";
       print NL " end_month                = $emonth,$emonth\n";
       print NL " end_day                  = $eday,$eday\n";
       print NL " end_hour                 = $ehour,$ehour\n";
       print NL " end_minute               = $emin,$emin\n";
       print NL " end_second               = $esec,$esec\n";
       print NL " interval_seconds         = $METEM_INTERVAL,\n";
       print NL " history_interval         = $OUT_INTERVAL,$OUT_INTERVAL\n";
       print NL " input_from_file          = .true.,.true.,.true.,\n";
       print NL " frames_per_outfile       = 1,1,\n";
       print NL " restart                  = .false.,\n";
       print NL " restart_interval         = 500000,\n";
       print NL " debug_level              = 0,\n";
#       print NL " nocolons                 = true,\n";
       print NL "/\n";
       print NL "&domains\n";
       print NL " time_step                = $WRF_DT,\n";
       print NL " max_dom                  = $NUM_DOMAINS,\n";
       print NL " parent_time_step_ratio   = $PARENT_TIME_STEP_RATIO[0], $PARENT_TIME_STEP_RATIO[1],\n";
       print NL " e_we                     = $WEST_EAST_GRID[0], $WEST_EAST_GRID[1],\n";
       print NL " e_sn                     = $SOUTH_NORTH_GRID[0], $SOUTH_NORTH_GRID[1],\n";
       print NL " e_vert                   = $VERTICAL_GRID[0], $VERTICAL_GRID[1],\n";
       print NL " dx                       = $WRF_DX[0],$WRF_DX[1],\n";
       print NL " dy                       = $WRF_DX[0],$WRF_DX[1],\n";
#       print NL " eta_levels               = $NL_ETA_LEVELS\n";
       print NL " smooth_option            = 1,\n";
       print NL " p_top_requested          = $PTOP\n";
       print NL " num_metgrid_levels       = $NUM_METGRID_LEVELS,\n";
       print NL " num_metgrid_soil_levels  = $NUM_METGRID_SOIL_LEVELS,\n";
       print NL " grid_id                  = 1, 2,\n";
       print NL " parent_id                = 0, 1,\n";
       print NL " i_parent_start           = $I_PARENT_START[0],  $I_PARENT_START[1],\n";
       print NL " j_parent_start           = $J_PARENT_START[0],  $J_PARENT_START[1],\n";
       print NL " parent_grid_ratio        = $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
       print NL " parent_time_step_ratio   = $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
       print NL " feedback                 = 1,\n";
       print NL "/\n";
       print NL "&physics\n";
       print NL " mp_physics               = $MP_PHYSICS[0], $MP_PHYSICS[1],\n";
       print NL " ra_lw_physics            = $RA_LW_PHYSICS[0], $RA_LW_PHYSICS[1],\n";
       print NL " ra_sw_physics            = $RA_SW_PHYSICS[0], $RA_SW_PHYSICS[1],\n";
       print NL " radt                     = $RADT, $RADT,\n";
       print NL " sf_sfclay_physics        = $SF_SFCLAY_PHYSICS[0], $SF_SFCLAY_PHYSICS[1],\n";
       print NL " sf_surface_physics       = $SF_SURFACE_PHYSICS[0], $SF_SURFACE_PHYSICS[1],\n";
       print NL " bl_pbl_physics           = $BL_PBL_PHYSICS[0], $BL_PBL_PHYSICS[1],\n";
       print NL " bldt                     = 0,\n";
       print NL " cu_physics               = $CU_PHYSICS[0], $CU_PHYSICS[1],\n";
       print NL " cudt                     = 5,\n";
       print NL " isfflx                   = 1,\n";
       print NL " ifsnow                   = 1,\n";
       print NL " icloud                   = 1,\n";
       print NL " surface_input_source     = 1,\n";
       print NL " num_soil_layers          = 5,\n";
       print NL " sf_urban_physics         = 0,\n";
       print NL "/\n";
       print NL "&dynamics\n";
       print NL " w_damping                = 1,\n";
       print NL " diff_opt                 = 1,\n";
       print NL " km_opt                   = 4,\n";
       print NL " diff_6th_opt             = 0,\n";
       print NL " diff_6th_factor          = 0.12,\n";
       print NL " base_temp                = 290.\n";
       print NL " damp_opt                 = 0,\n";
       print NL " zdamp                    = 5000.,\n";
       print NL " dampcoef                 = 0.01,\n";
       print NL " khdif                    = 0,\n";
       print NL " kvdif                    = 0,\n";
       print NL " non_hydrostatic          = .true.,\n";
       print NL " moist_adv_opt            = 1,\n";
       print NL " scalar_adv_opt           = 1,\n";
       print NL "/\n";
       print NL "&bdy_control\n";
       print NL " spec_bdy_width           = 5,\n";
       print NL " spec_zone                = 1,\n";
       print NL " relax_zone               = 4,\n";
       print NL " specified                = .true., .false.,.false.,\n";
       print NL " nested                   = .false., .true., .true.,\n";
       print NL "/\n";
       print NL "&namelist_quilt\n";
       print NL " nio_tasks_per_group      = 0,\n";
       print NL " nio_groups               = 1,\n";
       print NL "/\n";
       close NL;
    }


    #Link GRIB data
    if ($run_wps == 0) {
       print "NOT running WPS\n";
    } else {
       print "Linking input data\n";

       my $grib_date = $fcst_date;
       if ($smonth == $emonth) {
          if ($straddle == 1) { #If start month and end month are the same and straddle == 1, that means we've fully entered the next month
             $monthnum ++;
             $straddle = 0;
          }
       } else {
          $straddle = 1;
       }

       &getgribfiles($grib_date, $fcst_end, $smonth );

   # RUN WPS

       print "Creating WPS job\n";

       open FH, ">run_wps.csh" or die "Can not open run_wps.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J ${syear}-${smonth}-${sday}-${shour}zWPS"."\n";
       print FH "#BSUB -q caldera\n";
       print FH "#BSUB -n 1\n";
       print FH "#BSUB -o run_wps.output\n";
       print FH "#BSUB -e run_wps.error\n";
       print FH "#BSUB -W 10"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=1]\n";
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "./geogrid.exe\n";
       print FH "./link_grib.csh grib_*\n";
       print FH "./ungrib.exe\n";
       print FH "./metgrid.exe\n";
       print FH "if ( (!(-e 'met_em.d01.$fcst_end.nc')) && (!(-e '$Script_dir/FAIL')) ) then\n";
       print FH "   echo 'WPS failure in $Run_dir/$fcst_date' > $Script_dir/FAIL\n";
       print FH "endif\n";
       close FH ;

       $job_feedback = ` bsub < run_wps.csh `;
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WPS job for $fcst_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }
    }

    if ($run_real == 0) {
       print "NOT running real.exe\n";
    } else {
       print "Creating real.exe job\n";

       open FH, ">run_real.csh" or die "Can not open run_real.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J ${syear}-${smonth}-${sday}-${shour}zREAL\n";
       print FH "#BSUB -q $JOBQUEUE_REAL\n";
       print FH "#BSUB -n $NUM_PROCS_REAL\n";
       print FH "#BSUB -o run_real.output"."\n";
       print FH "#BSUB -e run_real.error"."\n";
       print FH "#BSUB -W 10"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=%d]"."\n", ($NUM_PROCS_REAL < 16 ) ? $NUM_PROCS_REAL : 16;
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE_REAL =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "mpirun.lsf ./real.exe\n";
       print FH "if ( (!(-e 'wrfinput_d01')) && (!(-e '$Script_dir/FAIL')) ) then\n";
       print FH "   echo 'real.exe failure in $Run_dir/$fcst_date' > $Script_dir/FAIL\n";
       print FH "endif\n";
       close FH ;

       if ($run_wps == 0) {
          $job_feedback = ` bsub < run_real.csh `;
       } else {
          $job_feedback = ` bsub -w "ended($jobid)" < run_real.csh `;
       }
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit real.exe job for $fcst_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }
    }

    if ($run_wrf == 0) {
       print "NOT running WRF\n";
    } else {
       print "Creating WRF job\n";

       open FH, ">run_wrf.csh" or die "Can not open run_wrf.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J ${syear}-${smonth}-${sday}-${shour}zWRF\n";
       print FH "#BSUB -q $JOBQUEUE\n";
       print FH "#BSUB -n $NUM_PROCS\n";
       print FH "#BSUB -o run_wrf.output"."\n";
       print FH "#BSUB -e run_wrf.error"."\n";
       print FH "#BSUB -W 60"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=%d]"."\n", ($NUM_PROCS < 16 ) ? $NUM_PROCS : 16;
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "mkdir real_rsl\n";
       print FH "mv rsl* real_rsl/\n";
       print FH "mpirun.lsf ./wrf.exe\n";
       print FH "if ( (!(-e 'wrfout_d01_$fcst_end')) && (!(-e '$Script_dir/FAIL')) ) then\n";
       print FH "   echo 'WRF failure in $Run_dir/$fcst_date' > $Script_dir/FAIL\n";
       print FH "endif\n";
       print FH "mkdir -p $Out_dir/$fcst_dirname\n";
       print FH "\\cp $Run_dir/$fcst_date/wrfout_d0* $Out_dir/$fcst_dirname/\n";
       close FH ;

       if ( ($run_wps == 0) and ($run_real == 0) ) {
          $job_feedback = ` bsub < run_wrf.csh`;
       } else {
          $job_feedback = ` bsub -w "ended($jobid)" < run_wrf.csh`;
       }
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRF job for $fcst_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }
    }

    chdir $Script_dir;

    #Advance to next forecast date
    $fcst_date = `./da_advance_time.exe $fcst_date ${FC_INTERVAL}m -w`;
    chomp($fcst_date);

    print "New forecast date: $fcst_date\n";
 } # End while loop

 copy($0,$Out_dir); #Keep a copy of this script with these settings for future reference.

 print "\nScript finished!\n";
 my $Finish_time;
 $tm = localtime;
 $Finish_time=sprintf "End : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

 print "$Finish_time\n";




# SUBROUTINES

 sub getgribfiles {

    my ($date, $fcst_end, $smonth) = @_;

    while ( &wrf2num($date) <= &wrf2num($fcst_end) ) {
       my $gribyear  = substr("$date", 0, 4);
       my $gribmonth = substr("$date", 5, 2);
       my $gribday   = substr("$date", 8, 2);
       my $gribhour  = substr("$date", 11, 2);

       my @grib_file;

       if ($Data_type eq "FNL") {
          if ($straddle == 1) {
             my $monthnumplus = $monthnum + 1;
             if ($gribmonth == $smonth) {
                @grib_file = glob("$GRIB_dir[$monthnum]/fnl_$gribyear$gribmonth$gribday\_$gribhour*grib*");
             } else {
                @grib_file = glob("$GRIB_dir[$monthnumplus]/fnl_$gribyear$gribmonth$gribday\_$gribhour*grib*");
             }

          } else {
             @grib_file = glob("$GRIB_dir[$monthnum]/fnl_$gribyear$gribmonth$gribday\_$gribhour*grib*");
          }
       } elsif ($Data_type eq "NAM") {
          @grib_file = glob("$GRIB_dir[0]/$gribyear$gribmonth$gribday.nam.t${gribhour}*");
       } else {
          die "\nBAD DATA TYPE SPECIFIED\n";
       }

       symlink $grib_file[0], "grib_$gribyear$gribmonth$gribday\_$gribhour" or die "Cannot symlink $_ to local directory: $!\n";

       $date = `$Script_dir/da_advance_time.exe $date ${GRIB_INTERVAL}h -w`;
       chomp ($date);
    }



 }

#Need a subroutine to convert WRF-format dates to numbers for comparison
 sub wrf2num {
    my ($wrf_date) = @_;
    $wrf_date =~ s/\D//g;
    return $wrf_date;
 }

 sub current_jobs {
    my $bjobs = `bjobs`;
    my $jobnum = () = $bjobs =~ /\d\d:\d\d\n/gi; #This line is complicated; it counts the number of matches for time-like patterns at the end of the line
                                                 #see http://stackoverflow.com/questions/1849329
    return $jobnum;
 }

 sub run_checks { #Subroutine to check for failures and limit simultaneous jobs
    my $num_jobs =  &current_jobs;
    if ($num_jobs > $MAX_JOBS) {
       print "\n\n*********\n* PAUSE *\n*********\n";
       print "MAX_JOBS exceeded ($num_jobs in queue), waiting before submitting next forecast.\n";
       printf "We have been waiting for   0 minutes...";
       my $wait_time = 0;
       while ($num_jobs > $MAX_JOBS){
          sleep(60);
          $wait_time ++;
          printf "\b\b\b\b\b\b\b\b\b\b\b\b\b\b%03d minutes...",$wait_time;
          $num_jobs =  &current_jobs;
       }
    }
    if (-e "$Script_dir/FAIL") {
       die "\nFailure reported! See file '$Script_dir/FAIL' for details\n";
    }
 }

 sub watch_progress { # When waiting for jobs to finish, let's display some info

}

