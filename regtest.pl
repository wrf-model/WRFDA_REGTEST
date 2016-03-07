#!/usr/bin/perl -w
# Author  : Xin Zhang, MMM/NCAR, 8/17/2009
# Updates : March 2013, adapted for Loblolly (PC) and Yellowstone (Mike Kavulich) 
#           August 2013, added 4DVAR test capability (Mike Kavulich)
#           December 2013, added parallel/batch build capability (Mike Kavulich)
#           May 2014, added new platform (Mac), improved summary upload, added OBSPROC, 4DVAR, and VARBC test capabilities
#           June 2014, added FGAT test capability
#           August 2014, added GENBE test capability (for yellowstone)
#           January 2015, added GENBE test capability for PC and Mac, update for CV7 tests, several other updates and fixes
#           March 2015, added CLOUD_CV compilation option, adding 4DVAR GENBE capability, updates to web summary upload
#           April 2015, different compiler versions now have different BASELINE files, generalize yellowstone job scripts
#           May 2015, added CYCLING job capability for yellowstone, overhauled job hash structure for better summary reports
#           September 2015, added CYCLING capability and track sub-job info for local machines
#           November 2015, added HYBRID job capability
#           December 2015, added HDF5 and NETCDF4 capabilities
#           January 2016, added 4DVAR serial test capability
#           February 2016, Added HYBRID capabilities for local machines, enabled sm tests, cleaned up library link system

use strict;
use Term::ANSIColor;
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
use Data::Dumper;

# Start time:

my $Start_time;
my $tm = localtime;
$Start_time=sprintf "Begin : %02d:%02d:%02d-%04d/%02d/%02d\n",
        $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

my $Upload_defined;
my $Compiler_defined;
my $Source_defined;
my $Exec_defined;
my $Debug_defined;
my $Parallel_compile_num = 4;
my $Revision = 'HEAD'; # Revision Number
my $WRFPLUS_Revision = 'NONE'; # WRFPLUS Revision Number
my $Testfile = 'testdata.txt';
my $CLOUDCV_defined;
my $NETCDF4_defined;
my $REPO_defined;
my $RTTOV_dir;
my $use_HDF5 = "yes";
my @valid_options = ("compiler","source","revision","upload","exec","debug","j","cloudcv","netcdf4","hdf5","testfile","repo");

#This little bit makes sure the input arguments are formatted correctly
foreach my $arg ( @ARGV ) {
  my $first_two = substr($arg, 0, 2); 
  unless ($first_two eq "--") {
    print "\n Unknown option: $arg \n";
    &print_help_and_die;
  }

#Make sure option is valid
  my $valid = 0;
  foreach (@valid_options) {
    if ($arg =~ "$_") {$valid = 1};
  }
  if ($valid == 0) {
    $arg =~ s/=.*//;
    print "\n unknown option: $arg \n";
    &print_help_and_die;
  }

  &print_help_and_die unless ($arg =~ "="); #All options need an equals sign

}


GetOptions( "compiler=s" => \$Compiler_defined,
            "source:s" => \$Source_defined, 
            "revision:s" => \$Revision,
            "upload:s" => \$Upload_defined,
            "exec:s" => \$Exec_defined,
            "debug:s" => \$Debug_defined,
            "j:s" => \$Parallel_compile_num,
            "cloudcv:s" => \$CLOUDCV_defined,
            "netcdf4:s" => \$NETCDF4_defined,
            "hdf5:s" => \$use_HDF5,
            "testfile:s" => \$Testfile,
            "repo:s" => \$REPO_defined ) or &print_help_and_die;

unless ( defined $Compiler_defined ) {
  print "\nA compiler must be specified!\n\nAborting the script with dignity.\n";
  &print_help_and_die;
}


sub print_help_and_die {
  print "\nUsage : regtest.pl --compiler=COMPILER --source=SOURCE_CODE.tar --revision=NNNN --upload=[no]/yes --exec=[no]/yes\n";
  print "                   --debug=[no]/yes/super --j=NUM_PROCS --netcdf4=[no]/yes --hdf5=no/[yes] --cloudcv=[no]/yes\n";
  print "                   --testfile=testdata.txt --repo=https://svn-wrf-model.cgd.ucar.edu/trunk\n\n";
  print "        compiler: Compiler name (supported options: ifort, gfortran, xlf, pgi, g95)\n";
  print "        source:   Specify location of source code .tar file (use 'REPO' to retrieve from repository)\n";
  print "        revision: Specify code revision to retrieve (only works when '--source=REPO' specified)\n";
  print "                  Use any number to specify that revision number; specify 'HEAD' to use the latest revision\n";
  print "        upload:   Uploads summary to web (default is 'yes' iff source==REPO and revision==HEAD)\n";
  print "        exec:     Execute only; skips compile, utilizes existing executables\n";
  print "        debug:    'yes' compiles with minimal optimization; 'super' compiles with debugging options as well\n";
  print "        j:        Number of processors to use in parallel compile (default 4, use 1 for serial compilation)\n";
  print "        cloudcv:  Compile for CLOUD_CV options\n";
  print "        netcdf4:  Compile for NETCDF4 options\n";
  print "        hdf5:     Compile for HDF5 options\n";
  print "        testfile: Name of test data file (default: testdata.txt)\n";
  print "        repo:     Location of code repository\n";
  die "\n";
}

my $Exec;
if (defined $Exec_defined && $Exec_defined ne 'no') {
   $Exec = 1;
   unless (defined $Source_defined) {$Source_defined = "Existing executable"};
} else {
   $Exec = 0;
}
my $Debug;
if (defined $Debug_defined && $Debug_defined eq 'super') {
   $Debug = 2;
} elsif (defined $Debug_defined && $Debug_defined eq 'yes') {
   $Debug = 1;
} elsif ( !(defined $Debug_defined) || $Debug_defined eq 'no') {
   $Debug = 0;
} else {
   die "Invalid debug option specified ('$Debug_defined'); valid options are 'no', 'yes', or 'super'";
}

if ( $Parallel_compile_num > 16 ) {die "Can not parallel compile using more than 16 processors; set j<=16\n"};

# Who is running the test?
my $Tester = getlogin();

# Local variables
my $Arch;
my $Machine;
my $Name;
my $Compiler;
my $CCompiler;
my $Project;
my $Source;
my $Queue;
my $Compile_queue = 'caldera';
my @compile_job_list;
my $Database;
my $Baseline;
my $MainDir;
my @Message;
my $Par="";
my $Par_4dvar="";
my $Type="";
my $Clear = `clear`;
my $diffwrfdir = "";
my $missvars;
my @gtsfiles;
my @childs;
my @exefiles;
my %Experiments ;
my $cmd='';
#   Sample %Experiments Structure: #####################
#   
#   %Experiments (
#                  cv3_guo => \%record (
#                                     index=> 1 
#                                     cpu_mpi=> 32
#                                     cpu_openmp=> 8
#                                     status=>"open"
#                                     test_type=>"3DVAR"
#                                     paropt => { 
#                                                serial => {
#                                                           currjob => 89123
#                                                           currjobnum => 1
#                                                           currjobname => "OBSPROC"
#                                                           status => "running"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 17 #sum of subjob walltimes
#                                                           result => "--"
#                                                           job => {
#                                                                    1 => {
#                                                                              jobid => 89123
#                                                                              jobname => "OBSPROC"
#                                                                              status => "done"
#                                                                              walltime => 17
#                                                                              }
#                                                                   }
#                                                                    2 => {
#                                                                              jobid => 89124
#                                                                              jobname => "GENBE"
#                                                                              status => "running"
#                                                                              walltime => 0
#                                                                              }
#                                                                   }
#                                                                    3 => {
#                                                                              jobid => 89125
#                                                                              jobname => "3DVAR"
#                                                                              status => "pending"
#                                                                              walltime => 0
#                                                                              }
#                                                                   }
#                                                          } 
#                                                smpar  => {
#                                                           currjob => 0
#                                                           status => "pending"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 0
#                                                           result => "pending"
#                                                          } 
#                                               }
#                                     )
#                  t44_liuz => \%record (
#                                     index=> 3 
#                                     cpu_mpi=> 16
#                                     cpu_openmp=> 4
#                                     status=>"open"
#                                     test_type=>"3DVAR"
#                                     paropt => { 
#                                                serial => {
#                                                           currjob => 89123
#                                                           status => "done"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           result => "diff"
#                                                          } 
#                                               }
#                                     )
#                 )
#########################################################
my %Compile_options;
my %Compile_options_4dvar;
my $count; #For counting the number of compile options found
my %compile_job_array;

# What's my name?

my $ThisGuy = `whoami`; chomp($ThisGuy);

# Where am I?
$MainDir = `pwd`; chomp($MainDir);

# What's my hostname, system, and machine?

my $Host = hostname();
my $System = `uname -s`; chomp($System);
my $Local_machine = `uname -m`; chomp($Local_machine);
my $Machine_name = `uname -n`; chomp($Machine_name); 

if ($Machine_name =~ /yslogin\d/) {$Machine_name = 'yellowstone'};
my @splitted = split(/\./,$Machine_name);

$Machine_name = $splitted[0];

#Sort out the compiler name and version differences

my %convert_compiler = (
    gfortran    => "gfortran",
    gnu         => "gfortran",
    pgf90       => "pgi",
    pgi         => "pgi",
    intel       => "ifort",
    ifort       => "ifort",
);
my %convert_module = (
    gfortran    => "gnu",
    gnu         => "gnu",
    pgf90       => "pgi",
    pgi         => "pgi",
    intel       => "intel",
    ifort       => "intel",
);

my $Compiler_defined_conv .= $convert_compiler{$Compiler_defined};
my $module_loaded .= $convert_module{$Compiler_defined};

printf "NOTE: You specified '$Compiler_defined' as your compiler.\n Interpreting this as '$Compiler_defined_conv'.\n" unless ( $Compiler_defined eq $Compiler_defined_conv );

$Compiler_defined = $Compiler_defined_conv;



# Assign a C compiler
if ($Compiler_defined eq "gfortran") {
    $CCompiler = "gcc";
} elsif ($Compiler_defined eq "pgi") {
    $CCompiler = "pgcc";
} elsif ($Compiler_defined eq "ifort") {
    $CCompiler = "icc";
} else {
    print "\n ERROR ASSIGNING C COMPILER\n";
    &print_help_and_die;
}

my $Compiler_version = "";
if (defined $ENV{'COMPILER_VERSION'} ) {
   $Compiler_version = $ENV{COMPILER_VERSION}
}

# Parse the task table:

open(DATA, "<$Testfile") or die "Couldn't open test file $Testfile, see README for more info $!";

