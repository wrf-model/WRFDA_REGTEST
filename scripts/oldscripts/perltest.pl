#!/usr/bin/perl -w

use File::Copy;
use File::Path;
use File::Compare;

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);
#my @abbr = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
#print "$abbr[$mon] $mday \n";
$year += 1900;
$mon += 101;     $mon = sprintf("%02d", $mon % 100);
$mday += 100;    $mday = sprintf("%02d", $mday % 100);
$hour += 100;    $hour = sprintf("%02d", $hour % 100);
$min += 100;     $min = sprintf("%02d", $min % 100);
$sec += 100;     $sec = sprintf("%02d", $sec % 100);


# mkdir("regtest_compile_logs") or die "mkdir failed: $!";
#mkpath("regtest_compile_logs/$year$mon$mday") or die "make_path failed: $!";
#copy( "WRFDA/compile.log.serial", "regtest_compile_logs/$year$mon$mday/compile.log.serial_$hour:$min:$sec" ) or die "Copy failed: $!";
print "$year$mon$mday\_$hour:$min:$sec \n";

#my $comparing = compare("BASELINE.NEW/wrfvar_output.Linux.tutorial_xinzhang.serial.pgi","BASELINE.NEW/wrfvar_output.Linux.tutorial_xinzhang.serial.pgi");

my @output = `diffwrf cv3_guo/wrfvar_output.Linux.cv3_guo.dmpar.ifort BASELINE.NEW/wrfvar_output.Linux.cv3_guo.dmpar.ifort`;

print "\@output= @output\n";
print "output= $output[0]\n";


my @output2 = `~/bin/diffwrf cv3_guo/wrfvar_output.Linux.cv3_guo.dmpar.ifort BASELINE.NEW/wrfvar_output.Linux.cv3_guo.dmpar.ifort`;

print "\@output2= @output2\n";
print "output2= $output2[0]\n";

my @output3 = `~/bin/diffwrf BASELINE.NEW/wrfvar_output.Linux.cv3_guo.dmpar.ifort BASELINE.NEW/wrfvar_output.Linux.cv3_guo.dmpar.ifort`;

print "\@output3= @output3\n";
print "output3= $output3[0]\n";

my @output4 = `~/bin/diffwrf BASELINE.NEW/wrfvar_output.Linux.tutorial_xinzhang.dmpar.ifort tutorial_xinzhang/wrfvar_output.Linux.tutorial_xinzhang.dmpar.ifort`;

print "\@output4= @output4\n";
print "output4= $output4[0]\n";

if ($output4[0] =~ /NetCDF error/ ) {
    print "Didn't find that, yo";
    print "$output4[0]";
} else {
    print "You did somethin wrong, brah\n";
}


if (!@output) {
    print "output is empty\n";
}

if (@output2) {
    print "output2 is non-empty\n";
}

if (@output3) {
    print "output3 is non-empty\n";
}

if (@output4) {
    print "output4 is non-empty\n";
}




