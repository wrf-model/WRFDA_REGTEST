#!/usr/bin/perl -w

##################################################################
# Generate an ensemble for use with hybrid WRFDA
# - Runs WPS/real.exe to create an initial forecast (one or two domains)
# - Runs WRFDA in RANDOMCV mode to add random perturbations to the initial domain
# - (Optional) Runs WRF forecast on each ensemble member for specified forecast period
#
# Written by Michael Kavulich, October 2015
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
use IPC::Open2;
use Getopt::Long;

#Set needed variables

 my $Start_time;
 my $tm = localtime;
 $Start_time=sprintf "Begin : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

 print "Start time: $Start_time\n";

# Location of necessary executables and data
 my $Main_dir = "/glade/p/work/kavulich/V38";
 my $WRF_dir="$Main_dir/WRFV3";
 my $WPS_dir="$Main_dir/WPS";
 my $geog_dir="/glade/p/work/wrfhelp/WPS_GEOG/";
 my $WRFDA_dir="$Main_dir/WRFDA_3DVAR_dmpar";
 my $BE_file="/glade/p/work/kavulich/GEN_BE/hybrid_etkf_tutorial_case_new/gen_be_cv5_d01/working/be.dat";

 my @GRIB_dir;
 $GRIB_dir[0]="/glade/p/rda/data/ds083.2/grib2/2015/2015.10";   #Where to find grib input data
#If your forecasts span multiple months, put the subsequent directory names in subsequent array values. Should work for indefinitely long runs
 $GRIB_dir[1]="/glade/p/rda/data/ds083.2/grib2/2015/2015.10";

# Directories for running WPS/WRF and storing output
 my $Script_dir = `pwd`;
 chomp $Script_dir;
 my $WORKDIR="/glade/scratch/kavulich/ENSEMBLE_FORECASTS";
 my $Case_name="hybrid_etkf_tutorial_case_new";
 my $Run_dir="$WORKDIR/$Case_name";
 my $Out_dir="$Script_dir/Output/$Case_name";

# Job submission options
 my $MAX_JOBS = 50;
 my $NUM_PROCS = 32;
 my $NUM_PROCS_REAL = 1;
 my $JOBQUEUE = "regular";
 my $JOBQUEUE_REAL = "caldera";
 my $PROJECT = "P64000400";

# Ensemble options
 my $dual_res = 0;     # 0 for standard hybrid, 1 for dual-resolution hybrid
 my $num_members = 10;  # Number of ensemble members; minimum 1
 my $run_forecast = 1; # 0 to just create the perturbed wrfinput files, 1 to run ensemble forecasts

# Start date
 my $initial_date="2015-10-26_12:00:00"; #Initial time for first forecast

# Set number of WPS time stamps for each cycle
 my $WPS_times=5;  # Set to "1" if you don't want to run a forecast

# Timing parameters
 my $METEM_INTERVAL=21600;   #WPS output interval               IN SECONDS
 my $OUT_INTERVAL=720;       #WRF output interval               IN MINUTES
 my $FC_INTERVAL=720;        #Interval between forecasts        IN MINUTES
 my $GRIB_INTERVAL=6;        #WPS GRIB input interval           IN HOURS
                             # I'm so, so sorry about this part ^^^^^^^^^^
                             # but it's necessary due to WPS/WRF namelist conventions
 my $RUN_DAYS = 0;           # Don't make this a month or longer or bad things will happen!
 my $RUN_HOURS = 24;
 my $RUN_MINUTES = 0;


# Domain parameters
 my $NUM_DOMAINS = 1; #For NUM_DOMAINS > 1, be sure that the appropriate variables are all set for all domains below!
 my @DX = ( 36000, 30000 );
 my @WEST_EAST_GRID = ( 120, 181 );
 my @SOUTH_NORTH_GRID = ( 100, 121 );
 my @VERTICAL_GRID = ( 42, 41 );
 my @PARENT_GRID_RATIO = ( 1, 2 );
 my @I_PARENT_START = ( 1, 21 );
 my @J_PARENT_START = ( 1, 11 );