while (<DATA>) {
     last if ( /^####/ && (keys %Experiments) > 0 );
     next if /^#/;
     if ( /^(\D)/ ) {
         ($Arch, $Machine, $Name, $Compiler, $Project, $Queue, $Database, $Baseline, $Source) = 
               split /\s+/,$_;
     }

     if ( /^(\d)+/ && ($System =~ /$Arch/i) ) {
#       printf "Local_machine=$Local_machine Machine=$Machine \n";
       if ( ($Local_machine =~ /$Machine/i) ) {
#         printf "SUCCESS1 \n Compiler=$Compiler Compiler_defined=$Compiler_defined \n";
         if ( ($Compiler =~ /$Compiler_defined/i) ) {
#              printf "SUCCESS2 \n Machine_name=$Machine_name Name=$Name \n";
              if ( ($Name =~ /$Machine_name/i) ) {
                $_=~ m/(\d+) \s+ (\S+) \s+ (\S+) \s+ (\S+) \s+ (\S+) \s+ (\S+)/x;
                my @tasks = split /\|/, $6;
                my %task_records;
                $task_records{$_} = {} for @tasks;
                my %record = (
                     index => $1,
                     test_type => $3,
                     cpu_mpi => $4,
                     cpu_openmp => $5,
                     status => "open",
                     paropt => \%task_records
                );
                $Experiments{$2} = \%record;
                if ($Experiments{$2}{test_type} =~ /4DVAR/i) {
                    foreach (@tasks) {
                        $Par_4dvar = join('|',$Par_4dvar,$_) unless ($Par_4dvar =~ /$_/);
                    }
                } else {
                    foreach my $task (@tasks) {
                        my $task_noplus = $task;
                        $task_noplus =~ s/\+/\\+/g; # Need to escape "+" sign from "dm+sm" in the unless check
                        $Par = join('|',$Par,$task) unless ($Par =~ /$task_noplus/);
                    }
                }
              };
         }; 
       };
     }; 
}


# NOTE: FOR SOME REASON THIS DOESN'T DO ANYTHING RIGHT NOW. NEEDS FURTHER CHECKING
if ($Par_4dvar =~ /sm/i) {
    print "\nNOTE: 4DVAR shared memory builds not supported. Will not compile 4DVAR for smpar; dm+sm.\n\n";
    $Par_4dvar =~ s/smpar\|//g;
    $Par_4dvar =~ s/\|smpar//g;
    $Par_4dvar =~ s/smpar//g;
    $Par_4dvar =~ s/dm\+sm\|//g;
    $Par_4dvar =~ s/\|dm\+sm//g;
    $Par_4dvar =~ s/dm\+sm//g;
    sleep 1;
}


#Remove "|" from the start of parallelism strings
$Par_4dvar =~ s/^\|//g;
$Par =~ s/^\|//g;

#Create $Type variable to keep track of which code needs to be compiled/checked 
foreach my $name (keys %Experiments) {
    unless ( $Type =~ $Experiments{$name}{test_type}) {
        $Type = join('|',$Type,$Experiments{$name}{test_type});
    }

}
$Type =~ s/CYCLING/3DVAR/g;
$Type =~ s/FGAT/3DVAR/g;
$Type =~ s/HYBRID/3DVAR/g;

# If source specified on command line, use it
$Source = $Source_defined if defined $Source_defined;

# If the source is "REPO", we need to specify the location of the code repository
my $CODE_REPO = 'https://svn-wrf-model.cgd.ucar.edu/trunk';
if ( ($Source eq "REPO") && (defined $REPO_defined) ) {
    $CODE_REPO = $REPO_defined;
}

# Upload summary to web by default if source is head of repository; 
# otherwise do not upload unless upload option is explicitly selected
my $Upload;
if ( ($Debug == 0) && ($Exec == 0) && ($Source eq "REPO") && ($Revision eq "HEAD") && !(defined $Upload_defined) ) {
    $Upload="yes";
    print "\nSource is head of repository: will upload summary to web when test is complete.\n\n";
} elsif ( !(defined $Upload_defined) ) {
    $Upload="no";
} else {
    $Upload=$Upload_defined;
}

# If specified paths are relative then point them to the full path
if ( !($Source =~ /^\//) ) {
    unless ( ($Source eq "REPO") or $Exec) {$Source = $MainDir."/".$Source};
}
if ( !($Database =~ /^\//) ) {
    $Database = $MainDir."/".$Database;
}
if ( !($Baseline =~ /^\//) ) {
    $Baseline = $MainDir."/".$Baseline;
}

# If the test database doesn't exist, quit right away
unless ( -e "$Database" ) {
   die "DATABASE NOT FOUND: '$Database'\nQuitting $0...\n";
}


printf "Finished parsing the table, the experiments are : \n";
printf "#INDEX   EXPERIMENT                   TYPE             CPU_MPI  CPU_OPENMP    PAROPT\n";
printf "%-4d     %-27s  %-16s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n", 
     $Experiments{$_}{index}, $_, $Experiments{$_}{test_type},$Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
         keys%{$Experiments{$_}{paropt}} for (keys %Experiments);

die "\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (Mac OSx): pgi, g95 \n\n" unless (keys %Experiments) > 0 ; 

sleep 2; #Pause to let user see list

if ($Arch eq "Linux") { #If on Yellowstone, make sure we have the right modules loaded
   if ($Machine_name =~ /yellowstone/i) {
      if ( !( $ENV{TACC_FAMILY_COMPILER} =~ m/$module_loaded/) ) {; # Check Yellowstone ENV variable for current module
         print "\n!!!!!     ERROR ERROR ERROR     !!!!!\n";
         print "You have specified the $module_loaded compiler, but the $ENV{TACC_FAMILY_COMPILER} module is loaded!";
         print "\n!!!!!     ERROR ERROR ERROR     !!!!!\n";
         &print_help_and_die;
      }
   }
}

# Set paths to necessary utilities, set BUFR read ENV variables if needed

if ($Arch eq "Linux") {
    if ($Machine_name =~ /yellowstone/i) { # Yellowstone
        $diffwrfdir = "~/bin/";
    }
}

# What time is it?
#
   my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);
   $year += 1900;
   $mon += 101;     $mon = sprintf("%02d", $mon % 100);
   $mday += 100;    $mday = sprintf("%02d", $mday % 100);
   $hour += 100;    $hour = sprintf("%02d", $hour % 100);
   $min += 100;     $min = sprintf("%02d", $min % 100);
   $sec += 100;     $sec = sprintf("%02d", $sec % 100);

# If exec=yes, collect version info and skip compilation
if ($Exec) {
   print "Option exec=yes specified; checking previously built code for revision number\n";
   if ( ($Type =~ /4DVAR/i) && ($Type =~ /3DVAR/i) ) {
      print "Ensuring that all compiled code is the same version\n";
      if ( ($Par =~ /dmpar/i) && ($Par_4dvar =~ /dmpar/i) ) {
         my $Revision3 = &get_repo_revision("WRFDA_3DVAR_dmpar");
         my $Revision4 = &get_repo_revision("WRFDA_4DVAR_dmpar");
         die "Check your existing code: WRFDA_3DVAR_dmpar and WRFDA_4DVAR_dmpar do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = $Revision3;
      } elsif ( ($Par =~ /serial/i) && ($Par_4dvar =~ /serial/i) ) {
         my $Revision3 = &get_repo_revision("WRFDA_3DVAR_serial");
         my $Revision4 = &get_repo_revision("WRFDA_4DVAR_serial");
         die "Check your existing code: WRFDA_3DVAR_serial and WRFDA_4DVAR_serial do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = $Revision3;
      } elsif ( ($Par =~ /dmpar/i) && ($Par_4dvar =~ /serial/i) ) {
         my $Revision3 = &get_repo_revision("WRFDA_3DVAR_dmpar");
         my $Revision4 = &get_repo_revision("WRFDA_4DVAR_serial");
         die "Check your existing code: WRFDA_3DVAR_dmpar and WRFDA_4DVAR_serial do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = $Revision3;
      } else {
         my $Revision3 = &get_repo_revision("WRFDA_3DVAR_dmpar");
         my $Revision4 = &get_repo_revision("WRFDA_4DVAR_serial");
         die "Check your existing code: WRFDA_3DVAR_dmpar and WRFDA_4DVAR_serial do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = $Revision3;
      }
   } elsif ($Type =~ /4DVAR/i) {
      if ( ($Par_4dvar =~ /serial/i) && ($Par_4dvar =~ /dmpar/i) ) {
         print "Ensuring that all compiled code is the same version\n";
         my $Revision3 = &get_repo_revision("WRFDA_4DVAR_serial");
         my $Revision4 = &get_repo_revision("WRFDA_4DVAR_dmpar");
         die "Check your existing code: WRFDA_4DVAR_serial and WRFDA_4DVAR_dmpar do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = $Revision3;
      } elsif ($Par_4dvar =~ /serial/i) {
         $Revision = &get_repo_revision("WRFDA_4DVAR_serial");
      } else {
         $Revision = &get_repo_revision("WRFDA_4DVAR_dmpar");
      }
   } else {
      if ( $Par =~ /dmpar/i ) {
         $Revision = &get_repo_revision("WRFDA_3DVAR_dmpar");
      } else {
         $Revision = &get_repo_revision("WRFDA_3DVAR_serial");
      }
   }
   chomp($Revision);
   print "All code checks out; revision is $Revision\n";
   goto "SKIP_COMPILE";
}

# Set necessary environment variables for compilation

$ENV{J}="-j $Parallel_compile_num";

if (defined $NETCDF4_defined && $NETCDF4_defined ne 'no') {
   $ENV{NETCDF4}='1';
   print "\nWill compile with NETCDF4 features turned on\n\n";
}
if (defined $CLOUDCV_defined && $CLOUDCV_defined ne 'no') {
   $ENV{CLOUD_CV}='1';
   print "\nWill compile for CLOUD_CV option\n\n";
#   die "CLOUD_CV option is not fully implemented yet. Exiting...";
}

$ENV{CRTM}='1'; #These are not necessary since V3.6, but will not hurt
$ENV{BUFR}='1';

   if ( (-d "$MainDir/libs/HDF5_$Compiler\_$Compiler_version") && ($use_HDF5 eq "yes")) {
      $ENV{HDF5}="$MainDir/libs/HDF5_$Compiler\_$Compiler_version";
      print "Found HDF5 in directory $MainDir/libs/HDF5_$Compiler\_$Compiler_version\n";
   } else {
      unless (-d "$MainDir/libs/HDF5_$Compiler\_$Compiler_version") {print "\nDirectory $MainDir/libs/HDF5_$Compiler\_$Compiler_version DOES NOT EXIST!\n"};
      print "\nNot using HDF5\n";
   }

   if ($Arch eq "Linux") {
      if ($Machine_name eq "yellowstone") { # Yellowstone
          $RTTOV_dir = "/glade/u/home/$ThisGuy/libs/rttov_$Compiler\_$Compiler_version";
          if (-d $RTTOV_dir) {
              $ENV{RTTOV} = $RTTOV_dir;
              print "Using RTTOV libraries in $RTTOV_dir\n";
          } else {
              print "$RTTOV_dir DOES NOT EXIST\n";
              print "RTTOV Libraries have not been compiled with $Compiler version $Compiler_version\nRTTOV tests will fail!\n";
              $RTTOV_dir = undef;
          }

      } else { # Loblolly
          $RTTOV_dir = "/loblolly/kavulich/libs/rttov/$Compiler";
          if (-d $RTTOV_dir) {
              $ENV{RTTOV} = $RTTOV_dir;
              print "Using RTTOV libraries in $RTTOV_dir\n";
          } else {
              print "$RTTOV_dir DOES NOT EXIST\n";
              print "RTTOV Libraries have not been compiled with $Compiler\nRTTOV tests will fail!\n";
              $RTTOV_dir = undef;
          }

      }
      foreach my $key (keys %Compile_options) {
          if ($Compile_options{$key} =~/sm/i) {
              print "Note: shared-memory option $Compile_options{$key} was deleted for gfortran.\n";
              foreach my $name (keys %Experiments) {
                  foreach my $par (keys %{$Experiments{$name}{paropt}}) {
                      delete $Experiments{$name}{paropt}{$par} if $par eq $Compile_options{$key} ;
                      next ;
                  }
              }
              delete $Compile_options{$key};
          }
      }
   } elsif ($Arch eq "Darwin") {   # Darwin
      $RTTOV_dir = "$MainDir/libs/rttov_$Compiler\_$Compiler_version";
      if (-d $RTTOV_dir) {
          $ENV{RTTOV} = $RTTOV_dir;
          print "Using RTTOV libraries in $RTTOV_dir\n";
      } else {
          print "$RTTOV_dir DOES NOT EXIST\n";
          print "RTTOV Libraries have not been compiled with $Compiler\nRTTOV tests will fail!\n";
          $RTTOV_dir = undef;
      }
   }

#For cycle jobs, WRF must exist. Will add capability to compile WRF in the (near?) future
  if ($Type =~ /CYCLING/i) {
     if (-d "$MainDir/WRFV3_$Compiler") {
        print "Will use WRF code in $MainDir/WRFV3_$Compiler for CYCLING test\n";
     } else {
        print "\n$MainDir/WRFV3_$Compiler DOES NOT EXIST\n";
        print "Removing cycling tests...\n\n";
        foreach my $name (keys %Experiments) {
           foreach my $type ($Experiments{$name}{test_type}) {
              if ($type =~ /CYCLING/i) {
                 delete $Experiments{$name};
                 print "Deleting Cycling experiment $name from test list.\n\n";
                 next ;
              }
           }
        }
        printf "\nNew list of experiments : \n";
        printf "#INDEX   EXPERIMENT                   TYPE             CPU_MPI  CPU_OPENMP    PAROPT\n";
        printf "%-4d     %-27s  %-16s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n",
             $Experiments{$_}{index}, $_, $Experiments{$_}{test_type},$Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
                 keys%{$Experiments{$_}{paropt}} for (keys %Experiments);
        sleep 2; #Pause to let user see new list

     }
  }



#######################  BEGIN COMPILE 4DVAR  ########################

# Set WRFPLUSDIR (for 4DVAR dmpar tests) and/or WRFPLUSDIR_serial (for 4dvar serial tests)
my $WRFPLUSDIR;
my $WRFPLUSDIR_serial;
if ($Par_4dvar =~ /dmpar/i) {
    # Set WRFPLUS_DIR Environment variable
    $WRFPLUSDIR = $MainDir."/WRFPLUSV3_$Compiler";
    chomp($WRFPLUSDIR);
    print "4DVAR dmpar tests specified: checking for WRFPLUS code in directory $WRFPLUSDIR.\n";
    if (-d $WRFPLUSDIR) {
        $ENV{WRFPLUS_DIR} = $WRFPLUSDIR;
        print "Checking WRFPLUS revision ...\n";
        $WRFPLUS_Revision = &get_repo_revision("$WRFPLUSDIR");
    } else {
        print "\n$WRFPLUSDIR DOES NOT EXIST\n";
        print "\nNOT COMPILING FOR 4DVAR DMPAR!\n";

        foreach my $name (keys %Experiments) {
            if ($Experiments{$name}{test_type} =~ /4DVAR/i) {
               foreach my $par ($Experiments{$name}{paropt}) {
                   delete $Experiments{$name}{paropt}{$par} if ($par =~ /dmpar/i) ;
                   if ((keys %{$Experiments{$name}{paropt}}) > 0) {
                      print "\nDeleting 4DVAR dmpar experiment $name from test list.\n";
                   } else {
                      delete $Experiments{$name};
                      $Type =~ s/4DVAR//gi;
                      print "\nDeleting 4DVAR experiment $name from test list.\n";
                      next ;
                   }
                }
            }
        }
    printf "\nNew list of experiments : \n";
    printf "#INDEX   EXPERIMENT                   TYPE             CPU_MPI  CPU_OPENMP    PAROPT\n";
    printf "%-4d     %-27s  %-16s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n",
         $Experiments{$_}{index}, $_, $Experiments{$_}{test_type},$Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
             keys%{$Experiments{$_}{paropt}} for (keys %Experiments);
    sleep 2; #Pause to let user see new list
    }
}

if ($Par_4dvar =~ /serial/i) {
    # Set WRFPLUS_DIR Environment variable
    $WRFPLUSDIR_serial = $MainDir."/WRFPLUSV3_$Compiler\_serial";
    chomp($WRFPLUSDIR_serial);
    print "4DVAR serial tests specified: checking for WRFPLUS code in directory $WRFPLUSDIR_serial.\n";
    if (-d $WRFPLUSDIR_serial) {
        if ($WRFPLUS_Revision eq "NONE") {
           print "Checking WRFPLUS revision ...\n";
           $WRFPLUS_Revision = &get_repo_revision("$WRFPLUSDIR_serial");
        }
    } else {
        print "\n$WRFPLUSDIR_serial DOES NOT EXIST\n";
        print "\nNOT COMPILING FOR 4DVAR SERIAL!\n";

        foreach my $name (keys %Experiments) {
            if ($Experiments{$name}{test_type} =~ /4DVAR/i) {
               foreach my $par ($Experiments{$name}{paropt}) {
                   delete $Experiments{$name}{paropt}{$par} if ($par =~ /serial/i) ;
                   if ((keys %{$Experiments{$name}{paropt}}) > 0) {
                      print "\nDeleting 4DVAR serial experiment $name from test list.\n";
                   } else {
                      delete $Experiments{$name};
                      $Type =~ s/4DVAR//gi;
                      print "\nDeleting 4DVAR experiment $name from test list.\n";
                      next ;
                   }
                }
            }
        }
    printf "\nNew list of experiments : \n";
    printf "#INDEX   EXPERIMENT                   TYPE             CPU_MPI  CPU_OPENMP    PAROPT\n";
    printf "%-4d     %-27s  %-16s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n",
         $Experiments{$_}{index}, $_, $Experiments{$_}{test_type},$Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
             keys%{$Experiments{$_}{paropt}} for (keys %Experiments);
    sleep 2; #Pause to let user see new list
    }
}


if ($Type =~ /4DVAR/i) {

   foreach (split /\|/, $Par_4dvar) { #foreach1
      my $par_type = $_;

      # Set WRFPLUS_DIR for this build
      if ($par_type eq "dmpar") {
         $ENV{WRFPLUS_DIR} = "$WRFPLUSDIR";
      } elsif ($par_type eq "serial") {
         $ENV{WRFPLUS_DIR} = $WRFPLUSDIR_serial;
      }

      # Get WRFDA code

      if ( -e "WRFDA_4DVAR_$par_type" && -r "WRFDA_4DVAR_$par_type" ) {
         printf "Deleting the old WRFDA_4DVAR_$par_type directory ... \n";
         #Delete in background to save time rather than using "rmtree"
         ! system("mv", "WRFDA_4DVAR_$par_type", ".WRFDA_4DVAR_$par_type") or die "Can not move 'WRFDA_4DVAR_$par_type' to '.WRFDA_4DVAR_$par_type for deletion': $!\n";
         ! system("rm -rf .WRFDA_4DVAR_$par_type &") or die "Can not remove WRFDA_4DVAR_$par_type: $!\n";
      }

      if ($Source eq "REPO") {
         print "Getting the code from repository $CODE_REPO to WRFDA_4DVAR_$par_type ...\n";
         # SHOULD CREATE CUSTOM FUNCTION FOR GIT CHECKOUT EVENTUALLY
         ! system ("svn","co","-q","-r",$Revision,$CODE_REPO,"WRFDA_4DVAR_$par_type") or die " Can't run svn checkout: $!\n";
         if ($Revision eq 'HEAD') {
            $Revision = &get_repo_revision("WRFDA_4DVAR_$par_type");
         }
         printf "Revision %5d successfully checked out to WRFDA_4DVAR_$par_type.\n",$Revision;
      } else {
         print "Getting the code from $Source to WRFDA_4DVAR_$par_type ...\n";
         ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
         ! system("mv", "WRFDA", "WRFDA_4DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_4DVAR_$par_type': $!\n";
         $Revision = &get_repo_revision("WRFDA_4DVAR_$par_type");
      }

      # Change the working directory to WRFDA:
      chdir "WRFDA_4DVAR_$par_type" or die "Cannot chdir to WRFDA_4DVAR_$par_type: $!\n";

      # Delete unnecessary directories to test code in release style
      if ( -e "chem" && -r "chem" ) {
         printf "Deleting chem directory ... ";
         rmtree ("chem") or die "Can not rmtree chem :$!\n";
      }
      if ( -e "dyn_nmm" && -r "dyn_nmm" ) {
         printf "Deleting dyn_nmm directory ... ";
         rmtree ("dyn_nmm") or die "Can not rmtree dyn_nmm :$!\n";
      }
      if ( -e "hydro" && -r "hydro" ) {
         printf "Deleting hydro directory ... ";
         rmtree ("hydro") or die "Can not rmtree hydro :$!\n";
      }

      # Locate the compile options base on the $compiler:
      my $pid = open2( my $readme, my $writeme, './configure','4dvar');
      print $writeme "1\n";
      my @output = <$readme>;
      waitpid($pid,0);
      close ($readme);
      close ($writeme);

      my $option;

      $count = 0;
      foreach (@output) {
         my $config_line = $_ ;

         if (($config_line=~ m/(\d+)\.\s\($par_type\) .* $Compiler\/$CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) &&
             ! ($config_line=~/MIC/) &&
             ! ($config_line=~/HSW/) ) {
            $Compile_options_4dvar{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif (($config_line=~ m/(\d+)\.\s\($par_type\) .* $Compiler .* $CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) &&
             ! ($config_line=~/MIC/) &&
             ! ($config_line=~/HSW/) ) {
            $Compile_options_4dvar{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif ( ($config_line=~ m/(\d+)\. .* $Compiler .* $CCompiler .* ($par_type) .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i)  ) {
            $Compile_options_4dvar{$1} = $par_type;
            $option = $1;
            $count++;
         }
      }

      if ($count > 1) {
         print "Number of options found: $count\n";
         print "Options: ";
         while ( my ($key, $value) = each(%Compile_options_4dvar) ) {
            print "$key,";
         }
         print "\nSelecting option '$option'. THIS MAY NOT BE IDEAL.\n";
      } elsif ($count < 1 ) {
         die "\nSHOULD NOT DIE HERE\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (Yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (visit-a05): pgi, g95 \n\n";
      }

      printf "\nFound 4DVAR compilation option for %6s, option %2d.\n",$Compile_options_4dvar{$option}, $option;


      # Compile the code:


      # configure 4dvar
      my $status = system ('./clean -a 1>/dev/null  2>/dev/null');
      die "clean -a exited with error $!\n" unless $status == 0;
      if ( $Debug == 2 ) {
         $pid = open2($readme, $writeme, './configure','-D','4dvar');
      } elsif ( $Debug == 1 ) {
         $pid = open2($readme, $writeme, './configure','-d','4dvar');
      } else {
         $pid = open2($readme, $writeme, './configure','4dvar');
      }
      print $writeme "$option\n";
      @output = <$readme>;
      waitpid($pid,0);
      close ($readme);
      close ($writeme);

      # compile all_wrfvar
      if ( $Debug == 2 ) {
         printf "Compiling in super-debug mode, compilation optimizations turned off, debugging features turned on.\n";
      } elsif ( $Debug == 1 ) {
         printf "Compiling in debug mode, compilation optimizations turned off.\n";
      }


      if ( ($Parallel_compile_num > 1) && ($Machine_name =~ /yellowstone/i) ) {
         printf "Submitting job to compile WRFDA_4DVAR_$par_type with %10s for %6s ....\n", $Compiler, $Compile_options_4dvar{$option};


         # Generate the LSF job script
         open FH, ">job_compile_4dvar_$Compile_options_4dvar{$option}_opt${option}.csh" or die "Can not open job_compile_4dvar_${option}.csh to write. $! \n";
         print FH '#!/bin/csh'."\n";
         print FH '#',"\n";
         print FH '# LSF batch script'."\n";
         print FH '#'."\n";
         print FH "#BSUB -J compile_4dvar_$Compile_options_4dvar{$option}_opt${option}"."\n";
         print FH "#BSUB -q ".$Compile_queue."\n";
         print FH "#BSUB -n $Parallel_compile_num\n";
         print FH "#BSUB -o job_compile_4dvar_$Compile_options_4dvar{$option}_opt${option}.output"."\n";
         print FH "#BSUB -e job_compile_4dvar_$Compile_options_4dvar{$option}_opt${option}.error"."\n";
         print FH "#BSUB -W 100"."\n";
         print FH "#BSUB -P $Project"."\n";
         printf FH "#BSUB -R span[ptile=%d]"."\n", $Parallel_compile_num;
         print FH "\n";
         print FH "setenv J '-j $Parallel_compile_num'\n";
         if (defined $RTTOV_dir) {print FH "setenv RTTOV $RTTOV_dir\n"};
         print FH "./compile all_wrfvar >& compile.log.$Compile_options_4dvar{$option}\n";
         print FH "\n";
         close (FH);

         # Submit the job
         my $submit_message;
         $submit_message = `bsub < job_compile_4dvar_$Compile_options_4dvar{$option}_opt${option}.csh`;

         if ($submit_message =~ m/.*<(\d+)>/) {;
            print "Job ID for 4DVAR $Compiler option $Compile_options_4dvar{$option} is $1 \n";
            $compile_job_array{$1} = "4DVAR_$Compile_options_4dvar{$option}";
            push (@compile_job_list,$1);
         } else {
            die "\nFailed to submit 4DVAR compile job for $Compiler option $Compile_options_4dvar{$option}!\n";
         };

      } else { #Serial compile OR non-Yellowstone compile

         printf "Compiling WRFDA_4DVAR_$par_type with %10s for %6s ....\n", $Compiler, $Compile_options_4dvar{$option};

         # Fork each compilation
         $pid = fork();
         if ($pid) {
            print "pid is $pid, parent $$\n";
            push(@childs, $pid);
         } elsif ($pid == 0) {
            my $begin_time = gettimeofday();
            if (! open FH, ">compile.log.$Compile_options_4dvar{$option}") {
               print "Can not open file compile.log.$Compile_options_4dvar{$option}.\n";
               exit 1;
            }
            $pid = open (PH, "./compile all_wrfvar 2>&1 |");
            while (<PH>) {
               print FH;
            }
            close (PH);
            close (FH);
            my $end_time = gettimeofday();

            # Check if the compilation is successful:

            @exefiles = &check_executables;

            if (@exefiles) {
               print "\nThe following executables were not created for 4DVAR, $par_type: check your compilation log.\n";
               foreach ( @exefiles ) {
                  print "  $_\n";
               }
               exit 2
            }

            # Rename the main executable:
            if (! rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options_4dvar{$option}") {
               print "Program da_wrfvar.exe not created for 4DVAR, $par_type: check your compilation log.\n";
               exit 3;
            }

            # Check other executables for failures

            printf "\nCompilation of WRFDA_4DVAR_$par_type with %10s compiler for %6s was successful.\nCompilation took %4d seconds.\n",
                 $Compiler, $Compile_options_4dvar{$option}, ($end_time - $begin_time);

            # Save the compilation log file

            if (!-d "$MainDir/regtest_compile_logs/$year$mon$mday") {
               if (! mkpath("$MainDir/regtest_compile_logs/$year$mon$mday")) {
                  print "mkpath failed: $!\n$MainDir/regtest_compile_logs/$year$mon$mday";
                  exit 4;
               }
            }
            if (! copy( "compile.log.$Compile_options_4dvar{$option}", "../regtest_compile_logs/$year$mon$mday/compile_4dvar.log.$Compile_options_4dvar{$option}_$Compiler\_$hour:$min:$sec" )) {
               print "Copy failed: $!\ncompile.log.$Compile_options_4dvar{$option}\n../regtest_compile_logs/$year$mon$mday/compile_4dvar.log.$Compile_options_4dvar{$option}_$Compiler\_$hour:$min:$sec";
               exit 5;
            }

            exit 0; #Exit child process! Quite important or else you get stuck forever!
         } else {
            die "couldn't fork: $!\n";
         }



      }
      # Back to the upper directory:
      chdir ".." or die "Cannot chdir to .. : $!\n";

   } #end foreach1


########################  END COMPILE 4DVAR  #########################

}


#######################  BEGIN COMPILE 3DVAR  ########################
if ($Type =~ /3DVAR/i) {
#  my @par_type = split /\|/, $Par;

  foreach (split /\|/, $Par) { #foreach1
       my $par_type = $_;

       if ( -e "WRFDA_3DVAR_$par_type" && -r "WRFDA_3DVAR_$par_type" ) {
            printf "Deleting the old WRFDA_3DVAR_$par_type directory ... \n";
            #Delete in background to save time rather than using "rmtree"
            ! system("mv", "WRFDA_3DVAR_$par_type", ".WRFDA_3DVAR_$par_type") or die "Can not move 'WRFDA_3DVAR_$par_type' to '.WRFDA_3DVAR_$par_type for deletion': $!\n";
            ! system("rm -rf .WRFDA_3DVAR_$par_type &") or die "Can not remove WRFDA_3DVAR_$par_type: $!\n";
       }

       if ($Source eq "REPO") {
          print "Getting the code from repository $CODE_REPO to WRFDA_3DVAR_$par_type ...\n";
          ! system ("svn","co","-q","-r",$Revision,$CODE_REPO,"WRFDA_3DVAR_$par_type") or die " Can't run svn checkout: $!\n";
          if ($Revision eq 'HEAD') {
             $Revision = &get_repo_revision("WRFDA_3DVAR_$par_type");
          }
          printf "Revision %5d successfully checked out to WRFDA_3DVAR_$par_type.\n",$Revision;
       } else {
          print "Getting the code from $Source to WRFDA_3DVAR_$par_type ...\n";
          ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
          ! system("mv", "WRFDA", "WRFDA_3DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_3DVAR_$par_type': $!\n";
          $Revision = &get_repo_revision("WRFDA_3DVAR_$par_type");
       }

 
       # Change the working directory to WRFDA:
     
       chdir "WRFDA_3DVAR_$par_type" or die "Cannot chdir to WRFDA_3DVAR_$par_type: $!\n";

       # Delete unnecessary directories to test code in release style
       if ( -e "chem" && -r "chem" ) {
          printf "Deleting chem directory ... ";
          rmtree ("chem") or die "Can not rmtree chem :$!\n";
       }
       if ( -e "dyn_nmm" && -r "dyn_nmm" ) {
          printf "Deleting dyn_nmm directory ... ";
          rmtree ("dyn_nmm") or die "Can not rmtree dyn_nmm :$!\n";
       }
       if ( -e "hydro" && -r "hydro" ) {
          printf "Deleting hydro directory ... ";
          rmtree ("hydro") or die "Can not rmtree hydro :$!\n";
       }

       # Locate the compile options base on the $compiler:
       my $pid = open2( my $readme, my $writeme, './configure','wrfda','2>/dev/null');
       print $writeme "1\n";
       my @output = <$readme>;
       waitpid($pid,0);
       close ($readme);
       close ($writeme);


#       # Add a slash before '+' in $par_type. Needed for dm+sm support!
       my $par_type_configure = $par_type;
       $par_type_configure =~ s/\+/\\+/g;

       my $option;

      $count = 0;
      foreach (@output) {
         my $config_line = $_ ;
         if (($config_line=~ m/(\d+)\.\s\($par_type_configure\) .* $Compiler\/$CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) &&
             ! ($config_line=~/MIC/) &&
             ! ($config_line=~/HSW/) ) {
            $Compile_options{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif ( ($config_line=~ m/(\d+)\.\s\($par_type_configure\) .* $Compiler .* $CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) &&
             ! ($config_line=~/MIC/) &&
             ! ($config_line=~/HSW/) ) {
            $Compile_options{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif ( ($config_line=~ m/(\d+)\. .* $Compiler .* $CCompiler .* ($par_type_configure) .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i)  ) {
            $Compile_options{$1} = $par_type;
            $option = $1;
            $count++;
         }
      }

      if ($count > 1) {
         print "Number of options found: $count\n";
         print "Options: ";
         while ( my ($key, $value) = each(%Compile_options) ) {
            print "$key,";
         }
         print "\nSelecting option '$option'. THIS MAY NOT BE IDEAL.\n";
      } elsif ($count < 1 ) {
         die "\nSHOULD NOT DIE HERE\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (Yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (visit-a05): pgi, g95 \n\n";
      }

      printf "\nFound 3DVAR compilation option for %6s, option %2d.\n",$Compile_options{$option}, $option;


       # Compile the code:

        # configure wrfda
        my $status = system ('./clean -a 1>/dev/null  2>/dev/null');
        die "clean -a exited with error $!\n" unless $status == 0;
        if ( $Debug == 2 ) {
            $pid = open2($readme, $writeme, './configure','-D','wrfda');
        } elsif ( $Debug == 1 ) {
            $pid = open2($readme, $writeme, './configure','-d','wrfda');
        } else {
            $pid = open2($readme, $writeme, './configure','wrfda','2>/dev/null');
        }
        print $writeme "$option\n";
        @output = <$readme>;
        waitpid($pid,0);
        close ($readme);
        close ($writeme);

        # compile all_wrfvar
        if ( $Debug == 2 ) {
            printf "Compiling in super-debug mode, compilation optimizations turned off, debugging features turned on.\n";
        } elsif ( $Debug == 1 ) {
            printf "Compiling in debug mode, compilation optimizations turned off.\n";
        }

        if ( ($Parallel_compile_num > 1) && ($Machine_name =~ /yellowstone/i) ) { 
        printf "Submitting job to compile WRFDA_3DVAR_$par_type with %10s for %6s ....\n", $Compiler, $Compile_options{$option};


            # Generate the LSF job script
            open FH, ">job_compile_3dvar_$Compile_options{$option}_opt${option}.csh" or die "Can not open job_compile_3dvar_${option}.csh to write. $! \n";
            print FH '#!/bin/csh'."\n";
            print FH '#',"\n";
            print FH '# LSF batch script'."\n";
            print FH '#'."\n";
            print FH "#BSUB -J compile_3dvar_$Compile_options{$option}_opt${option}"."\n";
            print FH "#BSUB -q ".$Compile_queue."\n";
            print FH "#BSUB -n $Parallel_compile_num\n";
            print FH "#BSUB -o job_compile_3dvar_$Compile_options{$option}_opt${option}.output"."\n";
            print FH "#BSUB -e job_compile_3dvar_$Compile_options{$option}_opt${option}.error"."\n";
            print FH "#BSUB -W 100"."\n";
            print FH "#BSUB -P $Project"."\n";
            printf FH "#BSUB -R span[ptile=%d]"."\n", $Parallel_compile_num;
            print FH "\n";
            if (defined $RTTOV_dir) {print FH "setenv RTTOV $RTTOV_dir\n"};
            print FH "setenv J '-j $Parallel_compile_num'\n";
            print FH "./compile all_wrfvar >& compile.log.$Compile_options{$option}\n";
            print FH "\n";
            close (FH);

 #           my $BSUB="bsub -K -q $Compile_queue -P $Project -n $Parallel_compile_num -a poe -W 100 -J compile_3dvar_$Compile_options{$option}_opt${option} -o job_compile_3dvar_$Compile_options{$option}_opt${option}.out -e job_compile_3dvar_$Compile_options{$option}_opt${option}.err";

            # Submit the job
 
            my $submit_message;
            $submit_message = `bsub < job_compile_3dvar_$Compile_options{$option}_opt${option}.csh`;


            if ($submit_message =~ m/.*<(\d+)>/) {;
                print "Job ID for 3DVAR $Compiler option $Compile_options{$option} is $1 \n";
                $compile_job_array{$1} = "3DVAR_$Compile_options{$option}";
                push (@compile_job_list,$1);
            } else {
                die "\nFailed to submit 3DVAR compile job for $Compiler option $Compile_options{$option}!\n";
            };

        } else { #Serial compile OR non-Yellowstone compile
            printf "Compiling WRFDA_3DVAR_$par_type with %10s for %6s ....\n", $Compiler, $Compile_options{$option};

            #Fork each compilation
            $pid = fork();
            if ($pid) {
               print "pid is $pid, parent $$\n";
               push(@childs, $pid);
            } elsif ($pid == 0) {
               my $begin_time = gettimeofday();
               if (! open FH, ">compile.log.$Compile_options{$option}") {
                  print "Can not open file compile.log.$Compile_options{$option}.\n";
                  exit 1;
               }
               $pid = open (PH, "./compile all_wrfvar 2>&1 |");
               while (<PH>) {
                  print FH;
               }
               close (PH);
               close (FH);
               my $end_time = gettimeofday();

               # Check if the compilation is successful:

               @exefiles = &check_executables;

               if (@exefiles) {
                  print "\nThe following executables were not created for 3DVAR, $par_type: check your compilation log.\n";
                  foreach ( @exefiles ) {
                     print "  $_\n";
                  }
                  exit 2
               }
     
               # Rename the main executable:
               if (! rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options{$option}") {
                  print "Program da_wrfvar.exe not created for 3DVAR, $par_type: check your compilation log.\n";
                  exit 3;
               }

               printf "\nCompilation of WRFDA_3DVAR_$par_type with %10s compiler for %6s was successful.\nCompilation took %4d seconds.\n",
                    $Compiler, $Compile_options{$option}, ($end_time - $begin_time);

               # Save the compilation log file

               if (!-d "$MainDir/regtest_compile_logs/$year$mon$mday") {
                  if (! mkpath("$MainDir/regtest_compile_logs/$year$mon$mday")) {
                     print "mkpath failed: $!\n$MainDir/regtest_compile_logs/$year$mon$mday";
                     exit 4;
                  }
               }
               if (! copy( "compile.log.$Compile_options{$option}", "../regtest_compile_logs/$year$mon$mday/compile.log.$Compile_options{$option}_$Compiler\_$hour:$min:$sec" )) {
                  print "Copy failed: $!\ncompile.log.$Compile_options{$option}\n../regtest_compile_logs/$year$mon$mday/compile.log.$Compile_options{$option}_$Compiler\_$hour:$min:$sec";
                  exit 5;
               }

               exit 0; #Exit child process (0 indicates success). Quite important or else you get stuck forever!
            } else {
               die "couldn't fork: $!\n";
            }
        }

  # Back to the upper directory:
  chdir ".." or die "Cannot chdir to .. : $!\n";

  } #end foreach1


#######################  END COMPILE 3DVAR  ########################

}

#For forked jobs, need to wait for forked compilations to complete
foreach (@childs) {
   my $res = waitpid($_, 0);
   unless ($? == 0) {
      die "Child process exited with error: ", $_;
   }
}

#Because Perl is Perl, must create a temporary array to modify while in "for" loop
my @temparray = @compile_job_list;


# For batch build, keep track of ongoing compile jobs, continue when finished.
while ( @compile_job_list ) {
   # Remove '|' from start of "compile_job_list"

   for my $i ( 0 .. $#compile_job_list ) {
      my $jobnum = $compile_job_list[$i];
      my $feedback = `bjobs $jobnum`;
      if ( ($feedback =~ m/RUN/) || ( $feedback =~ m/PEND/ ) ) {; # Still pending or running
         next;
      }

      # Job not found, so assume it's done!
      my $bhist = `bhist $jobnum`;
      my @jobhist = split('\s+',$bhist);
      print "Job $compile_job_array{$jobnum} (job number $jobnum) is finished!\n It took $jobhist[24] seconds\n";

      # Save the compilation log file
      if (!-d "$MainDir/regtest_compile_logs/$year$mon$mday") {
         mkpath("$MainDir/regtest_compile_logs/$year$mon$mday") or die "mkpath failed: $!\n$MainDir/regtest_compile_logs/$year$mon$mday";
      }
      my @details = split /_/, $compile_job_array{$jobnum};
      copy( "WRFDA_$compile_job_array{$jobnum}/compile.log.$details[1]", "regtest_compile_logs/$year$mon$mday/compile_$details[1].log.$details[0]_$Compiler\_$hour:$min:$sec" ) or die "Copy failed: $!\nWRFDA_$compile_job_array{$jobnum}/compile.log.$details[1]\nregtest_compile_logs/$year$mon$mday/compile_$details[1].log.$details[0]_$Compiler\_$hour:$min:$sec";

      # Check that all executables were created
      @exefiles = &check_executables("WRFDA_$compile_job_array{$jobnum}");

      if (@exefiles) {
         print "\nThe following executables were not created for $details[0], $details[1]: check your compilation log.\n";
         foreach ( @exefiles ) {
            print "  $_\n";
         }
         die "Exiting $0\n";
      }

      rename "WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe","WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe.$Compiler.$details[1]" or die "\nSERIOUS ERROR\nSERIOUS ERROR\nHow on earth did you even get here? The script should have already failed if the main executable doesn't exist!\nProgram da_wrfvar.exe not created for $details[0], $details[1]: check your compilation log.\n";

      # Delete job from list of active jobs
      splice (@temparray,$i,1);
      last;
   }

   @compile_job_list = @temparray;

   sleep 5;
}



SKIP_COMPILE:

if ($Type =~ /3DVAR/i) {
   if ( $Par =~ /serial/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in serial in directory tree named 'WRFDA_3DVAR_serial' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_serial");
   }
   if ( $Par =~ /smpar/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in serial in directory tree named 'WRFDA_3DVAR_serial' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_smpar");
   }
   if ( $Par =~ /dmpar/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in parallel in directory tree named 'WRFDA_3DVAR_dmpar' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_dmpar");
   }
   if ( $Par =~ /dm\+sm/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in parallel in directory tree named 'WRFDA_3DVAR_dmpar' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_dm+sm");
   }
}
if ($Type =~ /4DVAR/i) {
   if ( $Par_4dvar =~ /serial/i ) {
      die "\nSTOPPING SCRIPT\n4DVAR code must be compiled to run in serial in directory tree named 'WRFDA_4DVAR_serial' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_4DVAR_serial");
   }
   if ( $Par_4dvar =~ /dmpar/i ) {
      die "\nSTOPPING SCRIPT\n4DVAR code must be compiled to run in parallel in directory tree named 'WRFDA_4DVAR_dmpar' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_4DVAR_dmpar");
   }
}



# Hack to find correct dynamic libraries for HDF5 with gfortran/pgi:
if ( (-d "$MainDir/libs/HDF5_$Compiler\_$Compiler_version") && ($use_HDF5 eq "yes") && ( ($Compiler eq "gfortran") || ($Compiler eq "pgi") ) ) {
   $ENV{LD_LIBRARY_PATH}="$ENV{LD_LIBRARY_PATH}:$MainDir/libs/HDF5_$Compiler\_$Compiler_version/lib";
   print "Adding $ENV{HDF5}/lib to \$LD_LIBRARY_PATH \n";
}


# Make working directory for each Experiments:


if ( ($Machine_name eq "yellowstone") ) {
    printf "Moving to scratch space: /glade/scratch/$ThisGuy/REGTEST/workdir/$Compiler\_$year$mon$mday\_$hour:$min:$sec\n";
    mkpath("/glade/scratch/$ThisGuy/REGTEST/workdir/$Compiler\_$year$mon$mday\_$hour:$min:$sec") or die "Mkdir failed: $!";
    chdir "/glade/scratch/$ThisGuy/REGTEST/workdir/$Compiler\_$year$mon$mday\_$hour:$min:$sec" or die "Chdir failed: $!";
}

foreach my $name (keys %Experiments) {

     # Make working directory:

     if ( -e $name && -r $name ) {
          rmtree ($name) or die "Can not rmtree $name :$!\n";
     }
     mkdir "$name", 0755 or warn "Cannot make $name directory: $!\n";
     if ( ($Machine_name eq "yellowstone") ) {
         if ( -l "$MainDir/$name") {unlink "$MainDir/$name" or die "Cannot unlink '$MainDir/$name'"}
         my $CurrDir = `pwd`;chomp $CurrDir;
         symlink "$CurrDir/$name", "$MainDir/$name"
             or warn "Cannot symlink '$CurrDir/$name' to main directory '$MainDir'";
     }

     unless ( -e "$Database/$name" ) {
         die "DATABASE NOT FOUND: '$Database/$name'\n";
     }
     # Symbolically link all files ;

     chdir "$name" or die "Cannot chdir to $name : $!\n";
     my @allfiles = glob ("$Database/$name/*");
     foreach (@allfiles) {
         if ($_ =~ "namelist.input") {
            copy("$_", basename($_)) or warn "Cannot copy $_ to local directory: $!\n";
         } else {
            symlink "$_", basename($_) or warn "Cannot symlink $_ to local directory: $!\n";
         }
     }
     
     mkdir "trace"; #Make trace directory for "trace_use" option

     printf "The directory for %-30s is ready.\n",$name;

     # Back to the upper directory:

     chdir ".." or die "Cannot chdir to .. : $!\n";

}

# Submit the jobs for each task and check the status of each task recursively:

# How many experiments do we have ?

 my $remain_exps = scalar keys %Experiments;  

#How many jobs do we have for each experiment ?

 my %remain_par;
 $remain_par{$_} = scalar keys %{$Experiments{$_}{paropt}} 
    for keys %Experiments;

# preset the the status of all jobs and subjobs (types)

 foreach my $name (keys %Experiments) {
    $Experiments{$name}{status} = "open"; # "open" indicates nothing is going on in this test directory, so it's safe to submit a new job
    foreach my $par (keys %{$Experiments{$name}{paropt}}) {
       $Experiments{$name}{paropt}{$par}{status} = "pending";
       $Experiments{$name}{paropt}{$par}{result} = "--";
       $Experiments{$name}{paropt}{$par}{walltime} = 0;
       $Experiments{$name}{paropt}{$par}{started} = 0;
       $Experiments{$name}{paropt}{$par}{cpu_mpi} = ( ($par eq 'serial') || ($par eq 'smpar') ) ? 1 : $Experiments{$name}{cpu_mpi};
       $Experiments{$name}{paropt}{$par}{cpu_openmp} = ( ($par eq 'serial') || ($par eq 'dmpar') ) ? 1 : $Experiments{$name}{cpu_openmp};
    } 
 } 

# Initial Status:

 &flush_status ();

# submit job:

 if ( ($Machine_name eq "yellowstone") ) {
    &submit_job_ys ;
    chdir "$MainDir";
 } else {
    &submit_job ;
 }

# End time:

 my $End_time;
 $tm = localtime;
 $End_time=sprintf "End   : %02d:%02d:%02d-%04d/%02d/%02d\n",
      $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

# Create the webpage:

&create_webpage ();

# Mail out summary:

open (SENDMAIL, "|/usr/sbin/sendmail -oi -t -odq")
       or die "Can't fork for sendmail: $!\n";

print SENDMAIL  "From: $Tester\n";
print SENDMAIL  "To: $Tester\@ucar.edu"."\n";
print SENDMAIL  "Subject: Regression test summary\n";
print SENDMAIL "Content-Type: text/html; charset=ISO-8859-1\n\n";

print SENDMAIL "<html>";
print SENDMAIL "<body>";
print SENDMAIL "<p>";
print SENDMAIL $Start_time."<br>";
print SENDMAIL "Source: ",$Source."<br>";
if ( $Source eq "REPO" ) {
    print SENDMAIL '<li>'."Repository location : $CODE_REPO".'</li>'."\n";
}
print SENDMAIL "Revision: ",$Revision."<br>";
if ( $WRFPLUS_Revision ne "NONE" ) {
    print SENDMAIL "WRFPLUS Revision: ",$WRFPLUS_Revision."<br>";
}
print SENDMAIL "Tester: ",$Tester."<br>";
print SENDMAIL "Machine name: ",$Host."<br>";
print SENDMAIL "Operating system: ",$System,", ",$Machine."<br>";
print SENDMAIL "Compiler: ",$Compiler." ".$Compiler_version."<br>";
print SENDMAIL "Baseline: ",$Baseline."<br>";
print SENDMAIL "<br>";
if ( $Machine_name eq "yellowstone" ) {
    print SENDMAIL "Test output can be found at '/glade/scratch/".$ThisGuy."/REGTEST/workdir/"
                    .$Compiler."_".$year.$mon.$mday."_".$hour.":".$min.":".$sec."'<br>";
    print SENDMAIL "<br>";
}
print SENDMAIL "<pre>";
print SENDMAIL @Message;
print SENDMAIL "</pre>";
print SENDMAIL $End_time."<br>";
print SENDMAIL "</body>";
print SENDMAIL "</html>";

close(SENDMAIL);

#
#
#

sub create_webpage {

    open WEBH, ">summary_$Machine_name\_$Compiler\_$Compiler_version.html" or
        die "Can not open summary_$Machine_name\_$Compiler\_$Compiler_version.html for write: $!\n";

    print WEBH '<html>'."\n";
    print WEBH '<body>'."\n";

    print WEBH '<p>'."Regression Test Summary:".'</p>'."\n";
    print WEBH '<ul>'."\n";
    print WEBH '<li>'.$Start_time.'</li>'."\n";
    print WEBH '<li>'."Source : $Source".'</li>'."\n";
if ( $Source eq "REPO" ) {
    print WEBH '<li>'."Repository location : $CODE_REPO".'</li>'."\n";
}
if ( $WRFPLUS_Revision ne "NONE" ) {
    print WEBH '<li>'."WRFPLUS Revision : $WRFPLUS_Revision".'</li>'."\n";
}
    print WEBH '<li>'."Tester : $Tester".'</li>'."\n";
    print WEBH '<li>'."Machine name : $Host".'</li>'."\n";
    print WEBH '<li>'."Operating system : $System".'</li>'."\n";
    print WEBH '<li>'."Compiler : $Compiler $Compiler_version".'</li>'."\n";
    print WEBH '<li>'."Baseline : $Baseline".'</li>'."\n";
    print WEBH '<li>'.$End_time.'</li>'."\n";
    print WEBH '</ul>'."\n";
if ( $Machine_name eq "yellowstone" ) {
    print WEBH "Test output can be found at '/glade/scratch/".$ThisGuy."/REGTEST/workdir/"
                    .$Compiler."_".$year.$mon.$mday."_".$hour.":".$min.":".$sec."'<br>";
    print WEBH "<br>";
}

    print WEBH '<table border="1">'."\n";
#   print WEBH '<caption>Regression Test Summary</caption>'."\n";
    print WEBH '<tr>'."\n";
    print WEBH '<th>EXPERIMENT</th>'."\n";
    print WEBH '<th>PAROPT</th>'."\n";
    print WEBH '<th>CPU_MPI</th>'."\n";
    print WEBH '<th>CPU_OMP</th>'."\n";
    print WEBH '<th>JOB</th>'."\n";
    print WEBH '<th>STATUS</th>'."\n";
    print WEBH '<th>WALLTIME(S)</th>'."\n";
    print WEBH '<th>RESULT</th>'."\n";
    print WEBH '</tr>'."\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            print WEBH '<tr>'."\n";
            print WEBH '<tr';
            if ($Experiments{$name}{paropt}{$par}{status} eq "error") {
                print WEBH ' style="background-color:red;color:white" ';
            } elsif ($Experiments{$name}{paropt}{$par}{result} eq "diff") {
                print WEBH ' style="background-color:yellow" ';
            }
            printf WEBH ' rowspan="%1d" >'."\n",scalar keys %{$Experiments{$name}{paropt}{$par}{job}};
            print WEBH '<td>'.$name.'</td>'."\n";
            print WEBH '<td>'.$par.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{cpu_mpi}.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{cpu_openmp}.'</td>'."\n";
            print WEBH '<td> </td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{status}.'</td>'."\n";
            printf WEBH '<td>'."%5d".'</td>'."\n",
                         $Experiments{$name}{paropt}{$par}{walltime};
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{result}.'</td>'."\n";
            print WEBH '</tr>'."\n";
            my $job = 1;
            foreach (sort keys %{$Experiments{$name}{paropt}{$par}{job}}) {
                print WEBH '<tr>'."\n";
                print WEBH '<td colspan=3> </td>'."\n";
                print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{job}{$job}{jobname}.'</td>'."\n";
#                print WEBH '<td>'.$Experiments{$name}{cpu_openmp}.'</td>'."\n";
                print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{job}{$job}{status}.'</td>'."\n";
                printf WEBH '<td>'."%5d".'</td>'."\n",
                             $Experiments{$name}{paropt}{$par}{job}{$job}{walltime};
                print WEBH '<td> </td>'."\n";
                print WEBH '</tr>'."\n";
                $job ++;
            }
        }
    }
            print WEBH '</table>'."\n"; 

    print WEBH '</body>'."\n";
    print WEBH '</html>'."\n";

    close (WEBH);

# Save summary, send to internet if requested:

    if ( ($Machine_name eq "yellowstone") ) {
        copy("summary_$Compiler\_$Compiler_version.html","/glade/scratch/$ThisGuy/REGTEST/workdir/$Compiler\_$year$mon$mday\_$hour:$min:$sec/summary_$Compiler\_$Compiler_version.html");
    }


# This variable is just so that you have to respond to a prompt before issuing the scp command; this avoids timeout errors
    my $scp_warn=0;


    my $go_on='';

    if ( $Upload =~ /yes/i ) {
       if ( (!$Exec) && ($Revision =~ /\d+(M|m)$/) ) {
          $scp_warn ++;
          print "This revision appears to be modified, are you sure you want to upload the summary?\a\n";

          while ($go_on eq "") {
             $go_on = <STDIN>;
             chop($go_on);
             if ($go_on =~ /N/i) {
                print "Summary not uploaded to web.\n";
                return;
             } elsif ($go_on =~ /Y/i) {
             } else {
                print "Invalid input: ".$go_on;
                $go_on='';
             }
          }
       }

       my $numexp= scalar keys %Experiments;
       $go_on='';

       if ( $numexp < 28 ) {
          $scp_warn ++;
          print "This run only includes $numexp of 28 tests, are you sure you want to upload?\a\n";

          while ($go_on eq "") {
             $go_on = <STDIN>;
             chop($go_on);
             if ($go_on =~ /N/i) {
                print "Summary not uploaded to web.\n";
                return;
             } elsif ($go_on =~ /Y/i) {
             } else {
                print "Invalid input: ".$go_on;
                $go_on='';
             }
          }
       }

       $go_on='';
       unless ( $Source eq "REPO" ) {
          $scp_warn ++;
          print "This revision, '$Source', may not be the trunk version,\nare you sure you want to upload?\a\n";
          while ($go_on eq "") {
             $go_on = <STDIN>;
             chop($go_on);
             if ($go_on =~ /N/i) {
                print "Summary not uploaded to web.\n";
                return;
             } elsif ($go_on =~ /Y/i) {
             } else {
                print "Invalid input: ".$go_on;
                $go_on='';
             }
          }
       }

       unless ($scp_warn > 0) {
          print "Are you sure you want to upload a web summary?\a\n";
          while ($go_on eq "") {
             $go_on = <STDIN>;
             chop($go_on);
             if ($go_on =~ /N/i) {
                print "Summary not uploaded to web.\n";
                return;
             } elsif ($go_on =~ /Y/i) {
             } else {
                print "Invalid input: ".$go_on;
                $go_on='';
             }
          }
       }

       #If there is a diff or error, we will note that on the webpage
       my $status = 0;
CHECKRESULTS: foreach my $exp (sort keys %Experiments) {
          foreach my $parl (sort keys %{$Experiments{$exp}{paropt}}) {
             if ($Experiments{$exp}{paropt}{$parl}{status} eq "error") {
                $status = -1;
                last CHECKRESULTS;
             } elsif ($Experiments{$exp}{paropt}{$parl}{result} eq "diff") {
                $status = 1;
             }
          }
       }

       #Remove dashes and dots from js functions, since these are reserved characters
       my $Machine_name_js = $Machine_name;
       $Machine_name_js =~ s/\-//g;
       $Machine_name_js =~ s/\./_/g; #Convert dots to underscores

       my $Compiler_version_js = $Compiler_version;
       $Compiler_version_js =~ s/\-//g;
       $Compiler_version_js =~ s/\./_/g; #Convert dots to underscores

       #Create .js file which will display the test date on the webpage
       open WEBJS, ">${Machine_name}_${Compiler}_${Compiler_version}_date.js" or
           die "Can not open ${Machine_name}_${Compiler}_${Compiler_version}_date.js for write: $!\n";

       print WEBJS "function ${Machine_name_js}_${Compiler}_${Compiler_version_js}_date()\n";
       print WEBJS '{'."\n";

       if ($status == -1) {
          print WEBJS "        document.getElementById(\"${Machine_name_js}_${Compiler}_${Compiler_version_js}_update\").innerHTML = \"$year-$mon-$mday, revision $Revision, result: <b><span style=\\\"color:red\\\">ERROR(S)</b>\";\n";
       } elsif ($status == 1) {
          print WEBJS "        document.getElementById(\"${Machine_name_js}_${Compiler}_${Compiler_version_js}_update\").innerHTML = \"$year-$mon-$mday, revision $Revision, result: <b><span style=\\\"color:orange\\\">DIFF(S)</b>\";\n";
       } else {
          print WEBJS "        document.getElementById(\"${Machine_name_js}_${Compiler}_${Compiler_version_js}_update\").innerHTML = \"$year-$mon-$mday, revision $Revision, result: <b>ALL PASS</b>\";\n";
       }
       print WEBJS '}'."\n";
       close (WEBJS);


       my @uploadit = ("scp", "summary_${Machine_name}_${Compiler}_${Compiler_version}.html","${Machine_name}_${Compiler}_${Compiler_version}_date.js" , "$ThisGuy\@nebula.mmm.ucar.edu:/web/htdocs/wrf/users/wrfda/regression/");
       $status = system(@uploadit);
       if ($status == 0) {
          print "Summary successfully uploaded to: http://www.mmm.ucar.edu/wrf/users/wrfda/regression/summary_${Machine_name}_${Compiler}_${Compiler_version}.html\n";
       } else {
          print "Uploading 'summary_${Machine_name}_${Compiler}_${Compiler_version}.html' and '${Machine_name}_${Compiler}_${Compiler_version}_date.js' to web failed: $?\n";
       }
       unlink "$Machine_name\_$Compiler\_${Compiler_version}_date.js";
    }
}

sub refresh_status {

    my @mes; 

    push @mes, "Experiment                  Paropt      Job type        CPU_MPI  CPU_OMP  Status    Walltime (s)   Result\n";
    push @mes, "=============================================================================================================\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            push @mes, sprintf "%-28s%-12s%-16s%-9d%-9d%-10s%-15d%-7s\n",
                    $name, $par, $Experiments{$name}{test_type},
                    $Experiments{$name}{paropt}{$par}{cpu_mpi},
                    $Experiments{$name}{paropt}{$par}{cpu_openmp},
                    $Experiments{$name}{paropt}{$par}{status},
                    $Experiments{$name}{paropt}{$par}{walltime},
                    $Experiments{$name}{paropt}{$par}{result};
        }
    }

    push @mes, "=============================================================================================================\n";
    return @mes;
}

sub new_job {
     
     my ($nam, $com, $par, $cpun, $cpum, $types) = @_;

print "nam = $nam\n";
print "com = $com\n";
print "par = $par\n";
print "cpun = $cpun\n";
print "cpum = $cpum\n";
print "types = $types\n";
     my $feedback;
     my $starttime;
     my $endtime;
     my $h;
     my $i = 1; #jobnum loop counter

     # Enter into the experiment working directory:

     chdir "$nam" or die "Cannot chdir to $nam : $!\n";

     if ($types =~ /OBSPROC/i) {
         $types =~ s/OBSPROC//i;

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "OBSPROC";

         print "Running OBSPROC for $par job '$nam'\n";
         $starttime = gettimeofday();
         if ($types =~ /3DVAR/i) {
            $cmd="$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe 1>obsproc.out  2>obsproc.out";
            ! system($cmd) or die "Execution of obsproc failed: $!";
            @gtsfiles = glob ("obs_gts_*.3DVAR");
            copy("$gtsfiles[0]","ob.ascii") or warn "COULD NOT COPY OBSERVATION FILE $!";
            $endtime = gettimeofday();

            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
            $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
            if (-e "ob.ascii") {
               printf "OBSPROC complete\n";
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
            } else {
               printf "ob.ascii does not exist!\n";
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
               chdir "..";
               return "OBSPROC_FAIL";
            }
         } else {
            if ($types =~ /FGAT/i) {
               $cmd="$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe 1>obsproc.out  2>obsproc.out";
               ! system($cmd) or die "Execution of obsproc failed: $!";
               @gtsfiles = glob ("obs_gts_*.FGAT");
            } elsif ($types =~ /4DVAR/i) {
               $cmd="$MainDir/WRFDA_4DVAR_$par/var/obsproc/src/obsproc.exe 1>obsproc.out  2>obsproc.out";
               ! system($cmd) or die "Execution of obsproc failed: $!";
               @gtsfiles = glob ("obs_gts_*.4DVAR");
            }

            my $index = 0;
            foreach my $gtsfile (@gtsfiles) {
               $index ++;
               if ($index < 10) {
                  copy("$gtsfile","ob0$index.ascii") or warn "COULD NOT COPY OBSERVATION FILES $!"; 
               } else {
                  copy("$gtsfile","ob$index.ascii")  or warn "COULD NOT COPY OBSERVATION FILES $!";
               }
            }
            $endtime = gettimeofday();

            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
            $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
            if (-e "ob01.ascii") {
               printf "OBSPROC complete\n";
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
            } else {
               printf "ob01.ascii does not exist!\n";
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
               chdir "..";
               return "OBSPROC_FAIL";
            }

         }

     }


     if ($types =~ /GENBE/i) {
         $types =~ s/GENBE//i;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "GENBE";

         print "Running GEN_BE for $par job '$nam'\n";

         # Unpack forecasts tar file.
         ! system("tar -xf forecasts.tar")or die "Can't untar forecasts file: $!\n";

         # We need the script to see where the WRFDA directory is. See gen_be_wrapper.ksh in test directory
         $ENV{REGTEST_WRFDA_DIR}="$MainDir/WRFDA_3DVAR_$par";

         $starttime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "running";
         $cmd="./gen_be_wrapper.ksh 1>gen_be.out  2>gen_be.out";
         system($cmd);
         $endtime = gettimeofday();

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if (-e "gen_be_run/SUCCESS") {
            copy("gen_be_run/be.dat","be.dat") or die "Cannot copy be.dat: $!";
            $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
            chdir "..";
            $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
            return "GENBE_FAIL";
         }
     }

     if ($types =~ /3DVAR/i) {
         if ($types =~ /VARBC/i) {
             $types =~ s/VARBC//i;

             while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
                $i ++;
             }
             $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "VARBC";

             # Submit the first job for VARBC:

             print "Starting VARBC 3DVAR $par job '$nam'\n";

             $starttime = gettimeofday();
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "running";
             if ($par=~/dm/i) {
                 $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
                 system($cmd);
             } else {
                 $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
                 system($cmd);
             }
             $endtime = gettimeofday();

             $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
             $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                           + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
             mkpath("varbc_run_1_$par") or die "mkdir failed: $!";
             unless ( -e "wrfvar_output") {
                 chdir "..";
                 $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
                 return "VARBC_FAIL";
             }
             system("mv statistics rsl* wrfvar_output varbc_run_1_$par/");
             unlink 'VARBC.in';
             move('VARBC.out','VARBC.in') or die "Move failed: $!";
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         }

         $types =~ s/3DVAR//i;

         # Submit the 3DVAR job:
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "3DVAR";

         print "Starting 3DVAR $par job '$nam'\n";

         $starttime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "running";
         if ($par=~/dm/i) { 
             $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler"; 
             system($cmd);
         }
         $endtime = gettimeofday();
    
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( -e "wrfvar_output") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
         }
    
         # Back to the upper directory:

         chdir ".." or die "Cannot chdir to .. : $!\n";
    
         return 1;

     } elsif ($types =~ /FGAT/i) {
         $types =~ s/FGAT//i;

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "FGAT";

         print "Starting FGAT $par job '$nam'\n";
         $starttime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "running";
         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
             system($cmd);
         }
         $endtime = gettimeofday();
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( -e "wrfvar_output") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
         }
         # Back to the upper directory:
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return 1;


     } elsif ($types =~ /CYCLING/i) {
         $types =~ s/CYCLING//i;

         # Cycling jobs need some extra variables. You'll see why if you read on
         my $job_feedback;

         print "Starting CYCLING $par job '$nam'\n";

         # For cycling jobs, after first 3DVAR run, we run UPDATEBC for lateral BC, then WRF,
         # then UPDATEBC for lower BC, then 3DVAR again at next time.
         # The output of the NEXT 3DVAR run is the one that will be checked against the baseline.

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_init";

         # Cycling experiments are set up so that the first two steps are run in their own directories: WRFDA_init and WRF
         # The data for each of these is contained in a tar file (cycle_data.tar) to avoid overwriting original data

         my $tarstatus = system("tar", "xf", "cycle_data.tar");
         unless ($tarstatus == 0) {
            print "Problem opening cycle_data.tar; $!\nTest probably not set up correctly\n";
            return undef;
         }

         # First: run initial 3DVAR job

         chdir "WRFDA_init" or warn "Cannot chdir to 'WRFDA_init': $!\n";

         $starttime = gettimeofday();
         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>WRFDA.out.$nam.$par 2>WRFDA.out.$nam.$par";
             system($cmd);
         }
         $endtime = gettimeofday();
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( -e "wrfvar_output") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             chdir "../.." or die "Cannot chdir to ../.. : $!\n";
             return 1;
         }
         $i++;

         # Second: run da_update_bc.exe to update lateral boundary conditions before WRF run. This is done in the WRFDA_init directory


         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "UPDATE_BC_LAT";
         $starttime = gettimeofday();
         copy( "wrfbdy_d01.orig", "wrfbdy_d01" );
         $cmd="$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe 1>update_bc.out.$nam.$par 2>update_bc.out.$nam.$par";
         system($cmd);
         copy( "wrfbdy_d01", "../WRF/wrfbdy_d01" );
         copy( "wrfvar_output", "../WRF/wrfinput_d01" );
         $endtime = gettimeofday();

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         $i++;

         # Third: Use our updated wrfinput and wrfbdy to run a forecast

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRF";
         chdir "../WRF" or warn "Cannot chdir to '../WRF': $!\n";
         $starttime = gettimeofday();
         system("ln -sf $MainDir/WRFV3_$com/run/*.TBL .");      #Linking the necessary WRF accessory files
         system("ln -sf $MainDir/WRFV3_$com/run/RRTM*DATA .");
         system("ln -sf $MainDir/WRFV3_$com/run/ozone* .");
         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun $MainDir/WRFV3_$com/main/wrf.exe 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="$MainDir/WRFV3_$com/main/wrf.exe 1>WRF.out.$nam.$par 2>WRF.out.$nam.$par";
             system($cmd);
         }
         $endtime = gettimeofday();

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         my @wrfout = glob("wrfout*");
         if ( @wrfout) {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             my $wd = `pwd`;
             chomp($wd);
             print "\nWD: $wd\n";
             chdir "../.." or die "Cannot chdir to ../.. : $!\n";
             $wd = `pwd`;
             chomp($wd);
             print "\nWD: $wd\n";
             return 1;
         }
         $i++;
         
         #Link new fg file
         symlink ($wrfout[-1],"fg");

         # Fourth: run da_update_bc.exe to update lower boundary conditions before 2nd WRFDA run

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "UPDATE_BC_LOW";
         chdir ".." or warn "Cannot chdir to '..': $!\n";

         #Link new fg file
         symlink ("WRF/".$wrfout[-1],"fg");

         $starttime = gettimeofday();
         $cmd="$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe 1>update_bc.out.$nam.$par 2>update_bc.out.$nam.$par";
         system($cmd);
         $endtime = gettimeofday();

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         $i++;


         #Fifth and lastly, run 3dvar again

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_final";

         $starttime = gettimeofday();
         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>WRFDA.out.$nam.$par 2>WRFDA.out.$nam.$par";
             system($cmd);
         }
         $endtime = gettimeofday();

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( -e "wrfvar_output") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             chdir ".." or die "Cannot chdir to .. : $!\n";
             return 1;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

         # Return 1, since we can now track sub-jobs properly (lol) and there were no job submission errors
         return 1;


     } elsif ($types =~ /HYBRID/i) {
         $types =~ s/HYBRID//i;

         print "Starting HYBRID $par job '$nam'\n";

         # Hybrid jobs need some extra variables
         my $job_feedback;
         my $wrfdate;
         my $date;
         my $ens_num;
         my $vertlevs;
         my $ens_filename;

print "1 test HYBRID\n";
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
#         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "HYBRID";

         # To make tests easier, the test directory should have a file "ens.info" that contains the wrf-formatted date
         # on the first line, the base filename should appear on the second line, and the number of vertical levels on
         # the third line. No characters should appear before this info on each line

         my $openstatus = open(INFO, "<","ens.info");
         unless ($openstatus) {
            print "Problem opening ens.info; $!\nTest probably not set up correctly\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }
print "2 test HYBRID\n";

         while (<INFO>) {
            chomp($_);
            if ($. == 4) {
               $ens_num = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
               last;
            } elsif ($. == 3) {
               $vertlevs = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
            } elsif ($. == 2) {
               $ens_filename = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
            } elsif ($. == 1) {
               #Only read the first 19 characters of the first line, since this is the length of a WRF-format date
               $wrfdate = substr($_, 0, 19) or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
            }

         }

         close INFO;
         $ens_filename =~ s/\s.*//;         # Remove trailing characters from filename
         $ens_num =~ s/\D.*//;              # Remove trailing characters from ensemble number line
         $vertlevs =~ s/\D.*//;             # Remove trailing characters from vertical level line

         $date = substr($wrfdate,0,13);     # Remove minute, second, and non-numeric characters
         $date =~ s/\D//g;                  # from $wrfdate to make $date


print "3 test HYBRID\n";
         # Step 1: Run gen_be_ensmean.exe to calculate the mean and variance fields

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "ENS_MEAN_VARI";

         $starttime = gettimeofday();
         copy("$ens_filename.e001","$ens_filename.mean");
         copy("$ens_filename.e001","$ens_filename.vari");
         system("$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_ensmean.exe >& ensmean.out");
         $endtime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         $i++;

print "4 test HYBRID\n";
         # Step 2: Calculate ensemble perturbations

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "ENS_PERT";
         mkpath('ep') or die "mkdir failed: $!";
         chdir("ep");
         $starttime = gettimeofday();
         system("$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_ep2.exe $date $ens_num . ../$ens_filename >& enspert.out");
         $endtime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( ! -e "ps.e001") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             chdir "../.." or die "Cannot chdir to .. : $!\n";
             return 1;
         }
         $i++;


print "5 test HYBRID\n";
         # Step 3: Create vertical localization file
         chdir("..");
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "VERT_LOC";
         system("$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_vertloc.exe $vertlevs >& vertlevs.out");
         $endtime = gettimeofday();
         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( ! -e "be.vertloc.dat") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             chdir ".." or die "Cannot chdir to .. : $!\n";
             return 1;
         }
         $i++;


