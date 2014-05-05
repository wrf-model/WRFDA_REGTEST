#!/usr/bin/perl -w
# Author  : Xin Zhang, MMM/NCAR, 8/17/2009
# Updates : March 2013, adapted for Loblolly (PC) and Yellowstone (Mike Kavulich) 
#           August 2013, added 4DVAR test capability (Mike Kavulich)
#           December 2013, added parallel/batch build capability (Mike Kavulich)
#
#

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

#This little bit makes sure the input arguments are formatted correctly
foreach ( @ARGV ) {
  my $arg = $_;
  my $first_two = substr($arg, 0, 2); 
  unless ($first_two eq "--") {
    print "\n Unknown option: $arg \n";
    &print_help_and_die;
  }
}


GetOptions( "compiler=s" => \$Compiler_defined,
            "source:s" => \$Source_defined, 
            "revision:s" => \$Revision,
            "upload:s" => \$Upload_defined,
            "exec:s" => \$Exec_defined,
            "debug:s" => \$Debug_defined,
            "j:s" => \$Parallel_compile_num) or &print_help_and_die;

unless ( defined $Compiler_defined ) {
  print "\nCOMPILER NOT SPECIFIED, ABORTING\n\n";
  &print_help_and_die;
}


sub print_help_and_die {
  print "\nUsage : regtest.pl --compiler=COMPILER --source=SOURCE_CODE.tar --revision=NNNN --upload=[no]/yes
                              --exec=[no]/yes --debug=[no]/yes/super --j=NUM_PROCS\n";
  print "        compiler: Compiler name (supported options: xlf, pgi, g95, ifort, gfortran)\n";
  print "        source:   Specify location of source code .tar file (use 'SVN' to retrieve from repository\n";
  print "        revision: Specify code revision to retrieve (only works when '--source=SVN' specified\n";
  print "        upload:   Uploads summary to web (default is 'yes' iff source=SVN and revision=HEAD)\n";
  print "        exec:     Execute only; skips compile, utilizes existing executables\n\n";
  print "        debug:    'yes' compiles with minimal optimization; 'super' compiles with debugging options as well\n";
  print "        j:        Number of processors to use in parallel compile (default 2)\n";
  print "Please note:\n";
  die "A compiler MUST be specified to run this script. Other options are optional.\n";
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

# Constant variables
my $SVN_REP = 'https://svn-wrf-model.cgd.ucar.edu/trunk';
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
my $compile_job_list = "";
my $Database;
my $Baseline;
my $MainDir;
my @Message;
my $Par="";
my $Par_4dvar="";
my $Type="";
my $Clear = `clear`;
my $Flush_Counter = 1;
my $diffwrfdir = "";
my $missvars;
my @gtsfiles;
my @childs;
my %Experiments ;
#   Sample %Experiments Structure: #####################
#   
#   %Experiments (
#                  cv3_guo => \%record (
#                                     index=> 1 
#                                     cpu_mpi=> 32
#                                     cpu_openmp=> 8
#                                     status=>"open"
#                                     paropt => { 
#                                                serial => {
#                                                           jobid => 89123
#                                                           status => "pending"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "ok"
#                                                          } 
#                                                smpar  => {
#                                                           jobid => 89123
#                                                           status => "done"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "ok"
#                                                          } 
#                                               }
#                                     )
#                  t44_liuz => \%record (
#                                     index=> 3 
#                                     cpu_mpi=> 16
#                                     cpu_openmp=> 4
#                                     status=>"open"
#                                     paropt => { 
#                                                serial => {
#                                                           jobid => 89123
#                                                           status => "pending"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "diff"
#                                                          } 
#                                               }
#                                     )
#                 )
#########################################################
my %Compile_options;
my %Compile_options_4dvar;
my %compile_job_array;

# What's my name?

my $ThisGuy = `whoami`;
chomp($ThisGuy);

# Where am I?
$MainDir = `pwd`;
chomp($MainDir);

# What's my hostname, system, and machine?

my $Host = hostname();
my $System = `uname -s`; chomp($System);
my $Local_machine = `uname -m`; chomp($Local_machine);
my $Machine_name = `uname -n`; chomp($Machine_name); 

if ($Machine_name =~ /yslogin\d/) {$Machine_name = 'yellowstone'};


#Sort out the compiler name and version differences

my %convert_compiler = (
    gfortran    => "gfortran",
    gnu         => "gfortran",
    pgf90       => "pgi",
    pgi         => "pgi",
    intel       => "ifort",
    ifort       => "ifort",
);

my $Compiler_defined_conv .= $convert_compiler{$Compiler_defined};

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
    die "\n ERROR ASSIGNING C COMPILER\n";
}


#if ($Machine_name eq 'yellowstone') {
#   my %yellowstone_compiler = (
#      gfortran    => "gnu",
#      pgi         => "pgi",
#      ifort       => "intel",
#);
#my $ys_compiler .= $yellowstone_compiler{$Compiler_defined};
#}

my $Compiler_version;
if ($Machine_name eq 'yellowstone') {
   $Compiler_version = $ENV{COMPILER_VERSION}
}

# Parse the task table:

open(DATA, "<testdata.txt") or die "Couldn't open testdata.txt, see README for more info $!";

while (<DATA>) {
     last if ( /^###/ && (keys %Experiments) > 0 );
     next if /^#/;
     if ( /^(\D)/ ) {
         ($Arch, $Machine, $Name, $Source, $Compiler, $Project, $Queue, $Database, $Baseline) = 
               split /\s+/,$_;
     }

     if ( /^(\d)+/ && ($System =~ /$Arch/i) ) {
#       printf "Local_machine=$Local_machine Machine=$Machine \n";
       if ( ($Local_machine =~ /$Machine/i) ) {
#         printf "SUCCESS1 \n Compiler=$Compiler Compiler_defined=$Compiler_defined \n";
         if ( ($Compiler =~ /$Compiler_defined/i) ) {
            if ( ($Arch =~ /Linux/i) ) {
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
                    foreach (@tasks) {
                        $Par = join('|',$Par,$_) unless ($Par =~ /$_/);
                    }
                }
              };
            } else {
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
              $Par = $6 unless ($Par =~ /$6/);
            };
         }; 
       };
     }; 
}


if ($Par_4dvar =~ /serial/i) {
    print "\nNOTE: 4DVAR serial builds not supported. Will not compile 4DVAR for serial.\n\n";
    $Par_4dvar =~ s/serial\|//g;
    $Par_4dvar =~ s/\|serial//g;
    $Par_4dvar =~ s/serial//g;
    sleep 1;
}


#Remove "|" from the start of parallelism strings
$Par_4dvar =~ s/^\|//g;
$Par =~ s/^\|//g;

