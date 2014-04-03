#!/usr/bin/perl -w
# Created March 27, 2013, Mike Kavulich. 
# No rights reserved, user is free to modify and distribute as they wish.
use File::Compare;
use File::Copy;

my $checkall = "";
foreach $arg (@ARGV) {
    $checkall = "$checkall $arg" ;
}

my $q = (@ARGV);


my @files = `find . -maxdepth 2 -follow -name "wrfvar_output.*"`;

my $loopnum = 0;
foreach $filename (@files) {
    $loopnum ++;
    chomp $filename;
    next if ($filename =~ m/BASELINE/i);

    my @fileparts = split('/',$filename);

    next if ( ($checkall !~ m/$fileparts[1]\s/i) && ($q > 0) );

    unless ( compare ("$filename","BASELINE.NEW/$fileparts[2]") ) {
       print "\n  'BASELINE.NEW/$fileparts[2]' AND '$filename' ARE EQUAL, DOING NOTHING.\n";
       next ;
    }
    mkdir "BASELINE.NEW.BACKUP" unless (-e "BASELINE.NEW.BACKUP");
    copy ("BASELINE.NEW/$fileparts[2]","BASELINE.NEW.BACKUP") or die "Cannot copy 'BASELINE.NEW/$fileparts[2]' to 'BASELINE.NEW.BACKUP': $!";
    copy ("$filename","BASELINE.NEW") or die "Cannot copy '$filename' to 'BASELINE.NEW': $_";
    print "'$filename' copied to BASELINE.NEW, old baseline file backed up to BASELINE.NEW.BACKUP\n";

}

