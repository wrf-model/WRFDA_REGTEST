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
my $RTTOV_dir;
my @valid_options = ("compiler","source","revision","upload","exec","debug","j","testfile","cloudcv");

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
            "testfile:s" => \$Testfile,
            "cloudcv:s" => \$CLOUDCV_defined ) or &print_help_and_die;

unless ( defined $Compiler_defined ) {
  print "\nA compiler must be specified!\n\nAbortin!\n\n";
  &print_help_and_die;
}


sub print_help_and_die {
  print "\nUsage : regtest.pl --compiler=COMPILER --source=SOURCE_CODE.tar --revision=NNNN --upload=[no]/yes
                              --exec=[no]/yes --debug=[no]/yes/super --j=NUM_PROCS --testfile=testdata.txt\n\n";
  print "        compiler: Compiler name (supported options: ifort, gfortran, xlf, pgi, g95)\n";
  print "        source:   Specify location of source code .tar file (use 'SVN' to retrieve from repository\n";
  print "        revision: Specify code revision to retrieve (only works when '--source=SVN' specified\n";
  print "        upload:   Uploads summary to web (default is 'yes' iff source=SVN and revision=HEAD)\n";
  print "        exec:     Execute only; skips compile, utilizes existing executables\n";
  print "        debug:    'yes' compiles with minimal optimization; 'super' compiles with debugging options as well\n";
  print "        j:        Number of processors to use in parallel compile (default 4, use 1 for serial compilation)\n";
  print "        testfile: Name of test data file (default: testdata.txt)\n";
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
#                                                           status => "running"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 0 #sum of subjob walltimes
#                                                           result => "ok"
#                                                           job => {
#                                                                    3DVAR => {
#                                                                              jobid => 89123
#                                                                              status => "running"
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
         ($Arch, $Machine, $Name, $Source, $Compiler, $Project, $Queue, $Database, $Baseline) = 
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
                    foreach (@tasks) {
                        $Par = join('|',$Par,$_) unless ($Par =~ /$_/);
                    }
                }
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
my $Upload;
if ( ($Debug == 0) && ($Exec == 0) && ($Source eq "SVN") && ($Revision eq "HEAD") && !(defined $Upload_defined) ) {
    $Upload="yes";
    print "\nSource is head of repository: will upload summary to web when test is complete.\n\n";
} elsif ( !(defined $Upload_defined) ) {
    $Upload="no";
} else {
    $Upload=$Upload_defined;
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
printf "#INDEX   EXPERIMENT                   TYPE             CPU_MPI  CPU_OPENMP    PAROPT\n";
printf "%-4d     %-27s  %-16s   %-8d   %-10d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n", 
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
   print "Option exec=yes specified; checking previously built code for revision number\n";
   if ( ($Type =~ /4DVAR/i) && ($Type =~ /3DVAR/i) ) {
      print "Ensuring that all compiled code is the same version\n";
      if ( ($Par =~ /dmpar/i) && ($Par_4dvar =~ /dmpar/i) ) {
         my $Revision3 = &svn_version("WRFDA_3DVAR_dmpar");
         my $Revision4 = &svn_version("WRFDA_4DVAR_dmpar");
         die "Check your existing code: WRFDA_3DVAR_dmpar and WRFDA_4DVAR_dmpar do not appear to be built from the same version of code!" unless ($Revision3 eq $Revision4);
         $Revision = &svn_version("WRFDA_3DVAR_dmpar");
      }
   } elsif ($Type =~ /4DVAR/i) {
      $Revision = &svn_version("WRFDA_4DVAR_dmpar");
   } else {
      if ( $Par =~ /dmpar/i ) {
         $Revision = &svn_version("WRFDA_3DVAR_dmpar");
      } else {
         $Revision = &svn_version("WRFDA_3DVAR_serial");
      }
   }
   chomp($Revision);
   goto "SKIP_COMPILE";
}

# Set necessary environment variables for compilation

$ENV{J}="-j $Parallel_compile_num";

if (defined $CLOUDCV_defined && $CLOUDCV_defined ne 'no') {
   $ENV{CLOUD_CV}='1';
   print "\nWill compile for CLOUD_CV option\n\n";
#   die "CLOUD_CV option is not fully implemented yet. Exiting...";
}

