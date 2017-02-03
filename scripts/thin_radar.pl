#!/usr/bin/perl -w
# Author:  Mike Kavulich, 2016 April
# 
# Script is in the public domain for any use; no rights reserved.
#
# Updates: 2017 January, added command-line arguments, ability to discard missing obs
#
# Purpose: For crude thinning of WRFDA ASCII radar observation files
#
# Usage: ./thin_radar.pl --infile=ob.radar --outfile=ob.radar.mod --thinmesh=0.2 --noempty=0

use File::Copy;
use File::Path;
use Getopt::Long;


my $infile;
my $outfile;
my $thinmesh = 0.2;
my $discard_empty=0;
GetOptions( "infile=s" => \$infile,
            "outfile:s" => \$outfile,
            "thinmesh:s" => \$thinmesh,
            "noempty:s" => \$discard_empty ) or die "Problem with input arguments: $!";

open(INFILE, "<$infile") or die "Couldn't open observation file $infile, see README for more info $!";
open(OUTFILE, ">$outfile") or die "Couldn't open output file $outfile for writing: $!";

my @Radar_site;
my ($platform,$name,$lon,$lat,$elev,$date,$numobs,$maxlevs,$i,$j,$missinglevs);
my ($oblon,$oblat,$oblevs);
my $discard_ob;
my $prevlon= -9999.9;
my $prevlat= -9999.9;
my $blacklist_lon = -9999.9;
my $numobs_after_thinning = 0;
my $numstations;

# Loop for reading infile line by line
while (<INFILE>) {

   # Radar files always start with these two lines:
   # 
   # TOTAL NUMBER = {number_of_radar_stations}
   # #-----------------#
   #
   if (/^TOTAL NUMBER/) {
      open(OUTFILE, ">$outfile") or die "Couldn't open output file $outfile for writing: $!";
      print OUTFILE $_;
      $numstations = $_;
      $numstations =~ s/\D//g;
      print OUTFILE "#-----------------#\n";
      next;
   }
   next if /^#-/;  # Skip lines that start "#-"
   next if /^\s*$/;   # Skip blank lines
   if (/^RADAR/) { # If line starts "RADAR", it's a header line for a new radar site
      &print_radar_site(@Radar_site) if ($#Radar_site > 1); # If there's already a radar site,
                                                            # We need to print the old one
      ($platform, $name, $lon, $lat, $elev, $date, $numobs, undef) = unpack("(a5 a14 a10 a10 a10 a19 a6 a6)",$_);
      if ($#Radar_site > 1) {
         print "Num obs for $name= $numobs\n";
         print "Num obs after thinning    = $numobs_after_thinning\n";
      }
      undef @Radar_site;                                    # Reset the old array
      $numobs_after_thinning = 0;
      $maxlevs = 0;
      $i = -1;
      next;
   }

   if (/^FM-128 RADAR/) {
      $i++;
      $discard_ob = 0;
      $missinglevs=0;
      $j = 1;
      if ($i == 0) { 
         $Radar_site[$i][0]=$_;
         $numobs_after_thinning++;
         (undef, undef, undef, $prevlat, $prevlon, undef, $maxlevs) = unpack("(a12 a3 a19 a14 a14 a10 a8 )",$_);
         $oblevs=$maxlevs;
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
      if ($discard_empty) {  # Check the flags for each observation level: if all are missing, go back and discard the observation
         my ($rvflag,$rfflag);
         (undef, undef, $rvflag, undef, undef, undef, $rfflag, undef) = unpack("(a15 a12 a4 a12 a2 a12 a4 a12)",$_);
         $missinglevs++ if ( ($rvflag == -88) and ($rfflag == -88) ); # Check for missing data flags: -88
         if ($missinglevs == $oblevs) {   # If all levels are missing, delete the observation
#            print "\nObservation is all missing!\nLat $oblat\nLon $oblon\n";
            for my $jj (0..$j) {
               undef $Radar_site[$i][$jj];
            }
         $i--; # Need to decrement $i and $numobs_after_thinning since they were incremented before
         $numobs_after_thinning--;
         next;
         } 
      }
      $Radar_site[$i][$j]=$_;
      $j++;
   }

}

if ($numstations == 1) {
   print "Num obs for $name= $numobs\n";
   print "Num obs after thinning    = $numobs_after_thinning\n";
}

#Print final radar site
&print_radar_site(@Radar_site);

close INFILE;

sub print_radar_site { 

   my (@radar_site) = @_;

   open(OUTFILE, ">>$outfile") or die "Couldn't open output file $outfile for writing: $!";
   printf OUTFILE "\n${platform}${name}${lon}${lat}${elev}${date}%6u%6u\n",$numobs_after_thinning,$maxlevs;
   print OUTFILE "#-------------------------------------------------------------------------------#\n\n";

#   foreach my $ob ($#radar_site) {
#      foreach my $ob_level ($#ob) {
#         print OUTFILE $ob_level;
#      }
#   }

   for my $i (0..$#radar_site) {
      for my $j (0..$#{$radar_site[$i]}) {        
         print OUTFILE $radar_site[$i][$j] if ($radar_site[$i][$j]); #This if statement is to catch "undefined" deleted observations.
      }
   }
   close(OUTFILE);
}