print "6 test HYBRID\n";
         # Step 4: Finally, run WRFDA

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_HYBRID";

         my @pertfiles = glob("ep/*");
         foreach (@pertfiles){ symlink($_,basename($_))}; # link all perturbation files to base directory
         if ( ! -e "fg") {
            symlink("$ens_filename.mean",'fg');
         }
         if ($par=~/dm/i) {
            $cmd= "mpirun -np $cpun $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
            system($cmd);
         } else {
            $cmd="$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
            system($cmd);
         }

         if ( -e "wrfvar_output") {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
             $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
             chdir ".." or die "Cannot chdir to .. : $!\n";
             return 1;
         }


print "7 test HYBRID\n";
         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

         # Return 1, since we can now track sub-jobs properly (lol) and there were no job submission errors
         return 1;

     } elsif ($types =~ /4DVAR/i) {
         $types =~ s/4DVAR//i;

         print "Starting 4DVAR $par job '$nam'\n";

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "4DVAR";

         $starttime = gettimeofday();
         if ($par=~/dm/i) {
            $cmd= "mpirun -np $cpun ../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
            system($cmd);
         } else {
            $cmd="../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
            system($cmd);
         }
         $endtime = gettimeofday();
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = $endtime - $starttime;
         $Experiments{$nam}{paropt}{$par}{walltime} = $Experiments{$nam}{paropt}{$par}{walltime}
                                                       + $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime};
         if ( -e "wrfvar_output") {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "done";
         } else {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "error";
         }

         # Back to the upper directory:
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return 1;

     } else {
         print "\nERROR:\nINVALID JOB TYPE $types FOR JOB '$nam'\n";
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return undef;
     }
}

