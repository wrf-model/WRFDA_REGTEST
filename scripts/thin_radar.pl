#!/usr/bin/perl -w
# Author:  Mike Kavulich, 2016 April
# 
# Script is in the public domain for any use; no rights reserved.
#
# Updates:
#
# Purpose: For crude thinning of WRFDA ASCII radar observation files
#
# Usage: ./thin_radar.pl --infile=ob.radar --outfile=ob.radar.mod

use File::Copy;
use File::Path;
use Getopt::Long;


my $infile;
my $outfile;
GetOptions( "infile=s" => \$infile,
            "outfile:s" => \$outfile ) or die "Problem with input arguments: $!";

my $thinmesh = 0.2;

open(INFILE, "<$infile") or die "Couldn't open observation file $infile, see README for more info $!";
open(OUTFILE, ">$outfile") or die "Couldn't open output file $outfile for writing: $!";

my @Radar_site;
my ($platform,$name,$lon,$lat,$elev,$date,$numobs,$maxlevs,$i,$j);
my ($oblon,$oblat,$oblevs);
my $discard_ob;
my $prevlon= -9999.9;
my $prevlat= -9999.9;
my $blacklist_lon = -9999.9;
my $numobs_after_thinning = 0;
while (<INFILE>) {
   if (/^TOTAL NUMBER/) {
      open(OUTFILE, ">$outfile") or die "Couldn't open output file $outfile for writing: $!";
      print OUTFILE $_;
      print OUTFILE "#-----------------#\n\n";
   }
   next if /^#-/;
   next if /^$/;
   if (/^RADAR/) {
      &print_radar_site(@Radar_site) if ($#Radar_site > 1);
      undef @Radar_site;
      $numobs_after_thinning = 0;
      $maxlevs = 0;
      $i = -1;
      ($platform, $name, $lon, $lat, $elev, $date, $numobs, undef) = unpack("(a5 a14 a10 a10 a10 a19 a6 a6)",$_);
print "name${name}name\n";
      next;
   }

   if (/^FM-128 RADAR/) {
      $i++;
      $discard_ob = 0;
      $j = 1;
      if ($i == 0) {
         $Radar_site[$i][0]=$_;
         $numobs_after_thinning++;
         (undef, undef, undef, $prevlat, $prevlon, undef, $maxlevs) = unpack("(a12 a3 a19 a14 a14 a10 a8 )",$_);
         next;
      }
      (undef, undef, undef, $oblat, $oblon, undef, $oblevs) = unpack("(a12 a3 a19 a14 a14 a10 a8)",$_);

      if ($oblon == $blacklist_lon) {
         $discard_ob = 1;
         next;
      }
      if (abs($oblon-$prevlon) < 0.00001) {
         if (abs($oblat-$prevlat) >= $thinmesh) {
            $maxlevs = $oblevs if ($oblevs > $maxlevs);
            $Radar_site[$i][0]=$_;
            $numobs_after_thinning++;
            $prevlat = $oblat;
         } else {
            $discard_ob = 1;
         }
      } elsif (abs($oblon-$prevlon) >= $thinmesh) {
         $maxlevs = $oblevs if ($oblevs > $maxlevs);
         $Radar_site[$i][0]=$_;
         $numobs_after_thinning++;
         $prevlat = $oblat;
         $prevlon = $oblon;
      } else {
         $blacklist_lon = $oblon;
         $discard_ob = 1;
      }
      next;
   }

   if ($discard_ob < 1) {
      $Radar_site[$i][$j]=$_;
      $j++;
   }

}

#Print final radar site
&print_radar_site(@Radar_site);

close INFILE;

print "Num obs = $numobs\n";
print "Num obs after thinning= $numobs_after_thinning\n";


sub print_radar_site { 

   my (@radar_site) = @_;

   open(OUTFILE, ">>$outfile") or die "Couldn't open output file $outfile for writing: $!";
   printf OUTFILE "${platform}${name}${lon}${lat}${elev}${date}%6u%6u\n",$numobs_after_thinning,$maxlevs;
   print OUTFILE "#-------------------------------------------------------------------------------#\n\n";

#   foreach my $ob ($#radar_site) {
#      foreach my $ob_level ($#ob) {
#         print OUTFILE $ob_level;
#      }
#   }

for my $i (0..$#radar_site) {
   for my $j (0..$#{$radar_site[$i]}) {        
print $radar_site[$i][$j];
         print OUTFILE $radar_site[$i][$j];
   }
}
   close(OUTFILE);
}

