#!/usr/bin/perl -w

use File::Copy;
use File::Path;

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
if (!-d "/loblolly2/kavulich/REGRESSION/regtest_compile_logs/$year$mon$mday") { 
make_path("/loblolly2/kavulich/REGRESSION/regtest_compile_logs/$year$mon$mday") or die "mkpath failed: $!\n/loblolly2/kavulich/REGRESSION/regtest_compile_logs/$year$mon$mday";
print "$year$mon$mday\_$hour:$min:$sec";
}