sub create_ys_job_script {

    my ($jobname, $jobtype, $jobpar, $jobcompiler, $jobcores, $jobcpus, $jobqueue, $jobproj, @stufftodo) = @_;
    # jobname:     name of the test (e.g. ASR_AIRS, realtime_hybrid, etc.)
    # jobtype:     brief descriptive type of submitted job (e.g. 3DVAR, UPDATE_LOW_BC, GENBE, FGAT, OBSPROC, etc.)
    # jobpar:      parallelization; one of serial, smpar, dmpar, or dm+sm
    # jobcompiler: name of compiler (not currently used, but might be useful in the future)
    # jobcores:    number of MPI tasks to run with
    # jobcpus:     number of OPENMP threads to run with
    # jobqueue


    printf "Creating $jobtype job: $jobname, $jobpar\n";

    # Generate the LSF job script
    unlink "job_${jobname}_${jobtype}_${jobpar}.pl" if -e "job_${jobname}_${jobtype}_${jobpar}.pl";
    open FH, ">job_${jobname}_${jobtype}_${jobpar}.pl" or die "Can not open job_${jobname}_${jobtype}_${jobpar}.pl to write. $! \n";

    print FH '#!/usr/bin/perl -w'."\n";
    print FH "use strict;\n"; #Always use "use strict"!
    print FH "use File::Copy;\n"; #This module is usually needed
    print FH '#',"\n";
    print FH '# LSF batch script'."\n";
    print FH "# Automatically generated by $0\n";
    print FH "#BSUB -J $jobname"."\n";
    # If more than 16 cores, can't use caldera
    print FH "#BSUB -q ".(($jobqueue eq 'caldera' && $jobcores > 16) ? "regular" : $jobqueue)."\n";
    printf FH "#BSUB -n %-3d"."\n",($jobpar eq 'dmpar' || $jobpar eq 'dm+sm') ? $jobcores: 1;
    print FH "#BSUB -o job_${jobname}_${jobtype}_${jobpar}.output"."\n";
    print FH "#BSUB -e job_${jobname}_${jobtype}_${jobpar}.error"."\n";
    printf FH "#BSUB -W %d"."\n", ($Debug > 0) ? (($jobpar eq 'dmpar' || $jobpar eq 'dm+sm') ? 30: 60) : 15;
    print FH "#BSUB -P $jobproj"."\n";
    # If job serial or smpar, span[ptile=1]; if job dmpar, span[ptile=16] or span[ptile=$cpun], whichever is less
    printf FH "#BSUB -R span[ptile=%d]"."\n", ($jobpar eq 'serial' || $jobpar eq 'smpar') ? 1 : (($jobcores < 16 ) ? $jobcores : 16);
    print FH "\n"; #End of BSUB commands; add newline for readability

    # Comment this out for now; this line will be needed if smpar functionality is ever added (also will need new variable passed, cpum)
    #print FH ( $par eq 'smpar' || $par eq 'dm+sm') ? "setenv OMP_NUM_THREADS $cpum\n" :"\n";

    # OpenMP stuff
    print FH 'delete $ENV{MP_PE_AFFINITY};'."\n";
    if ( ($jobpar eq 'smpar' || $jobpar eq 'dm+sm') && ( $jobcpus > 1 ) ) {
       print FH '$ENV{OMP_NUM_THREADS} = '."$jobcpus;\n";
       print FH '$ENV{MP_TASK_AFFINITY} = "core:$ENV{OMP_NUM_THREADS}";'."\n";
    }

    # Finally, let's print all the commands that will be needed for this job. 
    # Array @stufftodo should be provided as strings WITH ANY NEEDED NEWLINES
    foreach my $command (@stufftodo) {
       print FH $command;
    }
    print FH "\n"; #End of script; add newline for readability

    # ALL DONE! Close the file and call it a day
    close (FH);

}


