#!/usr/bin/perl -w
# Created March 27, 2013, Mike Kavulich. 
# Edited  April 03, 2014, Mike Kavulich: unchanged files as list rather than messy output
#         April 16, 2014, Mike Kavulich: Clarify input arguments and errors
# No rights reserved, user is free to modify and distribute as they wish.

# Usage: Copies wrfvar_output files to BASELINE.NEW, and copies the existing baseline to BASELINE.NEW.BACKUP
#        Will not copy files that are bit-for-bit identical
#        User can provide command-line arguments which are specific directories the script will check for output files
#                 (other directories will be ignored in this case). Wildcards (*) will work.

use File::Compare;
use File::Copy;
use Data::Dumper qw(Dumper);


my $checkall = " ";
my $checkall_unmatched = "";
my @changed;
my @unchanged;
my $uncopied_num = 0; #Note: uncopied_num will actually be the size of @unchanged, but @unchanged is indexed from 0

print "\nChecking files, please wait...\n";

foreach $arg (@ARGV) {
    $checkall = "$checkall$arg "; # Formulating the argument list this way avoids accidentally finding partial
                                  # matches for directory names
}

my $q = (@ARGV);

my @files = `find . -maxdepth 2 -follow -name "wrfvar_output.*"`;

my $copied_num = 0; #Note: copied_num will actually be the size of @changed, but @changed is indexed from 0
foreach $filename (@files) {
    chomp $filename;
    next if ($filename =~ m/BASELINE/i);

    my @fileparts = split('/',$filename);

    next if ( ($checkall !~ /\s$fileparts[1]\s/i) && ($q > 0) ); # Only check given directories
                                                                # (if they are provided as command-line args)

    unless ( compare ("$filename","BASELINE.NEW/$fileparts[2]") ) {
       $unchanged[$uncopied_num] = $filename;
       $uncopied_num = @unchanged;
       next ;
    }
    unless (-e "BASELINE.NEW/$fileparts[2]") {
        # If there is no baseline file, don't copy. For new tests you should add the baseline manually.
        print "WARNING: $filename does not have a baseline file for comparison! Not copying.\n";
        next;
    }
    mkdir "BASELINE.NEW.BACKUP" unless (-e "BASELINE.NEW.BACKUP");
    copy ("BASELINE.NEW/$fileparts[2]","BASELINE.NEW.BACKUP") or die "Cannot copy 'BASELINE.NEW/$fileparts[2]' to 'BASELINE.NEW.BACKUP': $!";
    copy ("$filename","BASELINE.NEW") or die "Cannot copy '$filename' to 'BASELINE.NEW': $!";
#    print "'$filename' copied to BASELINE.NEW, old baseline file backed up to BASELINE.NEW.BACKUP\n";
    $changed[$copied_num] = $filename;
    $copied_num = @changed;
}

if ($copied_num > 0){
    print "\nThe following $copied_num files were copied to BASELINE.NEW, old baseline files were backed up to BASELINE.NEW.BACKUP:\n\n";
    foreach $changed_name (@changed) {
        print "$changed_name\n";
    }


    unless ($uncopied_num < 1) {
        print "\nThe following $uncopied_num files were bit-for-bit identical to the baseline in BASELINE.NEW, and were not copied:\n\n";
        foreach $unchanged_name (@unchanged) {
            print "$unchanged_name\n";
        }
    }
} elsif ($uncopied_num > 0) {
    print "All $uncopied_num files were bit-for-bit identical to the baseline in BASELINE.NEW, and were not copied.\n";
} elsif ($q < 0) {
    print "No files found! Ensure you are in the REGTEST directory, and that the 'wrfvar_output' files exist.\n\n";
} else {
    print "No WRFDA output files found in any of the following directories:\n";
    print "$checkall\n";
    print "Check your input arguments, and that the 'wrfvar_output' files exist.\n\n";
}