# my $NL_ETA_LEVELS="1.000000,0.998000,0.996000,0.994000,0.992000,0.990000,0.988100,0.981800,0.974000,0.966000,0.958000,0.952000,0.943400,0.920000,0.880000,0.840000,0.800000,0.760000,0.720000,0.680000,0.640000,0.600000,0.560000,0.520000,0.480000,0.440000,0.400000,0.360000,0.320000,0.280000,0.240000,0.200000,0.160000,0.140000,0.120000,0.100000,0.080000,0.060000,0.040000,0.020000,0.00000";
 my $MAP_PROJ="lambert";
 my $REF_LAT=33.;    #AKA PHIC AKA CEN_LAT
 my $REF_LON=137.;     #AKA XLONC AKA CEN_LON
 my $STAND_LON=130.;
 my $TRUELAT1=30.;
 my $TRUELAT2=60.;
 my $POLE_LAT=90.;
 my $POLE_LON=0.;


# real.exe options
 my $NUM_METGRID_SOIL_LEVELS=4; #GFS Default "4"; prior to early 2005 it was "2"

# WRF options

 my $WRF_DT = 180;
 my @MP_PHYSICS = ( 6, 4 );
 my @RA_LW_PHYSICS = ( 4, 4 );
 my @RA_SW_PHYSICS = ( 4, 24 );
 my $RADT = 9;
 my @SF_SFCLAY_PHYSICS = ( 1, 1);
 my @SF_SURFACE_PHYSICS = ( 2, 2);
 my @BL_PBL_PHYSICS = ( 1, 2);
 my @CU_PHYSICS = ( 6, 99);
 my $PTOP = 2000;


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
    print "$Out_dir already exists, do you want to overwrite?\a\n";
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

 my $job_feedback; #For getting feedback from bsub
 my $jobid;        #For making sure we submit jobs in the right order

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
#    print "Currently $jobnum jobs are pending or running\n";
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

 my $monthnum = 0; #For multi-month runs, keep track of which month we're in
 my $straddle = 0; #For forecasts which straddle two months, we'll set this flag. You'll see why below

#    &run_checks; #Run failure and job number checks before starting new forecast

 #Generating new ensemble
 print "\n==================================================\n\n";
 print "Generating $num_members member ensemble for start date: $initial_date\n";
 my $fcst_end;
 if ($run_forecast) {
    $fcst_end = `./da_advance_time.exe $initial_date ${RUN_DAYS}d${RUN_HOURS}h${RUN_MINUTES}m -w`;
    chomp($fcst_end);
    print "Will run ensemble forecast through : $fcst_end\n";
 } else {
    $fcst_end = $initial_date;
 }

 # Separate out the individual components of each date
 my $syear  = substr("$initial_date", 0, 4) or die "Invalid start date format!\n";
 my $smonth = substr("$initial_date", 5, 2);
 my $sday   = substr("$initial_date", 8, 2);
 my $shour  = substr("$initial_date", 11, 2);
 my $smin   = substr("$initial_date", 14, 2);
 my $ssec   = substr("$initial_date", 17);

 my $eyear  = substr("$fcst_end", 0, 4) or die "Invalid end date format!\n";
 my $emonth = substr("$fcst_end", 5, 2);
 my $eday   = substr("$fcst_end", 8, 2);
 my $ehour  = substr("$fcst_end", 11, 2);
 my $emin   = substr("$fcst_end", 14, 2);
 my $esec   = substr("$fcst_end", 17);

 print "Setting up working directory for forecast in:\n$Run_dir\n";

 my $workdirname = substr(&wrf2num($initial_date),0,10);

 rmtree("$Run_dir/$initial_date");
 mkpath("$Run_dir/$initial_date");
 mkpath("$Out_dir/$workdirname");

 chdir "$Run_dir/$initial_date";
    # Get WPS files
    ! system("cp $WPS_dir/link_grib.csh $WPS_dir/geogrid/src/geogrid.exe $WPS_dir/ungrib/src/ungrib.exe $WPS_dir/metgrid/src/metgrid.exe $Run_dir/$initial_date/") or die "Error copying WPS files: $!\n";
    copy ("$WPS_dir/ungrib/Variable_Tables/Vtable.GFS","Vtable");
    copy ("$WRF_dir/run/real.exe","real.exe");


 unlink "namelist.input";
 unlink "namelist.wps";
 chmod 0755, "real.exe" or die "Couldn't change permissions for 'real.exe': $!";