sub new_job_ys {

     my ($nam, $com, $par, $cpun, $cpum, $types) = @_;

     my $feedback;
     my $h;
     my $i = 1; #jobnum loop counter
     # Enter into the experiment working directory:
     

     if ($types =~ /GENBE/i) {
         $types =~ s/GENBE//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "GENBE";
#         $Experiments{$nam}{paropt}{$par}{currjobname} = "GENBE";
         chdir "$nam" or die "Cannot chdir to $nam : $!\n";


         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @genbe_commands;
         $genbe_commands[0] = "if( -e 'be.dat' ) {unlink 'be.dat'};\n";
         $genbe_commands[1] = 'my $tarstatus = system("tar", "xf", "forecasts.tar");'."\n";
         # We need the script to see where the WRFDA directory is. See 'gen_be_wrapper.ksh' in test directory
         if ($types =~ /4DVAR/i) {
            $genbe_commands[2] = '$ENV{REGTEST_WRFDA_DIR}='."'$MainDir/WRFDA_4DVAR_$par';\n";
         } else {
            $genbe_commands[2] = '$ENV{REGTEST_WRFDA_DIR}='."'$MainDir/WRFDA_3DVAR_$par';\n";
         }
         $genbe_commands[3] = "`./gen_be_wrapper.ksh > gen_be.out`;\n";
         $genbe_commands[4] = "if( -e 'gen_be_run/SUCCESS' ) {\n";
         $genbe_commands[5] = "   copy('gen_be_run/be.dat','./be.dat');\n";
         $genbe_commands[6] = "} else {\n";
         $genbe_commands[7] = '   open FH,">FAIL_'."$par\";"."\n";
         $genbe_commands[8] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
         $genbe_commands[9] = "   close FH;\n";
         $genbe_commands[10] = "}\n";
         $genbe_commands[11] = "move('gen_be_run','gen_be_run_$par');\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, $cpum,
                                 $Queue, $Project, @genbe_commands );

         # Submit the job

         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{1}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})"  < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{1}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit GENBE job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

     }

     if ($types =~ /OBSPROC/i) {
         $types =~ s/OBSPROC//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "OBSPROC";
#         $Experiments{$nam}{paropt}{$par}{currjobname} = "OBSPROC";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @obsproc_commands;
         $obsproc_commands[0] = "system('$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe');\n";
         if ($types =~ /3DVAR/i) {
            $obsproc_commands[1] = "system('cp -f obs_gts_*.3DVAR ob.ascii');\n";
            $obsproc_commands[2] = 'if ( ! -e "ob.ascii") {'."\n";
            $obsproc_commands[3] = '   open FH,">FAIL";'."\n";
            $obsproc_commands[4] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
            $obsproc_commands[5] = "   close FH;\n";
            $obsproc_commands[6] = "}\n";
         } else {
            if ($types =~ /FGAT/i) {
               $obsproc_commands[1] = 'my @obsfiles = glob("obs_gts*.FGAT");'."\n"; 
            } elsif ($types =~ /4DVAR/i) {
               $obsproc_commands[1] = 'my @obsfiles = glob("obs_gts*.4DVAR");'."\n";
            }
            $obsproc_commands[2] = 'my $index = 1;'."\n";
            $obsproc_commands[3] = 'foreach my $obfile (@obsfiles){'."\n";
            $obsproc_commands[4] = '   ($index < 10) ? symlink($obfile,"ob0$index.ascii") : symlink($obfile,"ob$index.ascii");'."\n";
            $obsproc_commands[5] = '   $index ++;'."\n";
            $obsproc_commands[6] = '}'."\n";
            $obsproc_commands[7] = 'if ( ! -e "ob01.ascii") {'."\n";
            $obsproc_commands[8] = '   open FH,">FAIL";'."\n";
            $obsproc_commands[9] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
            $obsproc_commands[10] = "   close FH;\n";
            $obsproc_commands[11] = "}\n";
         }

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 $Queue, $Project, @obsproc_commands );

         # Submit the job

         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit OBSPROC job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";
     }

     if ($types =~ /VARBC/i) {
         $types =~ s/VARBC//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "VARBC";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @varbc_commands;
         $varbc_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";
         $varbc_commands[1] = "mkdir(\"varbc_run_1_$par\");\n";
         $varbc_commands[2] = "system(\"mv rsl* varbc_run_1_$par/\");\n";
         $varbc_commands[3] = "unlink('VARBC.in');\n";
         $varbc_commands[4] = "rename('VARBC.out','VARBC.in');\n";
         $varbc_commands[5] = 'if ( ! -e "wrfvar_output") {'."\n";
         $varbc_commands[6] = '   open FH,">FAIL";'."\n";
         $varbc_commands[7] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
         $varbc_commands[8] = "   close FH;\n";
         $varbc_commands[9] = "}\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @varbc_commands );

         # Submit the job

         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit VARBC job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Return to the upper directory

         chdir ".." or die "Cannot chdir to .. : $!\n";
     }

     if ($types =~ /FGAT/i) {
         $types =~ s/FGAT//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "FGAT";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";


         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @fgat_commands;
         $fgat_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @fgat_commands );

         # Submit the job
         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit FGAT job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";
     }


     if ($types =~ /3DVAR/i) {
         $types =~ s/3DVAR//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "3DVAR";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @_3dvar_commands;
         $_3dvar_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @_3dvar_commands );

         # Submit the job

         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit 3DVAR job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         chdir ".." or die "Cannot chdir to .. : $!\n";
     }

     if ($types =~ /CYCLING/i) {
         $types =~ s/CYCLING//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         # Cycling jobs need some extra variables. You'll see why if you read on
         my $job_feedback;

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         # For cycling jobs, after first 3DVAR run, we run UPDATEBC for lateral BC, then WRF,
         # then UPDATEBC for lower BC, then 3DVAR again at next time.
         # The output of the NEXT 3DVAR run is the one that will be checked against the baseline.

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_init";

         # Cycling experiments are set up so that the first two steps are run in their own directories: WRFDA_init and WRF
         # The data for each of these is contained in a tar file (cycle_data.tar) to avoid overwriting original data

         my $tarstatus = system("tar", "xf", "cycle_data.tar");
         unless ($tarstatus == 0) {
            print "Problem opening cycle_data.tar; $!\nTest probably not set up correctly\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # First: run initial 3DVAR job

         chdir "WRFDA_init" or warn "Cannot chdir to 'WRFDA_init': $!\n";

         my @_3dvar_init_commands;
         $_3dvar_init_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";
         $_3dvar_init_commands[1] = 'if ( ! -e "wrfvar_output") {'."\n";
         $_3dvar_init_commands[2] = '   open FH,">FAIL";'."\n";
         $_3dvar_init_commands[3] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
         $_3dvar_init_commands[4] = "   close FH;\n";
         $_3dvar_init_commands[5] = "}\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{1}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @_3dvar_init_commands );

         # Submit initial 3DVAR job
         $job_feedback = ` bsub < job_${nam}_WRFDA_init_${par}.pl 2>/dev/null `;


         # We're gonna use some fancy Yellowstone finagling to submit all our jobs in sequence without the parent script 
         # having to wait. To do this, we need to keep track of job numbers (hashes are unordered so we can't rely on %Experiments)
         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $h = $i;
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRFDA_init job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir "../.." or die "Cannot chdir to '../..' : $!\n";
            return undef;
         }

         # Second: run da_update_bc.exe to update lateral boundary conditions before WRF run. This is done in the WRFDA_init directory

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "UPDATE_BC_LAT";
         my @lat_bc_commands;
         $lat_bc_commands[0] = "copy('wrfbdy_d01.orig','wrfbdy_d01');\n";
         $lat_bc_commands[1] = "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe');\n";
         $lat_bc_commands[2] = "copy('wrfbdy_d01','../WRF/wrfbdy_d01');\n";
         $lat_bc_commands[3] = "copy('wrfvar_output','../WRF/wrfinput_d01');\n";

         &create_ys_job_script ( $nam,$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 'caldera', $Project, @lat_bc_commands );
         
         # Here's the finagling I was talking about. Since these jobs all require input from the previous job,
         # We can use -w "ended($jobid)" to wait for job $jobid to finish
         $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i++;$h++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit UPDATE_BC_LAT job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir "../.." or die "Cannot chdir to '../..' : $!\n";
            return undef;
         }
         # Third: Use our updated wrfinput and wrfbdy to run a forecast
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRF";
         chdir "../WRF" or warn "Cannot chdir to '../WRF': $!\n";

         my @wrf_commands;
         $wrf_commands[0] = "use File::Basename;\n";
         $wrf_commands[1] = 'my @wrffiles = glob("'."$MainDir/WRFV3_$com/run/*.TBL\");\n";
         $wrf_commands[2] = 'foreach (@wrffiles){ symlink($_,basename($_))};'."\n";
         $wrf_commands[3] = '@wrffiles = glob("'."$MainDir/WRFV3_$com/run/RRTM*DATA\");\n";
         $wrf_commands[4] = 'foreach (@wrffiles){ symlink($_,basename($_))};'."\n";
         $wrf_commands[5] = '@wrffiles = glob("'."$MainDir/WRFV3_$com/run/ozone*\");\n";
         $wrf_commands[6] = 'foreach (@wrffiles){ symlink($_,basename($_))};'."\n";
         $wrf_commands[7] = ($par eq 'serial' || $par eq 'smpar') ? "system('$MainDir/WRFV3_$com/main/wrf.exe');\n" : "system('mpirun.lsf $MainDir/WRFV3_$com/main/wrf.exe');\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @wrf_commands );

         $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i++;$h++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRF job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir "../.." or die "Cannot chdir to '../..' : $!\n";
            return undef;
         }

         # Fourth: run da_update_bc.exe to update lower boundary conditions before 2nd WRFDA run
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "UPDATE_BC_LOW";
         chdir ".." or warn "Cannot chdir to '..': $!\n";