foreach my $name (keys %Experiments) {
    unless ( $Type =~ $Experiments{$name}{test_type}) {
        $Type = join('|',$Type,$Experiments{$name}{test_type});
    }

}

# If source specified on command line, use it
$Source = $Source_defined if defined $Source_defined;

# Upload summary to web by default if source is head of repository; 
# otherwise do not upload unless upload option is explicitly selected
my $Upload
if ( ($Debug == 0) && ($Exec == 0) && ($Source eq "SVN") && ($Revision eq "HEAD") && !(defined $Upload_defined) ) {
   $Upload="yes";
    print "\nSource is head of repository: will upload summary to web when test is complete.\n";
} elsif ( !(defined $Upload_defined) ) {
   $Upload="no";
}

# If specified paths are relative then point them to the full path
if ( !($Source =~ /^\//) ) {
   unless ( ($Source eq "SVN") or $Exec) {$Source = $MainDir."/".$Source};
}
if ( !($Database =~ /^\//) ) {
   $Database = $MainDir."/".$Database;
}
if ( !($Baseline =~ /^\//) ) {
   $Baseline = $MainDir."/".$Baseline;
}


printf "Finished parsing the table, the experiments are : \n";
printf "#INDEX   EXPERIMENT                   TYPE                    CPU_MPI  CPU_OPENMP    PAROPT\n";
printf "%-4d     %-27s  %-23s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n", 
     $Experiments{$_}{index}, $_, $Experiments{$_}{test_type},$Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
         keys%{$Experiments{$_}{paropt}} for (keys %Experiments);

die "\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (Mac OSx): pgi, g95 \n\n" unless (keys %Experiments) > 0 ; 


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
   if ( ($Type =~ /4DVAR/i) && ($Type =~ /3DVAR/i) ) {
      if ( ($Par =~ /dmpar/i) && ($Par_4dvar =~ /dmpar/i) ) {
         my $Revision3 = `svnversion WRFDA_3DVAR_dmpar`;
         my $Revision4 = `svnversion WRFDA_4DVAR_dmpar`;
         die "Check your existing code: WRFDA_3DVAR_dmpar and WRFDA_4DVAR_dmpar do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = `svnversion WRFDA_3DVAR_dmpar`;
      }
   } elsif ($Type =~ /4DVAR/i) {
      $Revision = `svnversion WRFDA_4DVAR_dmpar`;
   } else {
      if ( $Par =~ /dmpar/i ) {
         $Revision = `svnversion WRFDA_3DVAR_dmpar`;
      } else {
         $Revision = `svnversion WRFDA_3DVAR_serial`;
      }
   }
   chomp($Revision);
   goto "SKIP_COMPILE";
}

# Set necessary environment variables for compilation

$ENV{J}="-j $Parallel_compile_num";

  if ($Arch eq "Linux") {
      if ($Machine_name eq "yellowstone") { # Yellowstone
          $ENV{CRTM}='1';
          $ENV{BUFR}='1';
          if ($Compiler=~/ifort/i) {   # INTEL
              my $RTTOV_dir = "/glade/u/home/$ThisGuy/libs/rttov_intel_$Compiler_version";
              if (-d $RTTOV_dir) {
                  $ENV{RTTOV} = $RTTOV_dir;
                  print "Using RTTOV libraries in $RTTOV_dir\n";
              } else {
                  print "$RTTOV_dir DOES NOT EXIST\n";
                  print "RTTOV Libraries have not been compiled with $Compiler version $Compiler_version\nRTTOV tests will fail!\n";
              }
          } elsif ($Compiler=~/gfortran/i) {   # GNU
              my $RTTOV_dir = "/glade/u/home/$ThisGuy/libs/rttov_gnu_$Compiler_version";
              if (-d $RTTOV_dir) {
                  $ENV{RTTOV} = $RTTOV_dir;
                  print "Using RTTOV libraries in $RTTOV_dir\n";
              } else {
                  print "$RTTOV_dir DOES NOT EXIST\n";
                  print "RTTOV Libraries have not been compiled with $Compiler version $Compiler_version\nRTTOV tests will fail!\n";
              }
          } elsif ($Compiler=~/pgi/i) {   # PGI

              my $RTTOV_dir = "/glade/u/home/$ThisGuy/libs/rttov_pgi_$Compiler_version";
              if (-d $RTTOV_dir) {
                 $ENV{RTTOV} = $RTTOV_dir;
                  print "Using RTTOV libraries in $RTTOV_dir\n";
              } else {
                 print "$RTTOV_dir DOES NOT EXIST\n";
                 print "RTTOV Libraries have not been compiled with $Compiler version $Compiler_version\nRTTOV tests will fail!\n";
              }
          }

      } else { # Loblolly
          if ($Compiler=~/pgi/i) {   # PGI
              $ENV{CRTM}='1';
              $ENV{BUFR}='1';
              $ENV{NETCDF} ='/loblolly/kavulich/libs/netcdf-4.1.3-pgf90-pgcc';
          }
          if ($Compiler=~/ifort/i) {   # INTEL
              $ENV{CRTM}='1';
              $ENV{BUFR}='1';
          }
          if ($Compiler=~/gfortran/i) {   # GFORTRAN
              $ENV{CRTM}='1';
              $ENV{BUFR}='1';
              $ENV{NETCDF} ='/loblolly/kavulich/libs/netcdf-3.6.3-gfortran-gcc';
          }
          my $RTTOV_dir = "/loblolly/kavulich/libs/rttov-11.1/$Compiler";
          if (-d $RTTOV_dir) {
              $ENV{RTTOV} = $RTTOV_dir;
              print "Using RTTOV libraries in $RTTOV_dir\n";
          } else {
              print "$RTTOV_dir DOES NOT EXIST\n";
              print "RTTOV Libraries have not been compiled with $Compiler\nRTTOV tests will fail!\n";
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
  }

  if ($Arch eq "Darwin") {   # Darwin
      if ($Compiler=~/g95/i) {   # G95
          $ENV{CRTM} ='1';
          $ENV{BUFR} ='1';
      }
      if ($Compiler=~/pgi/i) {   # PGI
          $ENV{CRTM} ='1';
          $ENV{BUFR} ='1';
          $ENV{NETCDF} ='/gum2/kavulich/libs/netcdf-3.6.3-pgf90-gcc/';
      }
  }

#######################  BEGIN COMPILE 4DVAR  ########################

if ($Type =~ /4DVAR/i) {
  # Set WRFPLUS_DIR Environment variable
    my $WRFPLUSDIR = $MainDir."/WRFPLUSV3_$Compiler";
    chomp($WRFPLUSDIR);

    if (-d $WRFPLUSDIR) {
        $ENV{WRFPLUS_DIR} = $WRFPLUSDIR;
    } else {
        print "\n$WRFPLUSDIR DOES NOT EXIST\n";
        print "\nNOT COMPILING FOR 4DVAR!\n";
        $Type =~ s/4DVAR//gi;

        foreach my $name (keys %Experiments) {
            foreach my $type ($Experiments{$name}{test_type}) {
                delete $Experiments{$name} if ($type =~ /4DVAR/i) ;
                next ;
            }
        }


    }
}


if ($Type =~ /4DVAR/i) {

  # Set WRFPLUS_DIR Environment variable

   foreach (split /\|/, $Par_4dvar) { #foreach1
      my $par_type = $_;



      # Get WRFDA code

      if ( -e "WRFDA_4DVAR_$par_type" && -r "WRFDA_4DVAR_$par_type" ) {
         printf "Deleting the old WRFDA_4DVAR_$par_type directory ... \n";
         rmtree ("WRFDA_4DVAR_$par_type") or die "Can not rmtree WRFDA_4DVAR_$par_type :$!\n";
      }

      if ($Source eq "SVN") {
         print "Getting the code from repository $SVN_REP to WRFDA_4DVAR_$par_type...\n";
         open (my $fh,"-|","svn","co","-r",$Revision,$SVN_REP,"WRFDA_4DVAR_$par_type")
            or die " Can't run svn export: $!\n";
         while (<$fh>) {
            $Revision = $1 if ( /revision \s+ (\d+)/x);
         }
         close ($fh);
         printf "Revision %5d is exported to WRFDA_4DVAR_$par_type.\n",$Revision;
      } else {
         print "Getting the code from $Source to WRFDA_4DVAR_$par_type...\n";
         ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
         ! system("mv", "WRFDA", "WRFDA_4DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_4DVAR_$par_type': $!\n";
      }

      # Check the revision number:

      $Revision = `svnversion WRFDA_4DVAR_$par_type`;
      chomp($Revision);

      # Change the working directory to WRFDA:
      chdir "WRFDA_4DVAR_$par_type" or die "Cannot chdir to WRFDA_4DVAR_$par_type: $!\n";

      # Delete unnecessary directories to test code in release style
      if ( -e "chem" && -r "chem" ) {
         printf "Deleting chem directory ... \n";
         rmtree ("chem") or die "Can not rmtree chem :$!\n";
      }
      if ( -e "dyn_nmm" && -r "dyn_nmm" ) {
         printf "Deleting dyn_nmm directory ... \n";
         rmtree ("dyn_nmm") or die "Can not rmtree dyn_nmm :$!\n";
      }
      if ( -e "hydro" && -r "hydro" ) {
         printf "Deleting hydro directory ... \n";
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

      foreach (@output) {
         if ( ($_=~ m/(\d+)\. .*$Compiler .* $CCompiler .* ($Par_4dvar) .*/ix) &&
             ! ($_=~/Cray/i) &&
             ! ($_=~/PGI accelerator/i) &&
             ! ($_=~/SGI MPT/i)  ) {
            $Compile_options_4dvar{$1} = $2;
            $option = $1;
         }
      }


      printf "Found 4DVAR compilation option for %6s, option %2d.\n",$Compile_options_4dvar{$option}, $option;

      die "\nSHOULD NOT DIE HERE\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (Yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (Mac OSx): pgi, g95 \n\n" if ( (keys %Compile_options_4dvar) == 0 );

      # Set the envir. variables:
      if ($Arch eq "Linux") {
         if ($Machine_name ne "yellowstone") {
            unless ($Compiler=~/pgi/i or $Compiler=~/gfortran/i) {   # Only PGI for non-yellowstone Linux right now
               print "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
               print "\n!!                   WARNING                    !!";
               print "\n!! 4DVAR NOT YET IMPLEMENTED FOR THIS COMPILER! !!";
               print "\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            }
         }
      }
      if ($Arch eq "Darwin") {   # Darwin
         die "4DVAR not yet implemented for Mac\n";
      }


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
         print FH "./compile all_wrfvar >& compile.log.$Compile_options_4dvar{$option}\n";
         print FH "\n";
         close (FH);

         # Submit the job
         my $submit_message;
         $submit_message = `bsub < job_compile_4dvar_$Compile_options_4dvar{$option}_opt${option}.csh`;

         if ($submit_message =~ m/.*<(\d+)>/) {;
            print "Job ID for 4DVAR $Compiler option $Compile_options_4dvar{$option} is $1 \n";
            $compile_job_array{$1} = "4DVAR_$Compile_options_4dvar{$option}";
            $compile_job_list = join('|',$compile_job_list,$1);
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
             open FH, ">compile.log.$Compile_options_4dvar{$option}" or die "Can not open file compile.log.$Compile_options_4dvar{$option}.\n";
             $pid = open (PH, "./compile all_wrfvar 2>&1 |");
             while (<PH>) {
                 print FH;
             }
             close (PH);
             close (FH);

#       system("./compile all_wrfvar >> compile.log.$Compile_options_4dvar{$option}");

             my $end_time = gettimeofday();

             # Check if the compilation is successful:

             my @exefiles = glob ("var/build/*.exe");

             foreach ( @exefiles ) {
                 warn "The exe file $_ has problem. \n" unless -s ;
             }


             # Rename the executables:
             rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options_4dvar{$option}"
                 or die "Program da_wrfvar.exe not created: check your compilation log.\n";

             printf "Compilation of WRFDA_4DVAR_$par_type with %10s compiler for %6s was successful.\nCompilation took %4d seconds.\n",
                 $Compiler, $Compile_options_4dvar{$option}, ($end_time - $begin_time);

             # Save the compilation log file

             if (!-d "$MainDir/regtest_compile_logs/$year$mon$mday") {
                mkpath("$MainDir/regtest_compile_logs/$year$mon$mday") or die "mkpath failed: $!\n$MainDir/regtest_compile_logs/$year$mon$mday";
         }
             copy( "compile.log.$Compile_options_4dvar{$option}", "../regtest_compile_logs/$year$mon$mday/compile_4dvar.log.$Compile_options_4dvar{$option}_$Compiler\_$hour:$min:$sec" ) or die "Copy failed: $!\ncompile.log.$Compile_options_4dvar{$option}\n../regtest_compile_logs/$year$mon$mday/compile_4dvar.log.$Compile_options_4dvar{$option}_$Compiler\_$hour:$min:$sec";
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
            rmtree ("WRFDA_3DVAR_$par_type") or die "Can not rmtree WRFDA_3DVAR_$par_type :$!\n";
       }

       if ($Source eq "SVN") {
            print "Getting the code from repository $SVN_REP to WRFDA_3DVAR_$par_type...\n";
            open (my $fh,"-|","svn","co","-r",$Revision,$SVN_REP,"WRFDA_3DVAR_$par_type")
                 or die " Can't run svn export: $!\n";
            while (<$fh>) {
                $Revision = $1 if ( /revision \s+ (\d+)/x); 
            }
            close ($fh);
            printf "Revision %5d is exported to WRFDA_3DVAR_$par_type.\n",$Revision;
       } else {
            print "Getting the code from $Source to WRFDA_3DVAR_$par_type...\n";
            ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
            ! system("mv", "WRFDA", "WRFDA_3DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_3DVAR_$par_type': $!\n";
       }

       # Check the revision number:

       $Revision = `svnversion WRFDA_3DVAR_$par_type`;
       chomp($Revision);
 
       # Change the working directory to WRFDA:
     
       chdir "WRFDA_3DVAR_$par_type" or die "Cannot chdir to WRFDA_3DVAR_$par_type: $!\n";

       # Delete unnecessary directories to test code in release style
       if ( -e "chem" && -r "chem" ) {
          printf "Deleting chem directory ... \n";
          rmtree ("chem") or die "Can not rmtree chem :$!\n";
       }
       if ( -e "dyn_nmm" && -r "dyn_nmm" ) {
          printf "Deleting dyn_nmm directory ... \n";
          rmtree ("dyn_nmm") or die "Can not rmtree dyn_nmm :$!\n";
       }
       if ( -e "hydro" && -r "hydro" ) {
          printf "Deleting hydro directory ... \n";
          rmtree ("hydro") or die "Can not rmtree hydro :$!\n";
       }

       # Locate the compile options base on the $compiler:
       my $pid = open2( my $readme, my $writeme, './configure','wrfda','2>/dev/null');
       print $writeme "1\n";
       my @output = <$readme>;
       waitpid($pid,0);
       close ($readme);
       close ($writeme);


#       # Add a slash before + in $Par !!! Needed if we support dm+sm in the future !!!
#       $Par =~ s/\+/\\+/g;

       my $option;

       foreach (@output) {
          if ( ($_=~ m/(\d+)\. .*$Compiler .* $CCompiler .* ($par_type) .*/ix) &&
              ! ($_=~/Cray/i) &&
              ! ($_=~/PGI accelerator/i) &&
              ! ($_=~/SGI MPT/i)  ) {
             $Compile_options{$1} = $2;
             $option = $1;
          }
       }


       printf "Found 3DVAR compilation option for %6s, option %2d.\n",$Compile_options{$option}, $option;

       die "\nSHOULD NOT DIE HERE\nCompiler '$Compiler_defined' is not supported on this $System $Local_machine machine, '$Machine_name'. \n Supported combinations are: \n Linux x86_64 (Yellowstone): ifort, gfortran, pgi \n Linux x86_64 (loblolly): ifort, gfortran, pgi \n Linux i486, i586, i686: ifort, gfortran, pgi \n Darwin (Mac OSx): pgi, g95 \n\n" if ( (keys %Compile_options) == 0 );

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
                $compile_job_list = join('|',$compile_job_list,$1);
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
                open FH, ">compile.log.$Compile_options{$option}" or die "Can not open file compile.log.$Compile_options{$option}.\n";
                $pid = open (PH, "./compile all_wrfvar 2>&1 |");
                while (<PH>) {
                    print FH;
                }
                close (PH);
                close (FH);
                my $end_time = gettimeofday();

                # Check if the compilation is successful:

                my @exefiles = glob ("var/build/*.exe");

                die "The number of exe files is less than 42. \n" if (@exefiles < 42);
     
                foreach ( @exefiles ) {
                    warn "The exe file $_ has problem. \n" unless -s ;
                }
     

                # Rename executables:

                rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options{$option}"
                    or die "Program da_wrfvar.exe not created: check your compilation log.\n";

                printf "Compilation of WRFDA_3DVAR_$par_type with %10s compiler for %6s was successful.\nCompilation took %4d seconds.\n",
                    $Compiler, $Compile_options{$option}, ($end_time - $begin_time);

                # Save the compilation log file

                if (!-d "$MainDir/regtest_compile_logs/$year$mon$mday") {
                    mkpath("$MainDir/regtest_compile_logs/$year$mon$mday") or die "mkpath failed: $!\n$MainDir/regtest_compile_logs/$year$mon$mday";
                }
                copy( "compile.log.$Compile_options{$option}", "../regtest_compile_logs/$year$mon$mday/compile.log.$Compile_options{$option}_$Compiler\_$hour:$min:$sec" ) or die "Copy failed: $!\ncompile.log.$Compile_options{$option}\n../regtest_compile_logs/$year$mon$mday/compile.log.$Compile_options{$option}_$Compiler\_$hour:$min:$sec";
                exit 0; #Exit child process! Quite important or else you get stuck forever!
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
    waitpid($_, 0);
}




# For batch build, keep track of ongoing compile jobs, continue when finished.
while ( $compile_job_list ) {
   # Remove '|' from start of "compile_job_list"
   $compile_job_list =~ s/^\|//g;

   foreach ( split /\|/, $compile_job_list ) {
      my $jobnum = $_;
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

      rename "WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe","WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe.$Compiler.$details[1]" or die "Program da_wrfvar.exe not created for $details[0], $details[1]: check your compilation log.\n";

      # Delete job from list of active jobs
      $compile_job_list =~ s/$jobnum//g;
      $compile_job_list =~ s/^\|//g;

   }
   sleep 2;
}



SKIP_COMPILE:

if ($Type =~ /3DVAR/i) {
   if ( $Par =~ /serial/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in serial in directory tree named 'WRFDA_3DVAR_serial' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_serial");
   }
   if ( $Par =~ /dmpar/i ) {
      die "\nSTOPPING SCRIPT\n3DVAR code must be compiled to run in parallel in directory tree named 'WRFDA_3DVAR_dmpar' in the working directory to use 'exec=yes' option.\n\n" unless (-d "WRFDA_3DVAR_dmpar");
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




# Make working directory for each Experiments:


if ( ($Machine_name eq "yellowstone") ) {
    printf "Moving to scratch space: /glade/scratch/$ThisGuy/REGTEST/$Compiler\_$year$mon$mday\_$hour:$min:$sec\n";
    mkpath("/glade/scratch/$ThisGuy/REGTEST/$Compiler\_$year$mon$mday\_$hour:$min:$sec") or die "Mkdir failed: $!";
    chdir "/glade/scratch/$ThisGuy/REGTEST/$Compiler\_$year$mon$mday\_$hour:$min:$sec" or die "Chdir failed: $!";
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
         symlink "$_", basename($_)
             or warn "Cannot symlink $_ to local directory: $!\n";
     }
     

     printf "The directory for %-30s is ready.\n",$name;

     my @files = glob("*.bufr");

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

#foreach my $name (keys %Experiments) {
#  print "REMAIN_PAR{$name} = $remain_par{$name}\n";
#}

# preset the the status of all jobs .

foreach my $name (keys %Experiments) {
    $Experiments{$name}{status} = "pending";
    foreach my $par (keys %{$Experiments{$name}{paropt}}) {
        $Experiments{$name}{paropt}{$par}{status} = "pending";
        $Experiments{$name}{paropt}{$par}{compare} = "--";
        $Experiments{$name}{paropt}{$par}{walltime} = 0;
        $Experiments{$name}{paropt}{$par}{queue} = $Experiments{$name}{test_type};
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

#print $Clear;
#print @Message;
print SENDMAIL $Start_time."\n";
print SENDMAIL "Source: ",$Source."\n";
print SENDMAIL "Revision: ",$Revision."\n";
print SENDMAIL "Tester: ",$Tester."\n";
print SENDMAIL "Machine name: ",$Host."\n";
print SENDMAIL "Operating system: ",$System,", ",$Machine."\n";
print SENDMAIL "Compiler: ",$Compiler."\n";
print SENDMAIL "Baseline: ",$Baseline."\n";
print SENDMAIL @Message;
print SENDMAIL $End_time."\n";

close(SENDMAIL);

#
#
#

sub create_webpage {

    open WEBH, ">summary_$Compiler.html" or
        die "Can not open summary_$Compiler.html for write: $!\n";

    print WEBH '<html>'."\n";
    print WEBH '<body>'."\n";

    print WEBH '<p>'."Regression Test Summary:".'</p>'."\n";
    print WEBH '<ul>'."\n";
    print WEBH '<li>'.$Start_time.'</li>'."\n";
    print WEBH '<li>'."Source : $Source".'</li>'."\n";
    print WEBH '<li>'."Revision : $Revision".'</li>'."\n";
    print WEBH '<li>'."Tester : $Tester".'</li>'."\n";
    print WEBH '<li>'."Machine name : $Host".'</li>'."\n";
    print WEBH '<li>'."Operating system : $System".'</li>'."\n";
    print WEBH '<li>'."Compiler : $Compiler".'</li>'."\n";
    print WEBH '<li>'."Baseline : $Baseline".'</li>'."\n";
    print WEBH '<li>'.$End_time.'</li>'."\n";
    print WEBH '</ul>'."\n";

    print WEBH '<table border="1">'."\n";
#   print WEBH '<caption>Regression Test Summary</caption>'."\n";
    print WEBH '<tr>'."\n";
    print WEBH '<th>EXPERIMENT</th>'."\n";
    print WEBH '<th>TYPE</th>'."\n";
    print WEBH '<th>PAROPT</th>'."\n";
    print WEBH '<th>CPU_MPI</th>'."\n";
    print WEBH '<th>CPU_OMP</th>'."\n";
    print WEBH '<th>STATUS</th>'."\n";
    print WEBH '<th>WALLTIME(S)</th>'."\n";
    print WEBH '<th>COMPARE</th>'."\n";
    print WEBH '</tr>'."\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            print WEBH '<tr>'."\n";
            print WEBH '<tr';
            if ($Experiments{$name}{paropt}{$par}{status} eq "error") {
                print WEBH ' style="background-color:red;color:white">'."\n";
            } elsif ($Experiments{$name}{paropt}{$par}{compare} eq "diff") {
                print WEBH ' style="background-color:yellow">'."\n";
            } else {
                print WEBH '>'."\n";
            }
            print WEBH '<td>'.$name.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{test_type}.'</td>'."\n";
            print WEBH '<td>'.$par.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{cpu_mpi}.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{cpu_openmp}.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{status}.'</td>'."\n";
            printf WEBH '<td>'."%5d".'</td>'."\n",
                         $Experiments{$name}{paropt}{$par}{walltime};
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{compare}.'</td>'."\n";
            print WEBH '</tr>'."\n";
        }
    }
            print WEBH '</table>'."\n"; 

    print WEBH '</body>'."\n";
    print WEBH '</html>'."\n";

    close (WEBH);

# Save summary, send to internet if requested:

    if ( ($Machine_name eq "yellowstone") ) {
        copy("summary_$Compiler.html","/glade/scratch/$ThisGuy/REGTEST/$Compiler\_$year$mon$mday\_$hour:$min:$sec/summary_$Compiler.html");
    }

    my $go_on='';

    if ( $Upload =~ /yes/i ) {
       if ( (!$Exec) && ($Revision =~ /\d+M$/) ) {
          print "This revision appears to be modified, are you sure you want to upload the summary?\a\n";
          while (!$go_on) {
             $go_on = <>;
             if ($go_on =~ /no/i) {
                die "Summary not uploaded to web.\n";
             } elsif ($go_on =~ /yes/i) {
             } else {
                print "Invalid input: ".$go_on."\nPlease type 'yes' or 'no':";
             }
          }
       }

       my $numexp= scalar keys %Experiments;

       if ( $numexp < 22 ) {
          $go_on='';
          print "This run only includes $numexp of 22 tests, are you sure you want to upload?\a\n";
          while (!$go_on) {
             $go_on = <>;
             if ($go_on =~ /no/i) {
                die "Summary not uploaded to web.\n";
             } elsif ($go_on =~ /yes/i) {
             } else {
                print "Invalid input: ".$go_on."\nPlease type 'yes' or 'no':";
             }
          }
       }

       unless ( $Source eq "SVN" ) {
          $go_on='';
          print "This revision, '$Source', may not be the trunk version,\nare you sure you want to upload?\a\n";
          while (!$go_on) {
             $go_on = <>;
             if ($go_on =~ /no/i) {
                die "Summary not uploaded to web.\n";
             } elsif ($go_on =~ /yes/i) {
             } else {
                print "Invalid input: ".$go_on."\nPlease type 'yes' or 'no':";
             }
          }
       }


       my @uploadit = ("scp", "summary_$Compiler.html", "kavulich\@nebula.mmm.ucar.edu:/web/htdocs/wrf/users/wrfda/regression/");
       system(@uploadit) == 0
          or die "Uploading 'summary_$Compiler.html' to web failed: $?\n";
       print "Summary successfully uploaded to: http://www.mmm.ucar.edu/wrf/users/wrfda/regression/summary_$Compiler.html\n";
    }
}

sub refresh_status {

    my @mes; 

    push @mes, "Experiment                  Paropt      CPU_MPI  CPU_OMP  Status    Walltime(s)    Compare\n";
    push @mes, "==========================================================================================\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            push @mes, sprintf "%-28s%-12s%-9d%-9d%-10s%-15d%-7s\n", 
                    $name, $par, $Experiments{$name}{cpu_mpi}, 
                    $Experiments{$name}{cpu_openmp}, 
                    $Experiments{$name}{paropt}{$par}{status},
                    $Experiments{$name}{paropt}{$par}{walltime},
                    $Experiments{$name}{paropt}{$par}{compare};
        }
    }

    push @mes, "==========================================================================================\n";
    return @mes;
}

sub new_job {
     
     my ($nam, $com, $par, $cpun, $cpum, $types) = @_;

     # Enter into the experiment working directory:

     if ($types =~ /3DVAR/i) {
#         printf "types: $types\n";
         $types =~ s/3DVAR//i;
         $Experiments{$nam}{paropt}{$par}{queue} = $types;
#         printf "New types: $types\n";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         if ($types =~ /OBSPROC/i) {
#             printf "types: $types\n";
             $types =~ s/OBSPROC//i;
             $Experiments{$nam}{paropt}{$par}{queue} = $types;
#             printf "New types: $types\n";

             printf "Running OBSPROC for $par job '$par'\n";

             `$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe &> obsproc.out`;

             @gtsfiles = glob ("obs_gts_*.3DVAR");
             if (defined $gtsfiles[0]) {
                 copy("$gtsfiles[0]","ob.ascii") or die "YOU HAVE COMMITTED AN OFFENSE!";
                 printf "OBSPROC complete\n";
             } else {
                 chdir "..";
                 return "OBSPROC_FAIL";
             }

         }

         # Submit the job :

         printf "Starting 3DVAR $par job '$nam'\n";

         if ($par=~/dm/i) { 
             # system ("mpdallexit>/dev/null");
             # system ("mpd&");
             # sleep (0.1);
             `mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par`;
         } else {
             `../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par > print.out.$Arch.$nam.$par.$Compiler`; 
         }
    
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );
    
         # Back to the upper directory:

         chdir ".." or die "Cannot chdir to .. : $!\n";
    
         return 1;

     } elsif ($types =~ /4DVAR/i) {
         printf "types: $types\n";
         $types =~ s/4DVAR//i;
         $Experiments{$nam}{paropt}{$par}{queue} = $types;
         printf "New types: $types\n";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         delete $ENV{OMP_NUM_THREADS};
         $ENV{OMP_NUM_THREADS}=$cpum if ($par=~/sm/i);

         if ($par=~/dm/i) {
             `mpirun -np $cpun ../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par`;
         } else {
             `../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par > print.out.$Arch.$nam.$par.$Compiler`;
         }
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         # Back to the upper directory:
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return 1;

     }
}

sub new_job_ys {

     my ($nam, $com, $par, $cpun, $cpum, $types) = @_;

     my $feedback;
     # Enter into the experiment working directory:
     


#     if ($types =~ /GENBE/i) {
#         printf "types: $types\n";
#         $types =~ s/GENBE//i;
#         $Experiments{$nam}{paropt}{$par}{queue} = $types;
#         printf "New types: $types\n";
     if ($types =~ /OBSPROC/i) {
#         printf "types: $types\n";
         $types =~ s/OBSPROC//i;
         $types =~ s/^\|//;
         $types =~ s/\|$//;
         $Experiments{$nam}{paropt}{$par}{queue} = $types;
#         printf "New types: $types\n";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         printf "Creating OBSPROC job: $nam, $par\n";


         # Generate the LSF job script         
         unlink "job_${nam}_obsproc_$par.csh" if -e 'job_$nam_$par.csh';
         open FH, ">job_${nam}_obsproc_$par.csh" or die "Can not open job_${nam}_obsproc_$par.csh to write. $! \n";

         print FH '#!/bin/csh'."\n";
         print FH '#',"\n";
         print FH '# LSF batch script'."\n";
         print FH '#'."\n";
         print FH "#BSUB -J $nam"."\n";
         # Don't use multiple processors for obsproc
         print FH "#BSUB -q ".$Queue."\n";
         printf FH "#BSUB -n 1\n";
         print FH "#BSUB -o job_${nam}_obsproc_$par.output"."\n";
         print FH "#BSUB -e job_${nam}_obsproc_$par.error"."\n";
         print FH "#BSUB -W 20"."\n";
         print FH "#BSUB -P $Project"."\n";
         # If job serial or smpar, span[ptile=1]; if job dmpar, span[ptile=16] or span[ptile=$cpun], whichever is less
         printf FH "#BSUB -R span[ptile=%d]"."\n", ($par eq 'serial' || $par eq 'smpar') ?
                                                    1 : (($cpun < 16 ) ? $cpun : 16);
         print FH "\n";

         print FH "$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe\n";

         print FH "\n";
         unless (-e "ob.ascii") {print FH "cp -f obs_gts_*.3DVAR ob.ascii\n"};
         print FH "\n";

         close (FH);

         # Submit the job

         $feedback = ` bsub < job_${nam}_obsproc_$par.csh 2>/dev/null `;


         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";


     } elsif ($types =~ /3DVAR/i) {
#         printf "types: $types\n";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";
         #If an OBSPROC job, make sure it created the observation file!
         if ($Experiments{$nam}{test_type} =~ /OBSPROC/i) {
             printf "Checking OBSPROC output\n";
             unless (-e "ob.ascii") {
                 chdir "..";
                 return "OBSPROC_FAIL";
             }
         }
         $types =~ s/3DVAR//i;
         $types =~ s/^\|//;
         $types =~ s/\|$//;
         $Experiments{$nam}{paropt}{$par}{queue} = $types;
#         printf "New types: $types\n";
         

         printf "Creating 3DVAR job: $nam, $par\n";


         # Generate the LSF job script:

         unlink "job_${nam}_3dvar_$par.csh" if -e 'job_$nam_$par.csh';
         open FH, ">job_${nam}_3dvar_$par.csh" or die "Can not open a job_${nam}_$par.csh to write. $! \n";
    
         print FH '#!/bin/csh'."\n";
         print FH '#',"\n";
         print FH '# LSF batch script'."\n";
         print FH '#'."\n";
         print FH "#BSUB -J $nam"."\n";
         # If more than 16 processors requested, can't use caldera
         print FH "#BSUB -q ".(($Queue eq 'caldera' && $cpun > 16) ? "small" : $Queue)."\n";
         printf FH "#BSUB -n %-3d"."\n",($par eq 'dmpar' || $par eq 'dm+sm') ?
                                        $cpun: 1;
         print FH "#BSUB -o job_${nam}_$par.output"."\n";
         print FH "#BSUB -e job_${nam}_$par.error"."\n";
         print FH "#BSUB -W 30"."\n";
         print FH "#BSUB -P $Project"."\n";
         # If job serial or smpar, span[ptile=1]; if job dmpar, span[ptile=16] or span[ptile=$cpun], whichever is less
         printf FH "#BSUB -R span[ptile=%d]"."\n", ($par eq 'serial' || $par eq 'smpar') ?
                                                    1 : (($cpun < 16 ) ? $cpun : 16);
         print FH "\n";
         print FH ( $par eq 'smpar' || $par eq 'dm+sm') ?
             "setenv OMP_NUM_THREADS $cpum\n" :"\n";
         print FH "\n";

         print FH "unsetenv MP_PE_AFFINITY\n";
         
         print FH ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         print FH "\n";
    
         close (FH);

         # Submit the job

         $feedback = ` bsub < job_${nam}_3dvar_$par.csh 2>/dev/null `;

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

     } elsif ($types =~ /4DVAR/i) {
         chdir "$nam" or die "Cannot chdir to $nam : $!\n";
         #If an OBSPROC job, make sure it created the observation file!
         if ($Experiments{$nam}{test_type} =~ /OBSPROC/i) {
             printf "Checking OBSPROC output\n";
             unless (-e "ob01.ascii") {
                 return "OBSPROC_FAIL";
             }
         }

         $types =~ s/4DVAR//i;
         $types =~ s/^\|//; # these lines remove
         $types =~ s/\|$//; # extra "|"
         $Experiments{$nam}{paropt}{$par}{queue} = $types;


         printf "Creating 4DVAR job: $nam, $par\n";


         # Generate the LSF job script:
         unlink "job_${nam}_4dvar_$par.csh" if -e 'job_$nam_$par.csh';
         open FH, ">job_${nam}_4dvar_$par.csh" or die "Can not open a job_${nam}_$par.csh to write. $! \n";

         print FH '#!/bin/csh'."\n";
         print FH '#',"\n";
         print FH '# LSF batch script'."\n";
         print FH '#'."\n";
         print FH "#BSUB -J $nam"."\n";
         # If more than 16 processors requested, can't use caldera
         print FH "#BSUB -q ".(($Queue eq 'caldera' && $cpun > 16) ? "small" : $Queue)."\n";
         printf FH "#BSUB -n %-3d"."\n",($par eq 'dmpar' || $par eq 'dm+sm') ?
                                        $cpun: 1;
         print FH "#BSUB -o job_${nam}_$par.output"."\n";
         print FH "#BSUB -e job_${nam}_$par.error"."\n";
         print FH "#BSUB -W 30"."\n";
         print FH "#BSUB -P $Project"."\n";
         # If job serial or smpar, span[ptile=1]; if job dmpar, span[ptile=16] or span[ptile=$cpun], whichever is less
         printf FH "#BSUB -R span[ptile=%d]"."\n", ($par eq 'serial' || $par eq 'smpar') ?
                                                    1 : (($cpun < 16 ) ? $cpun : 16);
         print FH "\n";
         print FH ( $par eq 'smpar' || $par eq 'dm+sm') ?
             "setenv OMP_NUM_THREADS $cpum\n" :"\n";
         print FH "\n";

         print FH ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         print FH "\n";

         close (FH);

         # Submit the job
         $feedback = ` bsub < job_${nam}_4dvar_$par.csh 2>/dev/null `;

         # Return to the upper directory

         chdir ".." or die "Cannot chdir to .. : $!\n";

     } else {
         die "You dun goofed!\n";
     }



     # Pick the job id

     if ($feedback =~ m/.*<(\d+)>/) {;
          # printf "Task %-30s 's jobid is %10d \n",$nam,$1;
         return $1;
     } else {
         print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit task for $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
         return undef;
     };


}


sub compare_output {
   
     my ($name, $par) = @_;

     my $diffwrfpath = $diffwrfdir . "diffwrf";

     return -3 unless ( -e "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler");
     return -4 unless ( -e "$Baseline/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler");

     my @output = `$diffwrfpath $name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler $Baseline/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler`;
 
     return -2 if (!@output);
     
     my $found = 0;
     my $sumfound = 0;
     $missvars = 0 ;

     foreach (@output) {
         
#         print "\nThis line is '$_'\n";

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
         
     
     }

     return -1 if ($sumfound == 0); # Return error if diffwrf output does not make sense

     print "\nTotal missing variables: $missvars\n";

     return 0;        # All the same.

}


sub flush_status {

    @Message = &refresh_status ();   # Update the Message
    print $Clear; 
    # print $Flush_Counter++ ,"\n";
    print @Message;

}

sub submit_job {

    foreach my $name (keys %Experiments) {

        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            #Set the start time for this job
            $Experiments{$name}{paropt}{$par}{starttime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{status} = "running";
            &flush_status (); # refresh the status

            #Submit job
            my $rc = &new_job ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                $Experiments{$name}{cpu_openmp},$Experiments{$name}{paropt}{$par}{queue} );

            #Set the end time for this job
            $Experiments{$name}{paropt}{$par}{endtime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{walltime} =
                $Experiments{$name}{paropt}{$par}{endtime} - $Experiments{$name}{paropt}{$par}{starttime};
            if (defined $rc) { 
                if ($rc =~ /OBSPROC_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{compare} = "obsproc failed";
                    &flush_status ();
                    next;
                } else {
                    printf "%-10s job for %-30s was finished in %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};
                }
            } else {
                $Experiments{$name}{paropt}{$par}{status} = "error";
                $Experiments{$name}{paropt}{$par}{compare} = "Mysterious error!";
                &flush_status ();
                next;   # Can not submit this job.
            }

            $Experiments{$name}{paropt}{$par}{status} = "done";

            # Wrap-up this job:

            rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler";

            # Compare the wrfvar_output with the BASELINE:

            unless ($Baseline =~ /none/i) {
                if (compare ("$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler","$Baseline/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler") == 0) {
                    $Experiments{$name}{paropt}{$par}{compare} = "match";
                } elsif (compare ("$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler","$name/fg") == 0) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{compare} = "fg == wrfvar_output";
                } else {
                    my $baselinetest = &compare_output ($name,$par);
                    my %compare_problem = (
                        1       => "diff",
                        -1      => "Unknown error",
                        -2      => "diffwrf comparison failed",
                        -3      => "Output missing",
                        -4      => "Baseline missing",
                        -5      => "Could not open output and/or baseline",
                    );
                    
                    if ( $baselinetest ) {
                        if ( $baselinetest < 0 ) {
                            $Experiments{$name}{paropt}{$par}{status} = "error";
                            $Experiments{$name}{paropt}{$par}{compare} = $compare_problem{$baselinetest};
                        } elsif ( $baselinetest > 0 ) {
                            $Experiments{$name}{paropt}{$par}{compare} = $compare_problem{$baselinetest};
                        }
                    } elsif ( $missvars ) {
                        $Experiments{$name}{paropt}{$par}{compare} = "ok, vars missing";
                    } else {
                        $Experiments{$name}{paropt}{$par}{compare} = "ok";
                    }
                }
            }
        }

    }

    &flush_status (); # refresh the status
}

sub submit_job_ys {

    while ($remain_exps > 0) {    # cycling until no more experiments remain

         #This first loop submits all parallel jobs

         foreach my $name (keys %Experiments) {

             next if ($Experiments{$name}{status} eq "done") ;  # skip this experiment if it is done.

             foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {

#                 die "Not okay, this is bad.\n" unless ($Experiments{$name}{paropt}{$par}{queue});

#                 print $Experiments{$name}{paropt}{$par}{queue}."\n";

                 next if ( $Experiments{$name}{paropt}{$par}{status} eq "done"  ||      # go to next job if it is done already..
                           $Experiments{$name}{paropt}{$par}{status} eq "error" );

                 unless ( defined $Experiments{$name}{paropt}{$par}{jobid} ) {      #  to be submitted .

                     next if $Experiments{$name}{status} eq "close";      #  skip if this experiment already has a job running.
                         my $rc = &new_job_ys ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                         $Experiments{$name}{cpu_openmp},$Experiments{$name}{paropt}{$par}{queue} );

                     if (defined $rc) {
                         if ($rc =~ /OBSPROC_FAIL/) {
                             $Experiments{$name}{paropt}{$par}{status} = "error";
                             $Experiments{$name}{paropt}{$par}{compare} = "obsproc failed";
                             $remain_par{$name} -- ;
                             if ($remain_par{$name} == 0) {
                                 $Experiments{$name}{status} = "done";
                                 $remain_exps -- ;
                             }
                             &flush_status ();
                             next;
                         } else {
                             $Experiments{$name}{paropt}{$par}{jobid} = $rc ;    # assign the jobid.
                             $Experiments{$name}{status} = "close";
                             my $checkQ = `bjobs $Experiments{$name}{paropt}{$par}{jobid}`;
                             if ($checkQ =~ /\ssmall\s/) {
                                 printf "%-10s job for %-30s was submitted to queue 'small' with jobid: %10d \n", $par, $name, $rc;
                             } else {
                                 printf "%-10s job for %-30s was submitted to queue '$Queue' with jobid: %10d \n", $par, $name, $rc;
                             }
                         }
                     } else {
                         $Experiments{$name}{paropt}{$par}{status} = "error";
                         $Experiments{$name}{paropt}{$par}{compare} = "Job submit failed";
                         $remain_par{$name} -- ;
                         if ($remain_par{$name} == 0) {
                             $Experiments{$name}{status} = "done";
                             $remain_exps -- ;
                         }
                         &flush_status ();
                         next;
                     }
                 }

                 # Job is still in queue.

                 my $feedback = `bjobs $Experiments{$name}{paropt}{$par}{jobid}`;
                 if ( $feedback =~ m/RUN/ ) {; # Still running
                     unless (defined $Experiments{$name}{paropt}{$par}{started}) { #set the start time when we first find it is running.
                         $Experiments{$name}{paropt}{$par}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{started} = 1;
                         &flush_status (); # refresh the status
                     }
                     next;
                 } elsif ( $feedback =~ m/PEND/ ) { # Still Pending
                     next;
                 }

                 # Job is finished.
                 my $bhist = `bhist $Experiments{$name}{paropt}{$par}{jobid}`;
                 my @jobhist = split('\s+',$bhist);
                 if ($Experiments{$name}{paropt}{$par}{walltime} == 0) {
                     $Experiments{$name}{paropt}{$par}{walltime} = $jobhist[24];
                 } else {
                     $Experiments{$name}{paropt}{$par}{walltime} = $Experiments{$name}{paropt}{$par}{walltime} + $jobhist[24];
                 }
                 

                 if ($Experiments{$name}{paropt}{$par}{queue}) {
                     print "$Experiments{$name}{paropt}{$par}{queue}\n";
                     delete $Experiments{$name}{paropt}{$par}{jobid};       # Delete the jobid.
                     $Experiments{$name}{paropt}{$par}{status} = "pending";    # Still more tasks for this job.

                     printf "First task of %-10s job for %-30s took %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};


                 } else {
                     delete $Experiments{$name}{paropt}{$par}{jobid};       # Delete the jobid.
                     $remain_par{$name} -- ;                               # Delete the count of jobs for this experiment.
                     $Experiments{$name}{paropt}{$par}{status} = "done";    # Done this job.

                     printf "%-10s job for %-30s was completed in %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};

                     # Wrap-up this job:

                     rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler";

                     # Compare against the baseline

                     unless ($Baseline =~ /none/i) {
                         &check_baseline_ys ($name, $Arch, $Machine_name, $par, $Compiler, $Baseline);
                     }
                 }


                 if ($remain_par{$name} == 0) {                        # if all par options are done, this experiment is finished.
                     $Experiments{$name}{status} = "done";
                     $remain_exps -- ;
                 } else {
                     $Experiments{$name}{status} = "open";              # Since this experiment is not done yet, open to submit job.
                 }

                 &flush_status ();
             }

         }
         sleep (2.);

    }

}

sub check_baseline_ys {

    my ($cbname, $cbArch, $cbMachine_name, $cbpar, $cbCompiler, $cbBaseline) = @_;

    print "\nComparing '$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler' 
              to '$cbBaseline/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler'" ;
    if (compare ("$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler",
                     "$cbBaseline/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler") == 0) {
        $Experiments{$cbname}{paropt}{$cbpar}{compare} = "match";
    } elsif (compare ("$cbname/wrfvar_output.$cbArch.$cbMachine_name.$cbname.$cbpar.$cbCompiler","$cbname/fg") == 0) {
        $Experiments{$cbname}{paropt}{$cbpar}{status} = "error";
        $Experiments{$cbname}{paropt}{$cbpar}{compare} = "fg == wrfvar_output";
    } else {
        my $baselinetest = &compare_output ($cbname,$cbpar);
        my %compare_problem = (
            1       => "diff",
            -1      => "ERROR",
            -2      => "Diffwrf comparison failed",
            -3      => "Output missing",
            -4      => "Baseline missing",
            -5      => "Could not open output and/or baseline",
        );


        if ( $baselinetest ) {
            if ( $baselinetest < 0 ) {
                $Experiments{$cbname}{paropt}{$cbpar}{status} = "error";
                $Experiments{$cbname}{paropt}{$cbpar}{compare} = $compare_problem{$baselinetest};
            } elsif ( $baselinetest > 0 ) {
                $Experiments{$cbname}{paropt}{$cbpar}{compare} = $compare_problem{$baselinetest};
            }
        } elsif ( $missvars ) {
            $Experiments{$cbname}{paropt}{$cbpar}{compare} = "ok, vars missing";
        } else {
            $Experiments{$cbname}{paropt}{$cbpar}{compare} = "ok";
        }
    }

}