# chmod 0755, "wrf.exe" or die "Couldn't change the permission to wrf.exe: $!";

 #Create namelists
 print "Creating namelists\n";

#--------------------------------------------------------------------------------------
# WPS NAMELIST
 open NL, ">namelist.wps" or die "Can not open namelist.wps for writing: $! \n";
 print NL "&share\n";
 print NL "wrf_core = 'ARW',\n";
 print NL " max_dom = $NUM_DOMAINS,\n";
 print NL " start_date = '$initial_date','$initial_date',\n";
 print NL " end_date   = '$fcst_end','$fcst_end',\n";
 print NL " interval_seconds = $METEM_INTERVAL\n";
 print NL " io_form_geogrid = 2,\n";
 print NL " debug_level = 0\n";
 print NL "/\n";
 print NL "&geogrid\n";
 print NL " parent_id         =   1,   1,\n";
 print NL " parent_grid_ratio =   $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
 print NL " i_parent_start    =   $I_PARENT_START[0],  $I_PARENT_START[1],\n";
 print NL " j_parent_start    =   $J_PARENT_START[0],  $J_PARENT_START[1],\n";
 print NL " e_we              =  $WEST_EAST_GRID[0], $WEST_EAST_GRID[1],\n";
 print NL " e_sn              =  $SOUTH_NORTH_GRID[0], $SOUTH_NORTH_GRID[1],\n";
 print NL " geog_data_res     = '2m','30s',\n";
 print NL " dx = $DX[0],\n";
 print NL " dy = $DX[0],\n";
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



#--------------------------------------------------------------------------------------
# WRFDA NAMELIST

 sub make_wrfda_namelist {

    my ($filename, $da_we, $da_sn, $da_vert, $da_dx, $seed1, $seed2) = @_;

    open NL, ">$filename" or die "Can not open '$filename' for writing: $! \n";
    print NL "&wrfvar1\n";  print NL "var4d=false,\n"; print NL "/\n";
    print NL "&wrfvar2\n";  print NL "/\n";
    print NL "&wrfvar3\n";  print NL "/\n";
    print NL "&wrfvar4\n";  print NL "/\n";
    print NL "&wrfvar5\n";  print NL "put_rand_seed             = .true.,\n"; print NL "/\n";
    print NL "&wrfvar6\n";  print NL "max_ext_its               = 1,\n"; print NL "/\n";
    print NL "&wrfvar7\n";  print NL "cv_options                = 5,\n"; print NL "/\n";
    print NL "&wrfvar8\n";  print NL "/\n";
    print NL "&wrfvar9\n";  print NL "/\n";
    print NL "&wrfvar10\n"; print NL "/\n";
    print NL "&wrfvar11\n"; print NL "seed_array1               = $seed1,\n"; print NL "seed_array2               = $seed2,\n"; print NL "/\n";
    print NL "&wrfvar12\n"; print NL "/\n";
    print NL "&wrfvar13\n"; print NL "/\n";
    print NL "&wrfvar14\n"; print NL "/\n";
    print NL "&wrfvar15\n"; print NL "/\n";
    print NL "&wrfvar16\n"; print NL "/\n";
    print NL "&wrfvar17\n"; print NL "analysis_type             = 'RANDOMCV',\n"; print NL "/\n";
    print NL "&wrfvar18\n"; print NL "analysis_date             = '$initial_date',\n"; print NL "/\n";
    print NL "&wrfvar19\n"; print NL "/\n"; 
    print NL "&wrfvar20\n"; print NL "/\n";
    print NL "&wrfvar21\n"; print NL "time_window_min           = '$initial_date',\n"; print NL "/\n";
    print NL "&wrfvar22\n"; print NL "time_window_max           = '$initial_date',\n"; print NL "/\n";
    print NL "&wrfvar23\n"; print NL "/\n"; 
    print NL "&time_control\n";
    print NL "/\n";
    print NL "&domains\n";
    print NL " e_we                     = $da_we\n";
    print NL " e_sn                     = $da_sn\n";
    print NL " e_vert                   = $da_vert\n";
    print NL " dx                       = $da_dx\n";
    print NL " dy                       = $da_dx\n";
    print NL "/\n";
    print NL "&physics\n";
    print NL " mp_physics               = $MP_PHYSICS[0],\n";
    print NL " ra_lw_physics            = $RA_LW_PHYSICS[0],\n";
    print NL " ra_sw_physics            = $RA_SW_PHYSICS[0],\n";
    print NL " radt                     = $RADT,\n";
    print NL " sf_sfclay_physics        = $SF_SFCLAY_PHYSICS[0],\n";
    print NL " sf_surface_physics       = $SF_SURFACE_PHYSICS[0],\n";
    print NL " bl_pbl_physics           = $BL_PBL_PHYSICS[0],\n";
    print NL "/\n";
    print NL "&dynamics\n";
    print NL "/\n";
 }


