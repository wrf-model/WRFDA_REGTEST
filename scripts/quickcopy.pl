#!/usr/bin/perl -w
# Created March 27, 2013, Mike Kavulich. 
# Edited  April 03, 2014, Mike Kavulich: unchanged files as list rather than messy output, allow baseline name as input
# No rights reserved, user is free to modify and distribute as they wish.
use File::Compare;
use File::Copy;

my $checkall = "";
my @changed;
my @unchanged;
my $uncopied_num = 0; #Note: uncopied_num will actually be the size of @unchanged, but @unchanged is indexed from 0

foreach $arg (@ARGV) {
    $checkall = "$checkall $arg" ;
}

my $q = (@ARGV);

my @files = `find . -maxdepth 2 -follow -name "wrfvar_output.*"`;

my $copied_num = 0; #Note: copied_num will actually be the size of @changed, but @changed is indexed from 0
foreach $filename (@files) {
    chomp $filename;
    next if ($filename =~ m/BASELINE/i);

    my @fileparts = split('/',$filename);

    next if ( ($checkall !~ m/$fileparts[1]\s/i) && ($q > 0) );

    unless ( compare ("$filename","BASELINE.NEW/$fileparts[2]") ) {
       $unchanged[$uncopied_num] = $filename;
       $uncopied_num = @unchanged;
       next ;
    }
    mkdir "BASELINE.NEW.BACKUP" unless (-e "BASELINE.NEW.BACKUP");
    unless (-e "BASELINE.NEW/$fileparts[2]") {
        # If there is no baseline file, don't copy. For new tests you should add the baseline manually.
        print "WARNING: $filename does not have a baseline file for comparison! Not copying.\n";
    }
    copy ("BASELINE.NEW/$fileparts[2]","BASELINE.NEW.BACKUP") or die "Cannot copy 'BASELINE.NEW/$fileparts[2]' to 'BASELINE.NEW.BACKUP': $!";
    copy ("$filename","BASELINE.NEW") or die "Cannot copy '$filename' to 'BASELINE.NEW': $!";
    print "'$filename' copied to BASELINE.NEW, old baseline file backed up to BASELINE.NEW.BACKUP\n";
    $copied_num ++;
}

if ($copied_num > 0){
    print "The following $copied_num files were copied to BASELINE.NEW, old baseline file were backed up to BASELINE.NEW.BACKUP:\n\n";
    foreach $changed_name (@changed) {
        print "$changed_name\n";
    }


    unless ($uncopied_num < 1) {
        print "The following $uncopied_num files were bit-for-bit identical to the baseline in BASELINE.NEW, and were not copied:\n\n";
        foreach $unchanged_name (@unchanged) {
            print "$unchanged_name\n";
        }
    }
} else {
    print "All $uncopied_num files were bit-for-bit identical to the baseline in BASELINE.NEW, and were not copied.\n";
}