$ENV{CRTM}='1'; #These are not necessary since V3.6, but will not hurt
$ENV{BUFR}='1';

  if ($Arch eq "Linux") {
      if ($Machine_name eq "yellowstone") { # Yellowstone
          $RTTOV_dir = "/glade/u/home/$ThisGuy/libs/rttov_$Compiler\_$Compiler_version";
          if (-d $RTTOV_dir) {
              $ENV{RTTOV} = $RTTOV_dir;
              print "Using RTTOV libraries in $RTTOV_dir\n";
          } else {
              print "$RTTOV_dir DOES NOT EXIST\n";
              print "RTTOV Libraries have not been compiled with $Compiler version $Compiler_version\nRTTOV tests will fail!\n";
          }

      } else { # Loblolly
          $RTTOV_dir = "/loblolly/kavulich/libs/rttov/$Compiler";
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
  } elsif ($Arch eq "Darwin") {   # Darwin
      $RTTOV_dir = "/sysdisk1/$ThisGuy/libs/rttov_$Compiler";
      if (-d $RTTOV_dir) {
          $ENV{RTTOV} = $RTTOV_dir;
          print "Using RTTOV libraries in $RTTOV_dir\n";
      } else {
          print "$RTTOV_dir DOES NOT EXIST\n";
          print "RTTOV Libraries have not been compiled with $Compiler\nRTTOV tests will fail!\n";
      }
  }

#For cycle jobs, WRF must exist. Will add capability to compile WRF in the near future
  if ($Type =~ /CYCLING/i) {
      if (-d "$MainDir/WRFV3_$Compiler") {
          print "Will use WRF code in $MainDir/WRFV3_$Compiler for CYCLING test\n";
      } else {
          print "\n$MainDir/WRFV3_$Compiler DOES NOT EXIST\n";
          print "\nCYCLING TEST WILL FAIL!!\n";
      }

  }



#######################  BEGIN COMPILE 4DVAR  ########################

if ($Type =~ /4DVAR/i) {
  # Set WRFPLUS_DIR Environment variable
    my $WRFPLUSDIR = $MainDir."/WRFPLUSV3_$Compiler";
    chomp($WRFPLUSDIR);
    print "4DVAR tests specified: checking for WRFPLUS code in directory $WRFPLUSDIR.\n";
    if (-d $WRFPLUSDIR) {
        $ENV{WRFPLUS_DIR} = $WRFPLUSDIR;
        print "Checking WRFPLUS revision ...\n";
        $WRFPLUS_Revision = &svn_version("$WRFPLUSDIR");
    } else {
        print "\n$WRFPLUSDIR DOES NOT EXIST\n";
        print "\nNOT COMPILING FOR 4DVAR!\n";
        $Type =~ s/4DVAR//gi;

        foreach my $name (keys %Experiments) {
            foreach my $type ($Experiments{$name}{test_type}) {
                if ($type =~ /4DVAR/i) {
                   delete $Experiments{$name};
                   print "\nDeleting 4DVAR experiment $name from test list.\n";
                   next ;
                }
            }
        }
    }
}


if ($Type =~ /4DVAR/i) {

   foreach (split /\|/, $Par_4dvar) { #foreach1
      my $par_type = $_;



      # Get WRFDA code

      if ( -e "WRFDA_4DVAR_$par_type" && -r "WRFDA_4DVAR_$par_type" ) {
         printf "Deleting the old WRFDA_4DVAR_$par_type directory ... \n";
         #Delete in background to save time rather than using "rmtree"
         ! system("mv", "WRFDA_4DVAR_$par_type", ".WRFDA_4DVAR_$par_type") or die "Can not move 'WRFDA_4DVAR_$par_type' to '.WRFDA_4DVAR_$par_type for deletion': $!\n";
         ! system("rm -rf .WRFDA_4DVAR_$par_type &") or die "Can not remove WRFDA_4DVAR_$par_type: $!\n";
      }

      if ($Source eq "SVN") {
         print "Getting the code from repository $SVN_REP to WRFDA_4DVAR_$par_type ...\n";
         ! system ("svn","co","-q","-r",$Revision,$SVN_REP,"WRFDA_4DVAR_$par_type") or die " Can't run svn checkout: $!\n";
         if ($Revision eq 'HEAD') {
            $Revision = &svn_version("WRFDA_4DVAR_$par_type");
         }
         printf "Revision %5d successfully checked out to WRFDA_4DVAR_$par_type.\n",$Revision;
      } else {
         print "Getting the code from $Source to WRFDA_4DVAR_$par_type ...\n";
         ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
         ! system("mv", "WRFDA", "WRFDA_4DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_4DVAR_$par_type': $!\n";
         $Revision = &svn_version("WRFDA_4DVAR_$par_type");
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

         if (($config_line=~ m/(\d+)\.\s\($par_type\) .* $CCompiler\/$Compiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) ) {
            $Compile_options_4dvar{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif (($config_line=~ m/(\d+)\.\s\($par_type\) .* $Compiler .* $CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) ) {
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

            my @exefiles = glob ("var/build/*.exe");

            if (@exefiles < 42) {
               print "The number of exe files is less than 42. \n";
               exit 2;
            }

            foreach ( @exefiles ) {
               warn "The exe file $_ has problem. \n" unless -s ;
            }

            # Rename the executables:
            if (! rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options_4dvar{$option}") {
               print "Program da_wrfvar.exe not created for 4DVAR, $par_type: check your compilation log.\n";
               exit 3;
            }

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

       if ($Source eq "SVN") {
          print "Getting the code from repository $SVN_REP to WRFDA_3DVAR_$par_type ...\n";
          ! system ("svn","co","-q","-r",$Revision,$SVN_REP,"WRFDA_3DVAR_$par_type") or die " Can't run svn checkout: $!\n";
          if ($Revision eq 'HEAD') {
             $Revision = &svn_version("WRFDA_3DVAR_$par_type");
          }
          printf "Revision %5d successfully checked out to WRFDA_3DVAR_$par_type.\n",$Revision;
       } else {
          print "Getting the code from $Source to WRFDA_3DVAR_$par_type ...\n";
          ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n";
          ! system("mv", "WRFDA", "WRFDA_3DVAR_$par_type") or die "Can not move 'WRFDA' to 'WRFDA_3DVAR_$par_type': $!\n";
          $Revision = &svn_version("WRFDA_3DVAR_$par_type");
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


#       # Add a slash before + in $Par !!! Needed if we support dm+sm in the future !!!
#       $Par =~ s/\+/\\+/g;

       my $option;

      $count = 0;
      foreach (@output) {
         my $config_line = $_ ;
         if (($config_line=~ m/(\d+)\.\s\($par_type\) .* $CCompiler\/$Compiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i) ) {
            $Compile_options{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif ( ($config_line=~ m/(\d+)\.\s\($par_type\) .* $Compiler .* $CCompiler .*/ix) &&
             ! ($config_line=~/Cray/i) &&
             ! ($config_line=~/PGI accelerator/i) &&
             ! ($config_line=~/-f90/i) &&
             ! ($config_line=~/POE/) &&
             ! ($config_line=~/Xeon/) &&
             ! ($config_line=~/SGI MPT/i)  ) {
            $Compile_options{$1} = $par_type;
            $option = $1;
            $count++;
         } elsif ( ($config_line=~ m/(\d+)\. .* $Compiler .* $CCompiler .* ($par_type) .*/ix) &&
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

               my @exefiles = glob ("var/build/*.exe");

               if (@exefiles < 42) {
                  print "The number of exe files is less than 42. \n";
                  exit 2;
               }

               foreach ( @exefiles ) {
                  warn "The exe file $_ has problem. \n" unless -s ;
               }
     
               # Rename the executables:
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

      rename "WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe","WRFDA_$compile_job_array{$jobnum}/var/build/da_wrfvar.exe.$Compiler.$details[1]" or die "Program da_wrfvar.exe not created for $details[0], $details[1]: check your compilation log.\n";

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
         symlink "$_", basename($_)
             or warn "Cannot symlink $_ to local directory: $!\n";
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

print "Checkpoint 1\n\n";
print Dumper($Experiments{radar_4dvar_cv7});
print "\n\n";

# preset the the status of all jobs and subjobs (types)

 foreach my $name (keys %Experiments) {
    $Experiments{$name}{status} = "pending";
    foreach my $par (keys %{$Experiments{$name}{paropt}}) {
       $Experiments{$name}{paropt}{$par}{status} = "pending";
       $Experiments{$name}{paropt}{$par}{result} = "--";
       $Experiments{$name}{paropt}{$par}{walltime} = 0;
       $Experiments{$name}{paropt}{$par}{todo} = $Experiments{$name}{test_type};
       $Experiments{$name}{paropt}{$par}{started} = 0;
       my @jobtypes = split /\|/, $Experiments{$name}{test_type};
          my %job_records;
          $job_records{$_} = {} for @jobtypes;
##                my %record = (
##                     index => $1,
##                     test_type => $3,
##                     cpu_mpi => $4,
##                     cpu_openmp => $5,
##                     status => "open",
##                     paropt => \%task_records
##                );
          $Experiments{$name}{paropt}{$par}{job} = \%job_records;
          foreach my $job (keys %{$Experiments{$name}{paropt}{$par}{job}}) {
             $Experiments{$name}{paropt}{$par}{job}{$job}{status} = "pending";
             $Experiments{$name}{paropt}{$par}{job}{$job}{walltime} = 0;
             $Experiments{$name}{paropt}{$par}{job}{$job}{jobid} = 0;
       }
    } 
 } 

print "Checkpoint 2\n\n";
print Dumper($Experiments{radar_4dvar_cv7});
print "\n\n";

# Initial Status:

 &flush_status ();

# submit job:

 if ( ($Machine_name eq "yellowstone") ) {
    &submit_job_ys ;
    chdir "$MainDir";
 } else {
    &submit_job ;
 }

print "Final structure check:\n\n";
print Dumper(%Experiments);
print "\n\n";

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
    print WEBH '<li>'."Revision : $Revision".'</li>'."\n";
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
    print WEBH '<th>TYPE</th>'."\n";
    print WEBH '<th>PAROPT</th>'."\n";
    print WEBH '<th>CPU_MPI</th>'."\n";
    print WEBH '<th>CPU_OMP</th>'."\n";
    print WEBH '<th>STATUS</th>'."\n";
    print WEBH '<th>WALLTIME(S)</th>'."\n";
    print WEBH '<th>RESULT</th>'."\n";
    print WEBH '</tr>'."\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            print WEBH '<tr>'."\n";
            print WEBH '<tr';
            if ($Experiments{$name}{paropt}{$par}{status} eq "error") {
                print WEBH ' style="background-color:red;color:white">'."\n";
            } elsif ($Experiments{$name}{paropt}{$par}{result} eq "diff") {
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
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{result}.'</td>'."\n";
            print WEBH '</tr>'."\n";
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

       if ( $numexp < 26 ) {
          $scp_warn ++;
          print "This run only includes $numexp of 26 tests, are you sure you want to upload?\a\n";

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
       unless ( $Source eq "SVN" ) {
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

    push @mes, "Experiment                  Paropt      Job type        CPU_MPI  Status    Walltime (s)   Result\n";
    push @mes, "=================================================================================================\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            push @mes, sprintf "%-28s%-12s%-16s%-9d%-10s%-15d%-7s\n", 
                    $name, $par, $Experiments{$name}{test_type},
                    $Experiments{$name}{cpu_mpi},
                    $Experiments{$name}{paropt}{$par}{status},
                    $Experiments{$name}{paropt}{$par}{walltime},
                    $Experiments{$name}{paropt}{$par}{result};
        }
    }

    push @mes, "=================================================================================================\n";
    return @mes;
}

sub new_job {
     
     my ($nam, $com, $par, $cpun, $cpum, $types) = @_;

     # Enter into the experiment working directory:

     chdir "$nam" or die "Cannot chdir to $nam : $!\n";

     if ($types =~ /OBSPROC/i) {
         $types =~ s/OBSPROC//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         print "Running OBSPROC for $par job '$nam'\n";

         $cmd="$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe 1>obsproc.out  2>obsproc.out";
         ! system($cmd) or die "Execution of obsproc failed: $!";

         @gtsfiles = glob ("obs_gts_*.3DVAR");
         if (defined $gtsfiles[0]) {
             copy("$gtsfiles[0]","ob.ascii") or die "YOU HAVE COMMITTED AN OFFENSE! $!";
             printf "OBSPROC complete\n";
         } else {
             chdir "..";
             return "OBSPROC_FAIL";
         }
     }


     if ($types =~ /GENBE/i) {
         $types =~ s/GENBE//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         if (-e "be.dat") {
            print "'be.dat' already exists, skipping GEN_BE step\n";
         } else {

            print "Running GEN_BE for $par job '$nam'\n";

            # Unpack forecasts tar file.
            ! system("tar -xf forecasts.tar")or die "Can't untar forecasts file: $!\n";

            # We need the script to see where the WRFDA directory is. See gen_be_wrapper.ksh in test directory
            $ENV{REGTEST_WRFDA_DIR}="$MainDir/WRFDA_3DVAR_$par";

            $cmd="./gen_be_wrapper.ksh 1>gen_be.out  2>gen_be.out";
            system($cmd);

            if (-e "gen_be_run/SUCCESS") {
               copy("gen_be_run/be.dat","be.dat") or die "Cannot copy be.dat: $!";
            } else {
               chdir "..";
               return "GENBE_FAIL";
            }

         }
     }

     if ($types =~ /3DVAR/i) {
         if ($types =~ /VARBC/i) {
             $types =~ s/VARBC//i;
             $Experiments{$nam}{paropt}{$par}{todo} = $types;

             # Submit the first job for VARBC:

             print "Starting VARBC 3DVAR $par job '$nam'\n";

             if ($par=~/dm/i) {
                 $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
                 system($cmd);
             } else {
                 $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
                 system($cmd);
             }

             mkpath('varbc_run_1') or die "Mkdir failed: $!";
             unless ( -e "wrfvar_output") {
                 chdir "..";
                 return "VARBC_FAIL";
             }
             system('mv statistics rsl* wrfvar_output varbc_run_1/');
             unlink 'VARBC.in';
             move('VARBC.out','VARBC.in') or die "Move failed: $!";
         }

         $types =~ s/3DVAR//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         # Submit the 3DVAR job:

         print "Starting 3DVAR $par job '$nam'\n";

         if ($par=~/dm/i) { 
             $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler"; 
             system($cmd);
         }
    
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );
    
         # Back to the upper directory:

         chdir ".." or die "Cannot chdir to .. : $!\n";
    
         return 1;

     } elsif ($types =~ /FGAT/i) {
         $types =~ s/FGAT//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;


         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun ../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="../WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
             system($cmd);
         }
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         # Back to the upper directory:
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return 1;

     } elsif ($types =~ /4DVAR/i) {
         $types =~ s/4DVAR//i;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;
         print "Starting 4DVAR $par job '$nam'\n";


         if ($par=~/dm/i) {
             $cmd= "mpirun -np $cpun ../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>/dev/null 2>/dev/null";
             system($cmd);
         } else {
             $cmd="../WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par 1>print.out.$Arch.$nam.$par.$Compiler 2>print.out.$Arch.$nam.$par.$Compiler";
             system($cmd);
         }
         rename "statistics", "statistics.$Arch.$nam.$par.$Compiler" if ( -e "statistics" );

         # Back to the upper directory:
         chdir ".." or die "Cannot chdir to .. : $!\n";

         return 1;

     }
}

sub create_ys_job_script {

    my ($jobname, $jobtype, $jobpar, $jobcompiler, $jobcores, $jobqueue, $jobproj, @stufftodo) = @_;


    printf "Creating $jobtype job: $jobname, $jobpar\n";

    # Generate the LSF job script
    unlink "job_${jobname}_${jobtype}_${jobpar}.csh" if -e "job_${jobname}_${jobtype}_${jobpar}.csh";
    open FH, ">job_${jobname}_${jobtype}_${jobpar}.csh" or die "Can not open job_${jobname}_${jobtype}_${jobpar}.csh to write. $! \n";

    print FH '#!/bin/csh'."\n";
    print FH '#',"\n";
    print FH '# LSF batch script'."\n";
    print FH "# Automatically generated by $0\n";
    print FH "#BSUB -J $jobname"."\n";
    # If more than 16 cores, can't use caldera
    print FH "#BSUB -q ".(($jobqueue eq 'caldera' && $jobcores > 16) ? "regular" : $jobqueue)."\n";
    printf FH "#BSUB -n %-3d"."\n",($jobpar eq 'dmpar' || $jobpar eq 'dm+sm') ? $jobcores: 1;
    print FH "#BSUB -o job_${jobname}_${jobtype}_${jobpar}.output"."\n";
    print FH "#BSUB -e job_${jobname}_${jobtype}_${jobpar}.error"."\n";
    print FH "#BSUB -W 30"."\n";
    print FH "#BSUB -P $jobproj"."\n";
    # If job serial or smpar, span[ptile=1]; if job dmpar, span[ptile=16] or span[ptile=$cpun], whichever is less
    printf FH "#BSUB -R span[ptile=%d]"."\n", ($jobpar eq 'serial' || $jobpar eq 'smpar') ? 1 : (($jobcores < 16 ) ? $jobcores : 16);
    print FH "\n"; #End of BSUB commands; add newline for readability

    # Comment this out for now; this line will be needed if smpar functionality is ever added (also will need new variable passed, cpum)
    #print FH ( $par eq 'smpar' || $par eq 'dm+sm') ? "setenv OMP_NUM_THREADS $cpum\n" :"\n";

    # Include this line to avoid caldera problems. CISL-recommended kludge *sigh*
    print FH "unsetenv MP_PE_AFFINITY\n";

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
     # Enter into the experiment working directory:
     

     if ($types =~ /GENBE/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "GENBE";
         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         if (-e "be.dat") {
            print "'be.dat' already exists, skipping GEN_BE step\n";
            chdir "..";
            return "SKIPPED";
         } else {

            #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
            my @genbe_commands;
            $genbe_commands[0] = "tar -xf forecasts.tar\n";
            # We need the script to see where the WRFDA directory is. See 'gen_be_wrapper.ksh' in test directory
            if ($types =~ /4DVAR/i) {
               $genbe_commands[1] = "setenv REGTEST_WRFDA_DIR ".$MainDir."/WRFDA_4DVAR_".$par."\n";
            } else {
               $genbe_commands[1] = "setenv REGTEST_WRFDA_DIR ".$MainDir."/WRFDA_3DVAR_".$par."\n";
            }
            $genbe_commands[2] = "./gen_be_wrapper.ksh > gen_be.out\n";
            $genbe_commands[3] = "if( -e gen_be_run/SUCCESS ) then\n";
            $genbe_commands[4] = "   cp gen_be_run/be.dat ./be.dat\n";
            $genbe_commands[5] = "endif\n";

            &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, 1,
                                    $Queue, $Project, @genbe_commands );

            # Submit the job
            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

     } elsif ($types =~ /OBSPROC/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "OBSPROC";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         if (-e "ob.ascii") {
            print "'ob.ascii' already exists, skipping OBSPROC step\n";
            chdir "..";
            return "SKIPPED";
         } else {
            #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
            my @obsproc_commands;
            $obsproc_commands[0] = "$MainDir/WRFDA_3DVAR_$par/var/obsproc/src/obsproc.exe\n";
            $obsproc_commands[1] = "cp -f obs_gts_*.3DVAR ob.ascii\n";

            &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, 1,
                                    $Queue, $Project, @obsproc_commands );

            # Submit the job

            $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;
         }

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

     } elsif ($types =~ /VARBC/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "VARBC";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @varbc_commands;
         $varbc_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";
         $varbc_commands[1] = "mkdir varbc_run_1\n";
         $varbc_commands[2] = "mv rsl* varbc_run_1\n";
         $varbc_commands[3] = "rm -f VARBC.in\n";
         $varbc_commands[4] = "mv VARBC.out VARBC.in\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @varbc_commands );

         # Submit the job

         $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;

         # Return to the upper directory

         chdir ".." or die "Cannot chdir to .. : $!\n";

     } elsif ($types =~ /FGAT/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "FGAT";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";


         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @fgat_commands;
         $fgat_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @fgat_commands );

         # Submit the job
         $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";



     } elsif ($types =~ /3DVAR/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "3DVAR";

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         #If an OBSPROC job, make sure it created the observation file!
         if ($Experiments{$nam}{test_type} =~ /OBSPROC/i) {
             printf "Checking OBSPROC output\n";
             unless (-e "ob.ascii") {
                 chdir "..";
                 return "OBSPROC_FAIL";
             }
         }

         #If a GENBE job, make sure GEN_BE completed successfully
         if ($Experiments{$nam}{test_type} =~ /GENBE/i) {
             printf "Checking GENBE output\n";
             unless (-e "be.dat") {
                 chdir "..";
                 return "GENBE_FAIL";
             }
         }

         #NEW FUNCTION FOR CREATING JOB SUBMISSION SCRIPTS: Put all commands for job script in an array
         my @_3dvar_commands;
         $_3dvar_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @_3dvar_commands );

         # Submit the job

         $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;

         chdir ".." or die "Cannot chdir to .. : $!\n";

     } elsif ($types =~ /CYCLING/i) {

         # Cycling jobs need some extra variables. You'll see why if you read on
         my $job_feedback;
         my @jobids;

         chdir "$nam" or die "Cannot chdir to $nam : $!\n";

         # For cycling jobs, after first 3DVAR run, we run UPDATEBC for lateral BC, then WRF,
         # then UPDATEBC for lower BC, then 3DVAR again at next time.
         # The output of the NEXT 3DVAR run is the one that will be checked against the baseline.
         $types =~ s/CYCLING//i;
         $types =~ s/^\|//;
         $types =~ s/\|$//;
         $Experiments{$nam}{paropt}{$par}{todo} = $types;

         delete $Experiments{$nam}{paropt}{$par}{job}{CYCLING};    #some more fancy finagling: we're gonna need to expand 'CYCLING'
                                                                   #into its individual jobs, to keep track of each
         $Experiments{$nam}{paropt}{$par}{currjob} = "WRFDA_init"; #"WRFDA_init" is the first job, so it's the one we'll set as "currjob"

         # Cycling experiments are set up so that the first two steps are run in their own directories: WRFDA_init and WRF
         # The data for each of these is contained in a tar file (cycle_data.tar) to avoid overwriting original data

         my $tarstatus = system("tar", "xf", "cycle_data.tar");
         unless ($tarstatus == 0) {
            print "Problem opening cycle_data.tar; $!\nTest probably not set up correctly\n";
            return undef;
         }

         # First: run initial 3DVAR job

         chdir "WRFDA_init" or warn "Cannot chdir to 'WRFDA_init': $!\n";

         $Experiments{$nam}{paropt}{$par}{job}{WRFDA_init}{walltime} = 0;
         my @_3dvar_init_commands;
         $_3dvar_init_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         &create_ys_job_script ( $nam, "WRFDA_init", $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @_3dvar_init_commands );

         # Submit initial 3DVAR job
         $job_feedback = ` bsub < job_${nam}_WRFDA_init_${par}.csh 2>/dev/null `;


         # We're gonna use some fancy Yellowstone finagling to submit all our jobs in sequence without the parent script 
         # having to wait. To do this, we need to keep track of job numbers (hashes are unordered so we can't rely on %Experiments)
         if ($job_feedback =~ m/.*<(\d+)>/) {
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_init}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_init}{walltime} = 0;
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_init}{status} = "pending";
            $jobids[0] = $1;
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRFDA_init job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            return undef;
         }

         # Second: run da_update_bc.exe to update lateral boundary conditions before WRF run. This is done in the WRFDA_init directory

         my @lat_bc_commands;
         $lat_bc_commands[0] = "cp wrfbdy_d01.orig wrfbdy_d01\n";
         $lat_bc_commands[1] = "$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe\n";
         $lat_bc_commands[2] = "cp wrfbdy_d01 ../WRF/\n";
         $lat_bc_commands[3] = "cp wrfvar_output ../WRF/wrfinput_d01\n";

         &create_ys_job_script ( $nam, "UPDATE_BC_LAT", $par, $com, 1,
                                 'caldera', $Project, @lat_bc_commands );
         
         # Here's the finagling I was talking about. Since these jobs all require input from the previous job,
         # We can use -w "ended($jobid)" to wait for job $jobid to finish
         $job_feedback = ` bsub -w "ended($jobids[0])" < job_${nam}_UPDATE_BC_LAT_${par}.csh 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $jobids[1] = $1;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LAT}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LAT}{walltime} = 0;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LAT}{status} = "pending";
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit UPDATE_BC_LAT job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            return undef;
         }

         # Third: Use our updated wrfinput and wrfbdy to run a forecast
         chdir "../WRF" or warn "Cannot chdir to '../WRF': $!\n";
         my @wrf_commands;
         $wrf_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFV3_$com/main/wrf.exe\n" :
             "mpirun.lsf $MainDir/WRFV3_$com/main/wrf.exe\n";

         &create_ys_job_script ( $nam, "WRF", $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @wrf_commands );

         $job_feedback = ` bsub -w "ended($jobids[1])" < job_${nam}_WRF_${par}.csh 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $jobids[2] = $1;
            $Experiments{$nam}{paropt}{$par}{job}{WRF}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{WRF}{walltime} = 0;
            $Experiments{$nam}{paropt}{$par}{job}{WRF}{status} = "pending";
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRF job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            return undef;
         }

         # Fourth: run da_update_bc.exe to update lower boundary conditions before 2nd WRFDA run
         chdir ".." or warn "Cannot chdir to '..': $!\n";

         # Because of limitations in how csh can link files, we need to create a perl script to be called to link the wrfout as fg
         open FH, ">link_new_fg.pl" or die "Can not open link_new_fg.pl to write. $! \n";
         print FH '#!/usr/bin/perl -w'."\n";
         print FH "use strict;";
         print FH 'my @wrfout = glob("wrfout*");'."\n";
         print FH 'symlink ($wrfout[-1],"fg");'."\n";
         close FH;

         chmod(0755,"link_new_fg.pl");

         my @low_bc_commands;
         $low_bc_commands[0] = "cp WRF/wrfout* .\n";
         $low_bc_commands[1] = "./link_new_fg.pl\n";
         $low_bc_commands[2] = "$MainDir/WRFDA_3DVAR_$par/var/build/da_update_bc.exe\n";

         &create_ys_job_script ( $nam, "UPDATE_BC_LOW", $par, $com, 1,
                                 'caldera', $Project, @low_bc_commands );

         $job_feedback = ` bsub -w "ended($jobids[2])" < job_${nam}_UPDATE_BC_LOW_${par}.csh 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $jobids[3] = $1;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LOW}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LOW}{walltime} = 0;
            $Experiments{$nam}{paropt}{$par}{job}{UPDATE_BC_LOW}{status} = "pending";
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit UPDATE_BC_LOW job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            return undef;
         }

         my @_3dvar_final_commands;
         $_3dvar_final_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_3DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         &create_ys_job_script ( $nam, "WRFDA_final", $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @_3dvar_final_commands );

         $job_feedback = ` bsub -w "ended($jobids[3])" < job_${nam}_WRFDA_final_${par}.csh 2>/dev/null `;

         if ($job_feedback =~ m/.*<(\d+)>/) {
            $jobids[4] = $1;
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_final}{jobid} = $1;
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_final}{walltime} = 0;
            $Experiments{$nam}{paropt}{$par}{job}{WRFDA_final}{status} = "pending";
         } else {
            print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\nFailed to submit WRFDA_final job for CYCLING task $nam\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n";
            return undef;
         }

         # Now we're done creating and submitting jobs; let's print some helpful info and go back to the main test

         print "Done submitting jobs for CYCLING test $nam, JOBIDs listed below:\n";
         print "WRFDA inital $jobids[0]\n";
         print "UPDATEBC lat $jobids[1]\n";
         print "WRF          $jobids[2]\n";
         print "UPDATEBC low $jobids[3]\n";
         print "WRFDA final  $jobids[4]\n";

         # Return to the upper directory
         chdir ".." or die "Cannot chdir to .. : $!\n";

         # Return last JOBID, since this governs when the script decides the job is done.
         return $jobids[4];

     } elsif ($types =~ /4DVAR/i) {
         $Experiments{$nam}{paropt}{$par}{currjob} = "4DVAR";
         chdir "$nam" or die "Cannot chdir to $nam : $!\n";
         #If an OBSPROC job, make sure it created the observation file!
         if ($Experiments{$nam}{test_type} =~ /OBSPROC/i) {
             printf "Checking OBSPROC output\n";
             unless (-e "ob01.ascii") {
                 return "OBSPROC_FAIL";
             }
         }

         my @_4dvar_commands;
         $_4dvar_commands[0] = ($par eq 'serial' || $par eq 'smpar') ?
             "$MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n" :
             "mpirun.lsf $MainDir/WRFDA_4DVAR_$par/var/build/da_wrfvar.exe.$com.$par\n";

         &create_ys_job_script ( $nam, $Experiments{$nam}{paropt}{$par}{currjob}, $par, $com, $Experiments{$nam}{cpu_mpi},
                                 $Queue, $Project, @_4dvar_commands );

         # Submit the job
         $feedback = ` bsub < job_${nam}_${Experiments{$nam}{paropt}{$par}{currjob}}_${par}.csh 2>/dev/null `;

         # Return to the upper directory

         chdir ".." or die "Cannot chdir to .. : $!\n";

     } else {
         die "You dun goofed!\n$types is not a valid test type.";
     }


     # Update the job list
     $types =~ s/$Experiments{$nam}{paropt}{$par}{currjob}//i;
     $types =~ s/^\|//;
     $types =~ s/\|$//;
     $Experiments{$nam}{paropt}{$par}{todo} = $types;

     # Pick the job id

     if ($feedback =~ m/.*<(\d+)>/) {;
         $Experiments{$nam}{paropt}{$par}{job}{$Experiments{$nam}{paropt}{$par}{currjob}}{jobid} = $1;
         return $1;
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


            #Submit job
            my $rc = &new_job ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                $Experiments{$name}{cpu_openmp},$Experiments{$name}{paropt}{$par}{todo} );

            #Set the end time for this job
            $Experiments{$name}{paropt}{$par}{endtime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{walltime}[0] =
                $Experiments{$name}{paropt}{$par}{endtime} - $Experiments{$name}{paropt}{$par}{starttime};
            if (defined $rc) { 
                if ($rc =~ /OBSPROC_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{result} = "obsproc failed";
                    &flush_status ();
                    next;
                } elsif ($rc =~ /VARBC_FAIL/) {
                    $Experiments{$name}{paropt}{$par}{status} = "error";
                    $Experiments{$name}{paropt}{$par}{result} = "Output missing";
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

            $Experiments{$name}{paropt}{$par}{status} = "done";

            # Wrap-up this job:

            rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version";

            # Compare the wrfvar_output with the BASELINE:

            unless ($Baseline =~ /none/i) {
                         &check_baseline ($name, $Arch, $Machine_name, $par, $Compiler, $Baseline, $Compiler_version);
            }
        }

    }

    &flush_status (); # refresh the status
    sleep 1;
}

sub submit_job_ys {

    while ($remain_exps > 0) {    # cycling until no more experiments remain

         #This first loop submits all parallel jobs

         foreach my $name (keys %Experiments) {

             next if ($Experiments{$name}{status} eq "done") ;  # skip this experiment if it is done.

             foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {

                 next if ( $Experiments{$name}{paropt}{$par}{status} eq "done"  ||      # go to next job if it is done already..
                           $Experiments{$name}{paropt}{$par}{status} eq "error" );

print "Investigating structure for job $name \n\n";
print Dumper($Experiments{$name});
print "\n\n";
                 unless ( defined $Experiments{$name}{paropt}{$par}{currjob} ) {      # No current job and not done; ready for submission

                     next if $Experiments{$name}{status} eq "close";      #  skip if this experiment already has a job running.
                         my $rc = &new_job_ys ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                         $Experiments{$name}{cpu_openmp},$Experiments{$name}{paropt}{$par}{todo} );

                     if (defined $rc) {
                         if ($rc =~ /OBSPROC_FAIL/) {
                             $Experiments{$name}{paropt}{$par}{status} = "error";
                             $Experiments{$name}{paropt}{$par}{result} = "obsproc failed";
                             $remain_par{$name} -- ;
                             if ($remain_par{$name} == 0) {
                                 $Experiments{$name}{status} = "done";
                                 $remain_exps -- ;
                             }
                             &flush_status ();
                             next;
                         } elsif ($rc =~ /GENBE_FAIL/) {
                             $Experiments{$name}{paropt}{$par}{status} = "error";
                             $Experiments{$name}{paropt}{$par}{result} = "gen_be failed";
                             $remain_par{$name} -- ;
                             if ($remain_par{$name} == 0) {
                                 $Experiments{$name}{status} = "done";
                                 $remain_exps -- ;
                             }
                             &flush_status ();
                             next;
                         } elsif ($rc =~ /SKIPPED/) {

                             $Experiments{$name}{paropt}{$par}{status} = "pending";    # Still more tasks for this job.
                             $Experiments{$name}{paropt}{$par}{started} = 0;
                             next;
                         } else {
                             $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{jobid} = $rc ;    # assign the current jobid.
                             $Experiments{$name}{status} = "close";
                             my $checkQ = `bjobs $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{jobid}`;
                             if ($checkQ =~ /\sregular\s/) {
                                 printf "%-10s job for %-30s was submitted to queue 'regular' with jobid: %10d \n", $par, $name, $rc;
                             } else {
                                 printf "%-10s job for %-30s was submitted to queue '$Queue' with jobid: %10d \n", $par, $name, $rc;
                             }
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

                 # Job is still in queue.

                 my $feedback = `bjobs $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{jobid}`;
                 if ( $feedback =~ m/RUN/ ) {; # Still running
                     unless ($Experiments{$name}{paropt}{$par}{started} == 1) { #set the start time when we first find it is running.
                         $Experiments{$name}{paropt}{$par}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{started} = 1;
                         &flush_status (); # refresh the status
                     }
                     next;
                 } elsif ( $feedback =~ m/PEND/ ) { # Still Pending
                     next;
                 }

                 # Job is finished.
                 my $bhist = `bhist $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{jobid}`;
                 my @jobhist = split('\s+',$bhist);  # Get runtime using bhist command, then store this job's runtime and add it to total runtime
                 $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{walltime} = $jobhist[24];
                 $Experiments{$name}{paropt}{$par}{walltime} = $Experiments{$name}{paropt}{$par}{walltime} + $jobhist[24];

                 if ($Experiments{$name}{paropt}{$par}{todo}) {
                     print "$Experiments{$name}{paropt}{$par}{todo}\n";
                     $Experiments{$name}{paropt}{$par}{status} = "pending";    # Still more tasks for this job.
                     $Experiments{$name}{paropt}{$par}{started} = 0;
                     printf "%-10s job for %-30s was completed in %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{walltime};
                     $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{status} = "done";
                     delete $Experiments{$name}{paropt}{$par}{currjob};       # Delete the current job.

#                     if () { #Before moving on, be sure the next job isn't already in the queue

#                     }


                 } else { #Nothing in $Experiments{$name}{paropt}{$par}{todo} means there's nothing left to do for this job
                     $remain_par{$name} -- ;                               # Delete the count of jobs for this experiment.
                     $Experiments{$name}{paropt}{$par}{status} = "done";    # Done this job.
                     $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{status} = "done";

                     printf "%-10s job for %-30s was completed in %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{job}{$Experiments{$name}{paropt}{$par}{currjob}}{walltime};
                     delete $Experiments{$name}{paropt}{$par}{currjob};       # Delete the jobid.

                     # Wrap-up this job:

                     rename "$name/wrfvar_output", "$name/wrfvar_output.$Arch.$Machine_name.$name.$par.$Compiler.$Compiler_version";

                     # Compare against the baseline

                     unless ($Baseline =~ /none/i) {
                         &check_baseline ($name, $Arch, $Machine_name, $par, $Compiler, $Baseline, $Compiler_version);
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


sub svn_version {

#This function is necessary since a Yellowstone upgrade bungled up the 'svnversion' function.
#Should have the same functionality for versioned directories, but will also try to retrieve
#the WRF/WRFDA release version if possible

#Also appends an "m" to the revision number if the contents are versioned and have been modified.
##I think this was part of the original behavior of "svnversion" but I can't remember for sure.

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