#--------------------------------------------------------------------------------------
# WRF/real NAMELIST
 open NL, ">namelist.input.wrf" or die "Can not open namelist.input.wrf for writing: $! \n";

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
 print NL " debug_level              = 0,\n"; print NL "/\n";
 print NL "&domains\n";
 print NL " time_step                = $WRF_DT,\n";
 print NL " max_dom                  = $NUM_DOMAINS,\n";
 print NL " e_we                     = $WEST_EAST_GRID[0], $WEST_EAST_GRID[1],\n";
 print NL " e_sn                     = $SOUTH_NORTH_GRID[0], $SOUTH_NORTH_GRID[1],\n";
 print NL " e_vert                   = $VERTICAL_GRID[0], $VERTICAL_GRID[1],\n";
 print NL " dx                       = $DX[0],$DX[1],\n";
 print NL " dy                       = $DX[0],$DX[1],\n";
#    print NL " eta_levels               = $NL_ETA_LEVELS\n";
 print NL " smooth_option            = 1,\n";
 print NL " p_top_requested          = $PTOP,\n";
 print NL " num_metgrid_levels       = 27,\n";
 print NL " num_metgrid_soil_levels  = $NUM_METGRID_SOIL_LEVELS,\n";
 print NL " grid_id                  = 1, 2,\n";
 print NL " parent_id                = 0, 1,\n";
 print NL " i_parent_start           = $I_PARENT_START[0],  $I_PARENT_START[1],\n";
 print NL " j_parent_start           = $J_PARENT_START[0],  $J_PARENT_START[1],\n";
 print NL " parent_grid_ratio        = $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
 print NL " parent_time_step_ratio   = $PARENT_GRID_RATIO[0],  $PARENT_GRID_RATIO[1],\n";
 print NL " feedback                 = 1,\n"; print NL "/\n";
 print NL "&physics\n";
 print NL " mp_physics               = $MP_PHYSICS[0], $MP_PHYSICS[1],\n";
 print NL " ra_lw_physics            = $RA_LW_PHYSICS[0], $RA_LW_PHYSICS[1],\n";
 print NL " ra_sw_physics            = $RA_SW_PHYSICS[0], $RA_SW_PHYSICS[1],\n";
 print NL " radt                     = $RADT, $RADT,\n";
 print NL " sf_sfclay_physics        = $SF_SFCLAY_PHYSICS[0], $SF_SFCLAY_PHYSICS[1],\n";
 print NL " sf_surface_physics       = $SF_SURFACE_PHYSICS[0], $SF_SURFACE_PHYSICS[1],\n";
 print NL " bl_pbl_physics           = $BL_PBL_PHYSICS[0], $BL_PBL_PHYSICS[1]\n";
 print NL " bldt                     = 0,\n";
 print NL " cu_physics               = $CU_PHYSICS[0], $CU_PHYSICS[1],\n";
 print NL " cudt                     = 5,\n";
 print NL " isfflx                   = 1,\n";
 print NL " ifsnow                   = 1,\n";
 print NL " icloud                   = 1,\n";
 print NL " surface_input_source     = 1,\n";
 print NL " num_soil_layers          = 5,\n";
 print NL " sf_urban_physics         = 0,\n"; print NL "/\n";
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
 print NL " scalar_adv_opt           = 1,\n"; print NL "/\n";
 print NL "&bdy_control\n";
 print NL " spec_bdy_width           = 5,\n";
 print NL " spec_zone                = 1,\n";
 print NL " relax_zone               = 4,\n";
 print NL " specified                = .true., .false.,.false.,\n";
 print NL " nested                   = .false., .true., .true.,\n"; print NL "/\n";
 print NL "&namelist_quilt\n"; print NL "/\n";
 close NL;


 #Link FNL GRIB data
 print "Linking input data\n";

 my $fnl_date = $initial_date;

 if ($smonth == $emonth) {
    if ($straddle == 1) { #If start month and end month are the same and straddle == 1, that means we've fully entered the next month
       $monthnum ++;
       $straddle = 0;
    }
 } else {
    $straddle = 1;
 }
 while ( &wrf2num($fnl_date) <= &wrf2num($fcst_end) ) {
    my $fnlyear  = substr("$fnl_date", 0, 4);
    my $fnlmonth = substr("$fnl_date", 5, 2);
    my $fnlday   = substr("$fnl_date", 8, 2);
    my $fnlhour  = substr("$fnl_date", 11, 2);
    
    my @fnl_file;
    if ($straddle == 1) {
       my $monthnumplus = $monthnum + 1;
       if ($fnlmonth == $smonth) {
          @fnl_file = glob("$GRIB_dir[$monthnum]/fnl_$fnlyear$fnlmonth$fnlday\_$fnlhour*grib*");
       } else {
          @fnl_file = glob("$GRIB_dir[$monthnumplus]/fnl_$fnlyear$fnlmonth$fnlday\_$fnlhour*grib*");
       }

    } else {
       @fnl_file = glob("$GRIB_dir[$monthnum]/fnl_$fnlyear$fnlmonth$fnlday\_$fnlhour*grib*");
    }

    symlink $fnl_file[0], "fnl_$fnlyear$fnlmonth$fnlday\_$fnlhour" or die "Cannot symlink $_ to local directory: $!\n";

    $fnl_date = `$Script_dir/da_advance_time.exe $fnl_date ${GRIB_INTERVAL}h -w`;
    chomp ($fnl_date);
 }

