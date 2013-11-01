#!/usr/bin/perl -w

use File::Copy;
use File::Path;
use File::Compare;
use strict;

#wrfvar_output.Linux.afwa_t7_ssmi.dmpar.gfortran
my $envcompiler;
my $fc;

$fc = $ENV{'FC'};

if (!$fc) {
    $fc = $ENV{'LMOD_FAMILY_COMPILER'};
}

print "Fortran compiler=$fc\n";

my %convert_compiler = (
    gfortran    => "gfortran",
    gnu         => "gfortran",
    pgf90       => "pgi",
    pgi         => "pgi",
    intel       => "ifort",
    ifort       => "ifort",
);

$envcompiler .= $convert_compiler{$fc};

print "Fortran compiler=$envcompiler\n";

#switch ($fc) {
#     case "gfortran" { $envcompiler = "gfortran" }
#     case "pgf90" { $envcompiler = "pgi" }
#     case "ifort" { $envcompiler = "ifort" }
#     else {die "Compiler not recognized! Check your 'FC' environment variable." }
#}

while (<DATA>) {
     last if ( /^###/ );
     my $filename = $_ or die "YOU FUCKED UP READING <DATA>:$!";
##     print "filename= $filename\n";
##     my @values = split(/\./, $filename) or die;
##     print "[$_]\n" for @values or die;
     my ($output, $arch, $exp, $paropt, $compiler) = split /\.|\n/,$filename or die;

     next if ($compiler ne $envcompiler);

     chomp($filename);
     
##     $filename = join($output, ".", $arch, ".", $exp, ".", $paropt, ".", $compiler) or die;

##     print "output= $output\n";
##     print "arch= $arch\n";
##     print "exp= $exp\n";
##     print "paropt= $paropt\n";
##     print "compiler= $compiler\n";
##     print "$exp/$filename";

##     my $comparing = compare("BASELINE.NEW/$filename","$exp/$filename") or die "YOU FUCKED UP THE COMPARE:$!";

     if (compare("BASELINE.NEW/$filename","$exp/$filename") == 0 ) {
         print "$filename = exact\n";
         } elsif (compare("BASELINE.NEW/$filename","$exp/$filename") == 1 ) {
         print "$filename = DIFF\n";
         } else {
         print "$filename = ERROR!!!\n";
     }

}


__DATA__
wrfvar_output.Linux.afwa_t7_ssmi.dmpar.gfortran
wrfvar_output.Linux.afwa_t7_ssmi.dmpar.ifort
wrfvar_output.Linux.afwa_t7_ssmi.dmpar.pgi
wrfvar_output.Linux.afwa_t7_ssmi.serial.gfortran
wrfvar_output.Linux.afwa_t7_ssmi.serial.ifort
wrfvar_output.Linux.afwa_t7_ssmi.serial.pgi
wrfvar_output.Linux.ASR_prepbufr.dmpar.gfortran
wrfvar_output.Linux.ASR_prepbufr.dmpar.ifort
wrfvar_output.Linux.ASR_prepbufr.dmpar.pgi
wrfvar_output.Linux.ASR_prepbufr.serial.gfortran
wrfvar_output.Linux.ASR_prepbufr.serial.ifort
wrfvar_output.Linux.ASR_prepbufr.serial.pgi
wrfvar_output.Linux.cv3_guo.dmpar.gfortran
wrfvar_output.Linux.cv3_guo.dmpar.ifort
wrfvar_output.Linux.cv3_guo.dmpar.pgi
wrfvar_output.Linux.cv3_guo.serial.gfortran
wrfvar_output.Linux.cv3_guo.serial.ifort
wrfvar_output.Linux.cv3_guo.serial.pgi
wrfvar_output.Linux.cwb_ascii.dmpar.gfortran
wrfvar_output.Linux.cwb_ascii.dmpar.ifort
wrfvar_output.Linux.cwb_ascii.dmpar.pgi
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.dmpar.gfortran
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.dmpar.ifort
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.dmpar.pgi
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.serial.gfortran
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.serial.ifort
wrfvar_output.Linux.cwb_ascii_outerloop_rizvi.serial.pgi
wrfvar_output.Linux.cwb_ascii.serial.gfortran
wrfvar_output.Linux.cwb_ascii.serial.ifort
wrfvar_output.Linux.cwb_ascii.serial.pgi
wrfvar_output.Linux.outerloop_bench_guo.dmpar.gfortran
wrfvar_output.Linux.outerloop_bench_guo.dmpar.ifort
wrfvar_output.Linux.outerloop_bench_guo.dmpar.pgi
wrfvar_output.Linux.outerloop_bench_guo.serial.gfortran
wrfvar_output.Linux.outerloop_bench_guo.serial.ifort
wrfvar_output.Linux.outerloop_bench_guo.serial.pgi
wrfvar_output.Linux.outerloop_ztd_bench_guo.dmpar.gfortran
wrfvar_output.Linux.outerloop_ztd_bench_guo.dmpar.ifort
wrfvar_output.Linux.outerloop_ztd_bench_guo.dmpar.pgi
wrfvar_output.Linux.outerloop_ztd_bench_guo.serial.gfortran
wrfvar_output.Linux.outerloop_ztd_bench_guo.serial.ifort
wrfvar_output.Linux.outerloop_ztd_bench_guo.serial.pgi
wrfvar_output.Linux.radar_meixu.dmpar.gfortran
wrfvar_output.Linux.radar_meixu.dmpar.ifort
wrfvar_output.Linux.radar_meixu.dmpar.pgi
wrfvar_output.Linux.radar_meixu.serial.gfortran
wrfvar_output.Linux.radar_meixu.serial.ifort
wrfvar_output.Linux.radar_meixu.serial.pgi
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.dmpar.gfortran
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.dmpar.ifort
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.dmpar.pgi
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.serial.gfortran
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.serial.ifort
wrfvar_output.Linux.sfc_assi_2_outerloop_guo.serial.pgi
wrfvar_output.Linux.t44_liuz.dmpar.gfortran
wrfvar_output.Linux.t44_liuz.dmpar.ifort
wrfvar_output.Linux.t44_liuz.dmpar.pgi
wrfvar_output.Linux.t44_liuz.serial.gfortran
wrfvar_output.Linux.t44_liuz.serial.ifort
wrfvar_output.Linux.t44_liuz.serial.pgi
wrfvar_output.Linux.t44_prepbufr.dmpar.gfortran
wrfvar_output.Linux.t44_prepbufr.dmpar.ifort
wrfvar_output.Linux.t44_prepbufr.dmpar.pgi
wrfvar_output.Linux.t44_prepbufr.serial.gfortran
wrfvar_output.Linux.t44_prepbufr.serial.ifort
wrfvar_output.Linux.t44_prepbufr.serial.pgi
wrfvar_output.Linux.tutorial_xinzhang.dmpar.gfortran
wrfvar_output.Linux.tutorial_xinzhang.dmpar.pgi
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.dmpar.gfortran
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.dmpar.ifort
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.dmpar.pgi
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.serial.gfortran
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.serial.ifort
wrfvar_output.Linux.tutorial_xinzhang_kmatrix.serial.pgi
wrfvar_output.Linux.tutorial_xinzhang_rttov.dmpar.gfortran
wrfvar_output.Linux.tutorial_xinzhang_rttov.dmpar.ifort
wrfvar_output.Linux.tutorial_xinzhang_rttov.dmpar.pgi
wrfvar_output.Linux.tutorial_xinzhang_rttov.serial.gfortran
wrfvar_output.Linux.tutorial_xinzhang_rttov.serial.ifort
wrfvar_output.Linux.tutorial_xinzhang_rttov.serial.pgi
wrfvar_output.Linux.tutorial_xinzhang.serial.gfortran
wrfvar_output.Linux.tutorial_xinzhang.serial.pgi
###