#         # Because of limitations in how csh can link files, we need to create a perl script to be called to link the wrfout as fg
#         open FH, ">link_new_fg.pl" or die "Can not open link_new_fg.pl to write. $! \n";
#         print FH '#!/usr/bin/perl -w'."\n";
#         print FH "use strict;";
#         print FH 'my @wrfout = glob("wrfout*");'."\n";
#         print FH 'symlink ($wrfout[-1],"fg");'."\n";
#         close FH;
#
#         chmod(0755,"link_new_fg.pl");

         my @low_bc_commands;
         $low_bc_commands[0] = 'my @wrfout = glob("WRF/wrfout*");'."\n";
         $low_bc_commands[1] = 'symlink ($wrfout[-1],"fg");'."\n";
         $low_bc_commands[2] = "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe');\n";
         $low_bc_commands[3] = 'if ( ! -e "fg") {'."\n";
         $low_bc_commands[4] = '   open FH,">FAIL";'."\n";
         $low_bc_commands[5] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$h}{jobname}."';\n"; #Remember that "h" is the previous job
         $low_bc_commands[6] = "   close FH;\n";
         $low_bc_commands[7] = "}\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 'caldera', $Project, @low_bc_commands );

         $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i++;$h++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit UPDATE_BC_LOW job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         #Fifth and lastly, run 3dvar again
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_final";
         my @_3dvar_final_commands;
         $_3dvar_final_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par')\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";
         $_3dvar_final_commands[1] = 'if ( ! -e "wrfvar_output") {'."\n";
         $_3dvar_final_commands[2] = '   open FH,">FAIL";'."\n";
         $_3dvar_final_commands[3] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
         $_3dvar_final_commands[4] = "   close FH;\n";
         $_3dvar_final_commands[5] = "}\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @_3dvar_final_commands );

         $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRFDA_final job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Now we're done creating and submitting jobs; let's go back to the main test

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

         # Return 1, since we can now track sub-jobs properly (lol) and there were no job submission errors
         return 1;

     }

     if ($types =~ /HYBRID/i) {
         $types =~ s/HYBRID//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         # Hybrid jobs also need some extra variables
         my $job_feedback;
         my $wrfdate;
         my $date;
         my $ens_num;
         my $vertlevs;
         my $ens_filename;

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }

         # For Hybrid jobs, we can either run the whole process, or start with pre-calculated perturbations
         if (-e "ep.tar") {

            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "UNTAR_ENS_DATA";

            my @untar_commands;
            $untar_commands[0] = "system('tar -xf ep.tar');\n";
            $untar_commands[1] = 'if ( ! -d "ep") {'."\n";
            $untar_commands[2] = '   open FH,">../FAIL";'."\n";
            $untar_commands[3] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
            $untar_commands[4] = "   close FH;\n";
            $untar_commands[5] = "}\n";

            $job_feedback = ` bsub < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

            if ($job_feedback =~ m/.*<(\d+)>/) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
               $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
               if ($i == 1) {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
               } else {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
               }
               $h = $i;
               $i ++;
            } else {
               print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit UNTAR_ENS_DATA job for HYBRID task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
               chdir ".." or die "Cannot chdir to '..' : $!\n";
               return undef;
            }

         } else {
            # To make tests easier, the test directory should have a file "ens.info" that contains the wrf-formatted date
            # on the first line, the base filename should appear on the second line, and the number of vertical levels on 
            # the third line. No characters should appear before this info on each line

            my $openstatus = open(INFO, "<","ens.info");
            unless ($openstatus) {
               print "Problem opening ens.info; $!\nTest probably not set up correctly\n";
               chdir ".." or die "Cannot chdir to '..' : $!\n";
               return undef;
            }

            while (<INFO>) {
               chomp($_);
               if ($. == 4) {
                  $ens_num = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
                  last;
               } elsif ($. == 3) {
                  $vertlevs = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
               } elsif ($. == 2) {
                  $ens_filename = $_ or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
               } elsif ($. == 1) {
                  #Only read the first 19 characters of the first line, since this is the length of a WRF-format date
                  $wrfdate = substr($_, 0, 19) or die "\n\nERROR: YOUR ens.info FILE IS MALFORMATTED\n\n";
               }

            }

            close INFO;
            $ens_filename =~ s/\s.*//;         # Remove trailing characters from filename
            $ens_num =~ s/\D.*//;              # Remove trailing characters from ensemble number line
            $vertlevs =~ s/\D.*//;             # Remove trailing characters from vertical level line

            $date = substr($wrfdate,0,13);     # Remove minute, second, and non-numeric characters
            $date =~ s/\D//g;                  # from $wrfdate to make $date

            # Step 1: Run gen_be_ensmean.exe to calculate the mean and variance fields

            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "ENS_MEAN_VARI";
            my @ensmean_commands;
            $ensmean_commands[0] = "copy('$ens_filename.e001','$ens_filename.mean');\n";
            $ensmean_commands[1] = "copy('$ens_filename.e001','$ens_filename.vari');\n";
            $ensmean_commands[2] = "system('$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_ensmean.exe >& ensmean.out');\n";

            &create_ys_job_script ( $nam,$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 'caldera', $Project, @ensmean_commands );

            $job_feedback = ` bsub < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

            if ($job_feedback =~ m/.*<(\d+)>/) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
               $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
               if ($i == 1) {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
               } else {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
               }
               $h = $i;
               $i ++;
            } else {
               print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit ENS_MEAN_VARI job for HYBRID task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
               chdir ".." or die "Cannot chdir to '..' : $!\n";
               return undef;
            }

            # Step 2: Calculate ensemble perturbations

            mkpath("ep") or die "mkdir failed: $!";
            chdir("ep");

            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "ENS_PERT";
            my @enspert_commands;
            $enspert_commands[0] = "system('$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_ep2.exe $date $ens_num . ../$ens_filename >& enspert.out');\n";
            $enspert_commands[1] = 'if ( ! -e "ps.e001") {'."\n";
            $enspert_commands[2] = '   open FH,">../FAIL";'."\n";
            $enspert_commands[3] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
            $enspert_commands[4] = "   close FH;\n";
            $enspert_commands[5] = "}\n";

            &create_ys_job_script ( $nam,$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 'caldera', $Project, @enspert_commands );

            $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

            if ($job_feedback =~ m/.*<(\d+)>/) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
               $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
               if ($i == 1) {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
               } else {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
               }
               $h ++;$i ++;
            } else {
               print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit ENS_PERT job for HYBRID task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
               chdir "../.." or die "Cannot chdir to '../..' : $!\n";
               return undef;
            }

            # Step 3: Create vertical localization file
            chdir("..");
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "VERT_LOC";
            my @vertloc_commands;
            $vertloc_commands[0] = "system('$MainDir/WRFDA_3DVAR_$par/var/build/gen_be_vertloc.exe $vertlevs >& vertlevs.out');\n";
            $vertloc_commands[1] = 'if ( ! -e "be.vertloc.dat") {'."\n";
            $vertloc_commands[2] = '   open FH,">FAIL";'."\n";
            $vertloc_commands[3] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
            $vertloc_commands[4] = "   close FH;\n";
            $vertloc_commands[5] = "}\n";

            &create_ys_job_script ( $nam,$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, 1, 1,
                                 'caldera', $Project, @vertloc_commands );

            $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

            if ($job_feedback =~ m/.*<(\d+)>/) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
               $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
               if ($i == 1) {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
               } else {
                  $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
               }
               $h ++;$i ++;
            } else {
               print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit VERT_LOC job for HYBRID task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
               chdir ".." or die "Cannot chdir to '..' : $!\n";
               return undef;
            }

         }

         # Finally, run WRFDA

         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "WRFDA_HYBRID";
         my @hybrid_commands;
         $hybrid_commands[0] = "use File::Basename;\n";
         $hybrid_commands[1] = 'my @pertfiles = glob("'."ep/*\");\n";
         $hybrid_commands[2] = 'foreach (@pertfiles){ symlink($_,basename($_))};'."\n";
         $hybrid_commands[3] = 'if ( ! -e "fg") {'."\n";
         $hybrid_commands[4] = "   symlink('$ens_filename.mean','fg');\n";
         $hybrid_commands[5] = '}'."\n";
         $hybrid_commands[6] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par')\n" :
             "system('mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";
         $hybrid_commands[7] = "rename(\"ep/\",\"ep_$par/\");\n";
         $hybrid_commands[8] = 'if ( ! -e "wrfvar_output") {'."\n";
         $hybrid_commands[9] = '   open FH,">FAIL";'."\n";
         $hybrid_commands[10] = "   print FH '".$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}."';\n";
         $hybrid_commands[11] = "   close FH;\n";
         $hybrid_commands[12] = "}\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @hybrid_commands );

         $job_feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_$Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}_${par}.pl 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRFDA_HYBRID job for HYBRID task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            chdir ".." or die "Cannot chdir to '..' : $!\n";
            return undef;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

         # Return 1, since we can now track sub-jobs properly (lol) and there were no job submission errors
         return 1;
     }

     if ($types =~ /4DVAR/i) {
         $types =~ s/4DVAR//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         while (exists $Experiments{$nam}{paropt}{$par}{job}{$i}) { #Increment jobnum if a job already exists
            $i ++;
         }
         $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname} = "4DVAR";
         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         my @_4dvar_commands;
         $_4dvar_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "system('$MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n" :
             "system('mpirun.lsf $MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par');\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}, $par, $com, $Experiments{$nam}{cpu_mpi}, 1,
                                 $Queue, $Project, @_4dvar_commands );

         # Submit the job
         if ($i == 1) {
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         } else {
            $h = $i - 1;
            $feedback = ` bsub -w "ended($Experiments{$nam}{paropt}{$par}{job}{$h}{jobid})" < job_${nam}_${Experiments{$nam}{paropt}{$par}{job}{$i}{jobname}}_${par}.pl 2>/dev/null `;
         }
         if ($feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{$i}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{$i}{walltime} = 0;
            if ($i == 1) {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "pending";
            } else {
               $Experiments{$nam}{paropt}{$par}{job}{$i}{status} = "waiting";
            }
            $i ++;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit 4DVAR job for task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
           return undef;
         }

         # Return to the upper directory

         chdir ".." or die "Cannot chdir to .. : $!\n";
     }


     # Update the job list
     $types =~ s/^\|//;
     $types =~ s/\|$//;
     $Experiments{$nam}{paropt}{$par}{todo} = $types;

     # Pick the job id

     if ($feedback =~ m/.*<(\d+)>/) {;
#         $Experiments{$nam}{paropt}{$par}{job}{$Experiments{$nam}{paropt}{$par}{currjob}}{jobid} = $1;
         return 1;
     } else {
         print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit task for $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
         return undef;
     };


}