# RUN WPS

 print "Creating WPS job\n";

 my $init_jobid;
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
 print FH "./link_grib.csh fnl_*\n";
 print FH "./ungrib.exe\n";
 print FH "./metgrid.exe\n";
 print FH "if ( (!(-e 'met_em.d01.$fcst_end.nc')) && (!(-e '$Script_dir/FAIL')) ) then\n";
 print FH "   echo 'WPS failure in $Run_dir/$initial_date' > $Script_dir/FAIL\n";
 print FH "endif\n";
 close FH ;

 $job_feedback = ` bsub < run_wps.csh `;
 print "$job_feedback\n";
 if ($job_feedback =~ m/.*<(\d+)>/) {
    $init_jobid = $1;
 } else {
    print "\nJob feedback = $job_feedback\n\n";
    die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WPS job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
 }

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
 print FH "ln -sf namelist.input.wrf namelist.input\n";
 print FH "mpirun.lsf ./real.exe\n";
 print FH "if ( (!(-e 'wrfinput_d01')) && (!(-e '$Script_dir/FAIL')) ) then\n";
 print FH "   echo 'real.exe failure in $Run_dir/$initial_date' > $Script_dir/FAIL\n";
 print FH "endif\n";
 close FH ;

 $job_feedback = ` bsub -w "ended($init_jobid)" < run_real.csh `;
 print "$job_feedback\n";
 if ($job_feedback =~ m/.*<(\d+)>/) {
    $init_jobid = $1;
 } else {
    print "\nJob feedback = $job_feedback\n\n";
    die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit real.exe job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
 }


 my $i = 0;
 while ($i <= $num_members) {

    if ($i == 0) {
       mkdir("ens_CONTROL");
       chdir("ens_CONTROL");
       unlink("$Out_dir/$workdirname/ens_CONTROL");
       mkdir("$Out_dir/$workdirname/ens_CONTROL");
       copy("$Run_dir/$initial_date/wrfbdy_d01","$Run_dir/$initial_date/ens_CONTROL/");
       copy("$Run_dir/$initial_date/wrfinput_d01","$Run_dir/$initial_date/ens_CONTROL/");
       copy("$Run_dir/$initial_date/ens_CONTROL/wrfbdy_d01","$Out_dir/$workdirname/ens_CONTROL");
       copy("$Run_dir/$initial_date/ens_CONTROL/wrfinput_d01","$Out_dir/$workdirname/ens_CONTROL");

       print "Creating CONTROL job\n";

       open FH, ">run_control.csh" or die "Can not open run_control.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J CONTROL\n";
       print FH "#BSUB -q $JOBQUEUE_REAL\n";
       print FH "#BSUB -n $NUM_PROCS_REAL\n";
       print FH "#BSUB -o CONTROL.output"."\n";
       print FH "#BSUB -e CONTROL.error"."\n";
       print FH "#BSUB -W 5"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=%d]"."\n", ($NUM_PROCS_REAL < 16 ) ? $NUM_PROCS_REAL : 16;
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE_REAL =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "\\cp ../wrfinput_d01 .\n";
       print FH "rm -rf $Out_dir/$workdirname/ens_CONTROL\n";
       print FH "mkdir  $Out_dir/$workdirname/ens_CONTROL\n";
       print FH "\\cp $Run_dir/$initial_date/ens_CONTROL/wrfinput_d0* $Out_dir/$workdirname/ens_CONTROL\n";
       close FH ;

       $job_feedback = ` bsub -w "ended($init_jobid)" < run_control.csh `;
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit CONTROL job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }

    } else {
       mkdir("ens_$i");
       chdir("ens_$i");
       symlink("$WRFDA_dir/run/LANDUSE.TBL","LANDUSE.TBL");
       symlink("$BE_file","be.dat");

       &make_wrfda_namelist("namelist.input",$WEST_EAST_GRID[0],$SOUTH_NORTH_GRID[0],$VERTICAL_GRID[0],$DX[0],"$syear$smonth$sday$shour",$i);

       print "Creating WRFDA RANDOMCV job for ensemble $i\n";
   
       open FH, ">run_wrfda.csh" or die "Can not open run_wrfda.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J RANDOMCV_ens$i\n";
       print FH "#BSUB -q $JOBQUEUE_REAL\n";
       print FH "#BSUB -n $NUM_PROCS_REAL\n";
       print FH "#BSUB -o run_randomcv.output"."\n";
       print FH "#BSUB -e run_randomcv.error"."\n";
       print FH "#BSUB -W 10"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=%d]"."\n", ($NUM_PROCS_REAL < 16 ) ? $NUM_PROCS_REAL : 16;
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE_REAL =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "ln -sf $WRFDA_dir/var/build/da_wrfvar.exe .\n";
       print FH "\\cp ../wrfinput_d01 .\n";
       print FH "ln -sf wrfinput_d01 ./fg\n";
       print FH "mpirun.lsf ./da_wrfvar.exe\n";
       print FH "if ( !(-e 'wrfvar_output')) then\n";
       print FH "   echo 'da_wrfvar.exe failure in $Run_dir/$initial_date/ens_$i' > $Script_dir/FAIL\n";
       print FH "endif\n";
       print FH "rm -rf $Out_dir/$workdirname/ens_$i\n";
       print FH "mkdir  $Out_dir/$workdirname/ens_$i\n";
       print FH "\\cp $Run_dir/$initial_date/ens_$i/wrfinput_d0* $Out_dir/$workdirname/ens_$i\n";
       close FH ;

       $job_feedback = ` bsub -w "ended($init_jobid)" < run_wrfda.csh `;
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit da_wrfvar.exe job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }


