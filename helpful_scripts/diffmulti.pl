#!/usr/bin/perl -w
 # Created April 10, 2013, Mike Kavulich.
 # No rights reserved, user is free to modify and distribute as they wish.

 # USAGE: feed script a path expression and another directory to compare to
 #                           WILDCARDS MUST BE ESCAPED!!!
 #        e.g. "./diffmulti.pl some_directory/\*.log some_other_directory"

use File::Compare;
use File::Copy;
use strict;
use warnings;

 #my $dirs = (@ARGV);
die "\nUSAGE: feed script a path expression and another directory to compare to\n
                           WILDCARDS MUST BE ESCAPED!!!\n
       e.g. './diffmulti.pl some_directory/*.log some_other_directory'\n" unless ($ARGV[0]);

my @paths = glob ("$ARGV[0]");

die "\nNo files match '$ARGV[0]'\n" unless ($paths[0]);


 # Get the first parent directory (there's probably a better way to do this)
my @firstdir = split('/',$paths[0]);
pop @firstdir;
my $firstpath = join ("/",@firstdir);


 # Make an array of the files in the first directory
my $i = 0 ;
my @files ;
foreach my $path (@paths) {
    my @pathparts = split('/',$path);
    $files[$i] = $pathparts[-1];
    $i++;
}


 # Compare to files in second directory
foreach my $filename (@files) {
    next unless (-e "$ARGV[1]/$filename") ;
    print "\nDifferences in $filename:\n";
    print `diff $firstpath/$filename $ARGV[1]/$filename`;

}