sub compare_output {
   
     my ($name, $par) = @_;

     my $diffwrfpath = $diffwrfdir . "diffwrf";

     return -3 unless ( -e "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version");
     return -4 unless ( -e "$Baseline/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version");

     my @output = `$diffwrfpath $name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version $Baseline/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version`;
 
     return -2 if (!@output);
     
     my $found = 0;
     my $sumfound = 0;
     $missvars = 0 ;

     my $diff_file = "$name.diff";

     #If we've gotten this far, print the output of diffwrf to a file
     
     open (FILE, ">> $diff_file") || die "problem opening $diff_file: $!\n";
     print FILE @output;
     close(FILE);

     foreach (@output) {
         
         return -5 if ( $_=~/could not open/i);

         if (/pntwise max/) {
             $found = 1 ;
             $sumfound = $sumfound + 1 ;
             next;
         }
         if ( $_=~/Variable not found/i) {
         $missvars ++ ;
         }

         next unless $found;

         my @values = split /\s+/, $_;

         if ($values[4]) {
             if ($values[4] =~ /^\d\.\d{10}E[+-]\d{2}$/) {# look for RMS format
                 #compare RMS(1) and RMS(2) , return 1 if diff found.
                 return 1 unless ($values[4] == $values[5]) ;
             }
         }

         if ($values[5] =~ /NaN/) {
             return -6;
         }
         
     
     }

     return -1 if ($sumfound == 0); # Return error if diffwrf output does not make sense

     print "\nTotal missing variables: $missvars\n";

     return 0;        # All the same.

}


sub flush_status {

    @Message = &refresh_status ();   # Update the Message
    
    print $Clear; 
    print join('', @Message);

}

sub submit_job {

    foreach my $name (keys %Experiments) {

        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            #Set the start time for this job
            $Experiments{$name}{paropt}{$par}{starttime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{status} = "running";
            &flush_status (); # refresh the status


#print "\nDumper check 1\n";
#print Dumper($Experiments{$name});
            #Submit job
            my $rc = &new_job ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                $Experiments{$name}{cpu_openmp},$Experiments{$name}{test_type} );

print "2 submit job test, rc = $rc\n";
            #Set the end time for this job
            $Experiments{$name}{paropt}{$par}{endtime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{walltime} =
                $Experiments{$name}{paropt}{$par}{endtime} - $Experiments{$name}{paropt}{$par}{starttime};
            if (defined $rc) { 
                if ($rc =~ /OBSPROC_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{result} = "OBSPROC error";
                    &flush_status ();
                    next;
                } elsif ($rc =~ /VARBC_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{result} = "VARBC error";
                    &flush_status ();
                    next;
                } elsif ($rc =~ /GENBE_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{result} = "GENBE error";
                    &flush_status ();
                    next;
                } else {
                    printf "%-10s job for %-30s was finished in %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};
                }
            } else {
                $Experiments{$name}{paropt}{$par}{status} = "error";
                $Experiments{$name}{paropt}{$par}{result} = "Mysterious error!";
                &flush_status ();
                next;   # Can not submit this job.
            }

#print "\nDumper check 2\n";
#print Dumper($Experiments{$name});
            $Experiments{$name}{paropt}{$par}{status} = "done";

            # Wrap-up this job:

            rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version";

            # Compare the wrfvar_output with the BASELINE:

            unless ($Baseline =~ /none/i) {
                         &check_baseline ($name, $Arch, $Machine_name, $par, $Compiler, $Baseline, $Compiler_version);
            }
        }

#print "\nDumper check 3\n";
#print Dumper($Experiments{$name});
    }

    &flush_status (); # refresh the status
    sleep 1;
}