#### Set up and run da_update_bc.exe ####
       open NL, ">parame.in" or die "Can not open parame.in for writing: $! \n";

       print NL "&control_param\n";
       print NL "da_file            = './wrfvar_output'\n";
       print NL "wrf_bdy_file       = './wrfbdy_d01'\n";
       print NL "wrf_input          = './wrfinput_d01'\n";
       print NL "update_lateral_bdy = .true.\n";
       print NL "update_low_bdy     = .false.\n";
       print NL "domain_id          = 1\n"; print NL "/\n";
       close NL;


       print "Creating UPDATE_BC job for ensemble $i\n";

       open FH, ">run_updatebc.csh" or die "Can not open run_updatebc.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J UPDATEBC_ens$i\n";
       print FH "#BSUB -q $JOBQUEUE_REAL\n";
       print FH "#BSUB -n $NUM_PROCS_REAL\n";
       print FH "#BSUB -o run_updatebc.output"."\n";
       print FH "#BSUB -e run_updatebc.error"."\n";
       print FH "#BSUB -W 5"."\n";
       print FH "#BSUB -P $PROJECT\n";
       printf FH "#BSUB -R span[ptile=%d]"."\n", ($NUM_PROCS_REAL < 16 ) ? $NUM_PROCS_REAL : 16;
       print FH "\n"; #End of BSUB commands; add newline for readability
       if ( $JOBQUEUE_REAL =~ "caldera") {
          print FH "unsetenv MP_PE_AFFINITY\n";  # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
       }
       print FH "ln -sf $WRFDA_dir/var/build/da_update_bc.exe .\n";
       print FH "\\cp ../wrfbdy_d01 .\n";
       print FH "mpirun.lsf ./da_update_bc.exe > update_bc.log\n";
       print FH "\\cp $Run_dir/$initial_date/ens_$i/wrfbdy_d0* $Out_dir/$workdirname/ens_$i\n";
       close FH ;

       $job_feedback = ` bsub -w "ended($jobid)" < run_updatebc.csh `;
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit da_update_bc.exe job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }
    }



    if ($run_forecast) {

#### Run WRF forecast (if necessary) ####
       mkdir("wrf_forecast");
       chdir("wrf_forecast");


    # Get WRF files; use glob since we need everything
       unlink ("LANDUSE.TBL");
       ! system("cp $WRF_dir/run/* .") or die "Error copying WRF files: $!\n";
   

       print "Creating WRF job for ensemble $i\n";

       open FH, ">run_wrf.csh" or die "Can not open run_wrf.csh for writing: $! \n";
       print FH "#!/bin/csh\n";
       print FH "#\n";
       print FH "# LSF batch script\n";
       print FH "# Automatically generated by $0\n";
       print FH "#BSUB -J WRF_ens$i\n";
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
       print FH "\\cp ../wrfinput_d01 .\n";
       print FH "\\cp ../../wrfbdy_d01 .\n";
       print FH "\\cp ../../namelist.input.wrf namelist.input\n";
       print FH "mpirun.lsf ./wrf.exe\n";
       print FH "if ( !(-e 'wrfout_d01_$fcst_end') ) then\n";
       if ($i == 0) {
          print FH "   echo 'WRF failure in $Run_dir/$initial_date/ens_CONTROL/wrf_forecast' > $Script_dir/FAIL\n";
       } else {
          print FH "   echo 'WRF failure in $Run_dir/$initial_date/ens_$i/wrf_forecast' > $Script_dir/FAIL\n";
       }
       print FH "endif\n";
       if ($i == 0) {
          printf FH "\\cp $Run_dir/$initial_date/ens_CONTROL/wrf_forecast/wrfout_d01_$fcst_end $Out_dir/$workdirname/ens_CONTROL/wrfout_d01_$fcst_end\n";
       } else {
          printf FH "\\cp $Run_dir/$initial_date/ens_$i/wrf_forecast/wrfout_d01_$fcst_end $Out_dir/$workdirname/ens_$i/wrfout_d01_$fcst_end.e%03d\n",$i;
       }
       close FH ;


       $job_feedback = ` bsub -w "ended($jobid)" < run_wrf.csh`;
       print "$job_feedback\n";
       if ($job_feedback =~ m/.*<(\d+)>/) {
          $jobid = $1;
       } else {
          print "\nJob feedback = $job_feedback\n\n";
          die "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRF job for $initial_date\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
       }
       chdir("..");

    }

    chdir("..");
    $i++;

 } # End while loop

 copy($0,$Out_dir); #Keep a copy of this script with these settings for future reference.

 print "\nScript finished!\n";
 my $Finish_time;
 $tm = localtime;
 $Finish_time=sprintf "End : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

 print "$Finish_time\n";