sub submit_job_ys {

$count = 0;
    while ($remain_exps > 0) {    # cycling until no more experiments remain

         #This first loop submits all parallel jobs

         foreach my $name (keys %Experiments) {

             next if ($Experiments{$name}{status} eq "done") ;  # skip this experiment if it is done.

             foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {

                 next if ( $Experiments{$name}{paropt}{$par}{status} eq "done"  ||      # go to next job if it is done already..
                           $Experiments{$name}{paropt}{$par}{status} =~ m/error/i );

                 unless ( defined $Experiments{$name}{paropt}{$par}{currjob} ) {      # No current job and not done; ready for submission

                     next if $Experiments{$name}{status} eq "close";      #  skip if this experiment already has a job running.
                     my $rc = &new_job_ys ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                   $Experiments{$name}{cpu_openmp},$Experiments{$name}{test_type} );

                     if (defined $rc) {
                         $Experiments{$name}{paropt}{$par}{currjob} = $rc ;    # keep track of current job number; this should be 1 at this point
                         $Experiments{$name}{paropt}{$par}{currjobid} = $Experiments{$name}{paropt}{$par}{job}{$rc}{jobid} ;    # assign the current jobid.
                         $Experiments{$name}{paropt}{$par}{currjobname} = $Experiments{$name}{paropt}{$par}{job}{$rc}{jobname} ;    # assign the current job name
                         $Experiments{$name}{status} = "close";
                         my $checkQ = `bjobs $Experiments{$name}{paropt}{$par}{currjobid}`;
                         if ($checkQ =~ /\sregular\s/) {
                             printf "%-10s job for %-30s,%8s was submitted to queue 'regular' with jobid: %10d \n",
                                  $Experiments{$name}{paropt}{$par}{currjobname}, $name, $par,$Experiments{$name}{paropt}{$par}{currjobid};
                         } else {
                             printf "%-10s job for %-30s,%8s was submitted to queue '$Queue' with jobid: %10d \n",
                                  $Experiments{$name}{paropt}{$par}{currjobname}, $name, $par,$Experiments{$name}{paropt}{$par}{currjobid};
                         }
                     } else {
                         $Experiments{$name}{paropt}{$par}{status} = "error";
                         $Experiments{$name}{paropt}{$par}{result} = "Job submit failed";
                         $remain_par{$name} -- ;
                         if ($remain_par{$name} == 0) {
                             $Experiments{$name}{status} = "done";
                             $remain_exps -- ;
                         }
                         &flush_status ();
                         next;
                     }
                 }

                 # If we got to this point, job is still in queue.
                 my $checkjob = `bjobs $Experiments{$name}{paropt}{$par}{currjobid}`;
                 if ( $checkjob =~ m/RUN/ ) {; # Still running
                     unless ($Experiments{$name}{paropt}{$par}{started} == 1) { #Set job status to running if this is the first time we've found it running
                         $Experiments{$name}{paropt}{$par}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{started} = 1;
                         &flush_status (); # refresh the status
                     }
                     next;
                 } elsif ( $checkjob =~ m/PEND/ ) { # Still Pending
                     next;
                 }

                 # If we got to this point, job is finished. Finalize the test or prepare for next job
                 my $bhist = `bhist $Experiments{$name}{paropt}{$par}{currjobid}`;
                 my @jobhist = split('\s+',$bhist);  # Get runtime using bhist command, then store this job's runtime and add it to total runtime
                 $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{walltime} = $jobhist[24];
                 $Experiments{$name}{paropt}{$par}{walltime} = $Experiments{$name}{paropt}{$par}{walltime} + $jobhist[24];

                 my $i = 1;
                 while ( exists $Experiments{$name}{paropt}{$par}{job}{$i} ) { # Loop through each job to determine if there are any left to run
                    if ($Experiments{$name}{paropt}{$par}{job}{$i}{status} eq "done") {
                       $i ++; #This job has already been completed and checked, go to next
                       next;
                    } elsif ($Experiments{$name}{paropt}{$par}{job}{$i}{status} eq "running" || $Experiments{$name}{paropt}{$par}{job}{$i}{status} eq "pending") {
                       #Note about above if statement: it's possible that a fast job could be completed before we even see it in the "running" state, 
                       # which is why "pending" is included in the above elsif statement
                       $Experiments{$name}{paropt}{$par}{started} = 0;
                       printf "%-10s job for %-30s,%8s was completed in %5d seconds. \n", 
                            $Experiments{$name}{paropt}{$par}{currjobname}, $name, $par, 
                            $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{walltime};
                       if ( -e "$name/FAIL" ) {
                          $Experiments{$name}{paropt}{$par}{status} = "error";
                          my $readFAIL;
                          if (open(my $FAILfile, '<:encoding(UTF-8)', "$name/FAIL")) {
                             $readFAIL = <$FAILfile>;
                             chomp $readFAIL;
                             print "READING:$readFAIL\n";
                             close $FAILfile;
                             $Experiments{$name}{paropt}{$par}{result} = "$readFAIL error";
                          } else {
                             warn "Could not open file '$name/FAIL' $!";
                             $Experiments{$name}{paropt}{$par}{result} = "Mysterious error";
                          }
                          $Experiments{$name}{paropt}{$par}{job}{$i}{status} = "error";
                          $remain_par{$name} -- ;                   # We got an error, so this parallelism for this test is done
                          my $j = $i + 1;
                          while ( exists $Experiments{$name}{paropt}{$par}{job}{$j}) { # Kill the rest of the jobs
                             $Experiments{$name}{paropt}{$par}{job}{$j}{status} = "--";
                             system("bkill $Experiments{$name}{paropt}{$par}{job}{$j}{jobid}");
                             print "bkill $Experiments{$name}{paropt}{$par}{job}{$j}{jobid}\n";
                             $j ++;
                          }
                       } else {
                          $Experiments{$name}{paropt}{$par}{job}{$i}{status} = "done";
                       }
                       delete $Experiments{$name}{paropt}{$par}{currjob};       # Delete the current job.
                       delete $Experiments{$name}{paropt}{$par}{currjobid};       # Delete the current job.
                       delete $Experiments{$name}{paropt}{$par}{currjobname};       # Delete the current job.

                       last if ( $Experiments{$name}{paropt}{$par}{status} eq "error"); #Exit while loop if there's an error

                       my $j = $i + 1;
                       if ( exists $Experiments{$name}{paropt}{$par}{job}{$j} ) { #Before moving on, be sure the next job isn't already in the queue
                          if ( $Experiments{$name}{paropt}{$par}{job}{$j}{status} eq "waiting") {
                             $Experiments{$name}{paropt}{$par}{job}{$j}{status} = "pending";
                             $Experiments{$name}{paropt}{$par}{status} = "pending";
                             $Experiments{$name}{paropt}{$par}{currjob} = $j;
                             $Experiments{$name}{paropt}{$par}{currjobid} = $Experiments{$name}{paropt}{$par}{job}{$j}{jobid};
                             $Experiments{$name}{paropt}{$par}{currjobname} = $Experiments{$name}{paropt}{$par}{job}{$j}{jobname};
                             my $checkQ = `bjobs $Experiments{$name}{paropt}{$par}{currjobid}`;
                             if ($checkQ =~ /\sregular\s/) {
                                printf "%-10s job for %-30s,%8s was submitted to queue 'regular' with jobid: %10d \n",
                                     $Experiments{$name}{paropt}{$par}{currjobname}, $name, $par,$Experiments{$name}{paropt}{$par}{currjobid};
                             } else {
                                printf "%-10s job for %-30s,%8s was submitted to queue '$Queue' with jobid: %10d \n",
                                     $Experiments{$name}{paropt}{$par}{currjobname}, $name, $par,$Experiments{$name}{paropt}{$par}{currjobid};
                             }

                          }
                       } else {
                          $Experiments{$name}{paropt}{$par}{status} = "done"; # If the job finished too quickly, it might still be "pending"; don't want that!
                       }
                    last;
                    } else {
                       print Dumper($Experiments{$name});
                       print "Name = $name\n";
                       print "Par  = $par\n";
                       die "\nSerious error...WE SHOULD NEVER BE HERE!!\n";
                    }
                 }

                 if ($Experiments{$name}{paropt}{$par}{status} eq "pending") { #If we set this to pending, it's because there are more jobs in the queue
                    next;
                 } else {
                    unless ($Experiments{$name}{paropt}{$par}{status} eq "error") { #These steps are unnecessary if we've already determined there's an error
#                       next if ($Experiments{$name}{paropt}{$par}{todo}); #If there is more to do, need to call &new_job_ys again
                                                                          # THIS SHOULD BE DEPRECIATED, the current system should not need "todo"
                       $remain_par{$name} -- ;                            # If we got to this point, this parallelism for this test is done
                       $Experiments{$name}{paropt}{$par}{status} = "done";

                       printf "%-30s test,%8s was completed in %5d seconds. \n", $name, $par, $Experiments{$name}{paropt}{$par}{walltime};

                       # Wrap-up this job:
                       rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version";

                       # Compare against the baseline
                       unless ($Baseline =~ /none/i) {
                            &check_baseline ($name, $Arch, $Machine_name, $par, $Compiler, $Baseline, $Compiler_version);
                       }
                    }
                 }

                 if ($remain_par{$name} == 0) {                        # if all par options are done, this experiment is finished.
                     $Experiments{$name}{status} = "done";
                     $remain_exps -- ;
                 } else {
                     $Experiments{$name}{status} = "open";              # If there are still parallelism options remaining, open to submit new parallelization option.
                 }

                 &flush_status ();
             }

         }
         sleep (2.);
         $count ++;

         if ($count > (300*($Debug + 1))) { #The "$Debug" logic is because a higher debug level will cause longer test run times
            print "\nOne or more tests are taking longer than expected, do you want to keep waiting?\a\n";
            my $go = ''; 
            while ($go eq "") {
               $go = <STDIN>;
               chop($go);
               if ($go =~ /N/i) {
                  print "Exiting test\n";
                  print Dumper(%Experiments);
                  return;
               } elsif ($go =~ /Y/i) {
                  $count = $count - 60*($Debug + 1);
                  &flush_status ();
               } else {
                  print "Invalid input: ".$go;
                  $go='';
               }
            }
            
         }
    }

}


sub check_executables {
    my ($dirname) = @_;
    my @badfiles;
    #Unless dirname is specified, set current working directory
    unless ($dirname) {
       $dirname = `pwd`;
       chomp ($dirname);
    }
    unless (-d $dirname) {die "\n$dirname does not exist or is not a directory!\nYou have done something terribly wrong!\n"};
    my @checkfiles  = qw(
       var/build/da_advance_time.exe
       var/build/da_bias_airmass.exe
       var/build/da_bias_scan.exe
       var/build/da_bias_sele.exe
       var/build/da_bias_verif.exe
       var/build/da_rad_diags.exe
       var/build/da_tune_obs_desroziers.exe
       var/build/da_tune_obs_hollingsworth1.exe
       var/build/da_tune_obs_hollingsworth2.exe
       var/build/da_update_bc_ad.exe
       var/build/da_update_bc.exe
       var/build/da_verif_grid.exe
       var/build/da_verif_obs.exe
       var/build/da_wrfvar.exe
       var/build/gen_be_addmean.exe
       var/build/gen_be_cov2d3d_contrib.exe
       var/build/gen_be_cov2d.exe
       var/build/gen_be_cov3d2d_contrib.exe
       var/build/gen_be_cov3d3d_bin3d_contrib.exe
       var/build/gen_be_cov3d3d_contrib.exe
       var/build/gen_be_cov3d.exe
       var/build/gen_be_diags.exe
       var/build/gen_be_diags_read.exe
       var/build/gen_be_ensmean.exe
       var/build/gen_be_ensrf.exe
       var/build/gen_be_ep1.exe
       var/build/gen_be_ep2.exe
       var/build/gen_be_etkf.exe
       var/build/gen_be_hist.exe
       var/build/gen_be_stage0_gsi.exe
       var/build/gen_be_stage0_wrf.exe
       var/build/gen_be_stage1_1dvar.exe
       var/build/gen_be_stage1.exe
       var/build/gen_be_stage1_gsi.exe
       var/build/gen_be_stage2_1dvar.exe
       var/build/gen_be_stage2a.exe
       var/build/gen_be_stage2.exe
       var/build/gen_be_stage2_gsi.exe
       var/build/gen_be_stage3.exe
       var/build/gen_be_stage4_global.exe
       var/build/gen_be_stage4_regional.exe
       var/build/gen_be_vertloc.exe
       var/build/gen_mbe_stage2.exe
       var/obsproc/src/obsproc.exe
    );
    my $i = 0;
    my $filename;
    foreach (@checkfiles) {
       $filename="$dirname/$_";
       unless (-s $filename) {
          $badfiles[$i] = $_;
          $i++;
       }
    }
    return @badfiles;
}


sub check_baseline {

    my ($cbname, $cbArch, $cbMachine_name, $cbpar, $cbCompiler, $cbBaseline, $cbCompiler_version) = @_;

    print "\nComparing '$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler.$cbCompiler_version' 
              to '$cbBaseline/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler.$cbCompiler_version'" ;
    if (compare ("$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler.$cbCompiler_version",
                     "$cbBaseline/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler.$cbCompiler_version") == 0) {
        $Experiments{$cbname}{paropt}{$cbpar}{result} = "match";
    } elsif (compare ("$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler.$cbCompiler_version","$cbname/fg") == 0) {
        $Experiments{$cbname}{paropt}{$cbpar}{status} = "error";
        $Experiments{$cbname}{paropt}{$cbpar}{result} = "fg == wrfvar_output";
    } else {
        my $baselinetest = &compare_output ($cbname,$cbpar);
        my %result_problem = (
            1       => "diff",
            -1      => "ERROR",
            -2      => "Diffwrf comparison failed",
            -3      => "Output missing",
            -4      => "Baseline missing",
            -5      => "Could not open output and/or baseline",
            -6      => "NaN in output",
        );


        if ( $baselinetest ) {
            if ( $baselinetest < 0 ) {
                $Experiments{$cbname}{paropt}{$cbpar}{status} = "error";
                $Experiments{$cbname}{paropt}{$cbpar}{result} = $result_problem{$baselinetest};
            } elsif ( $baselinetest > 0 ) {
                $Experiments{$cbname}{paropt}{$cbpar}{result} = $result_problem{$baselinetest};
            }
        } elsif ( $missvars ) {
            $Experiments{$cbname}{paropt}{$cbpar}{result} = "ok, vars missing";
        } else {
            $Experiments{$cbname}{paropt}{$cbpar}{result} = "ok";
        }
    }

}


sub get_repo_revision {

#This function was originally made due to a Yellowstone upgrade which bungled up the 'svnversion' function.
#Should have the same functionality as old "svnversion" function for directories under SVN revision
#control, but will also try to retrieve the WRF/WRFDA release version if possible.

#Also appends an "m" to the revision number if the contents are versioned and have been modified.
#I think this was part of the original behavior of "svnversion" but I can't remember for sure.

#Needs to be updated with git functionality once we start the transition to git for version control

   my ($dir_name) = @_;
   my $wd = `pwd`;
   chomp ($wd);
   my $revnum;
   my $vernum;
   my $mod = '';

   if ( -d "$dir_name/.svn" ) {
      # Apparently svn info doesn't work on symlinks sometimes, so have to actually go into the directory >:[
      chdir $dir_name;
      open (my $fh,"-|","svn","info")
           or die " Can't run svn info: $!\n";
      while (<$fh>) {
         $revnum = $1 if ( /Revision: \s+ (\d+)/x);
      }
      close ($fh);

      open (my $fh2,"-|","svn","status","-q")
           or die " Can't run svn status: $!\n";
      while (my $row = <$fh2>) {
         if ( $row =~ /\S*/) {
            unless ($row =~ /^!/) { #We don't care if directories are missing; just modifications.
                                    #If important directories are missing everything will blow up anyway
               $mod = $row;
            }
         }
      }
      close ($fh2);
      if($mod=~/\S+/){
         $revnum = "$revnum"."m"; #Add an 'm' if modified
      }

      chdir $wd;
      return $revnum;

   } elsif ( -e "$dir_name/inc/version_decl" ) {
      open my $file, '<', "$dir_name/inc/version_decl"; 
      my $readfile = <$file>; 
      close $file;
      $readfile =~ /\x27(.+)\x27/;
      $vernum = $1;

      return $vernum;
   } else {

      return "exported";

   }

}

