#!/usr/bin/perl -w
#
##################################################################
# Converts the remote branches and tags in a new git repository
# (created by git-svn) into local branches and tags. Creates two
# csh scripts in the process that are executed to do the actual 
# branch/tag conversion. These can be saved for future reference.
# 
# Written by Michael Kavulich, Jr., May 2016
##################################################################
#
#

use strict;
#use Time::HiRes qw(sleep gettimeofday);
#use Time::localtime;
#use Sys::Hostname;
#use File::Copy;
#use File::Path;
#use File::Basename;
#use File::Compare;
#use IPC::Open2;
#use Net::FTP;
#use Getopt::Long;

my $cmd = 'git branch -a';
my @gitbranches = `$cmd`;

foreach my $line (@gitbranches) {
   chomp $line;
   if ($line =~ /remotes\/svn\/tags\//) {
      my $tag = $line;
      $tag =~ s/remotes\/svn\/tags\///;
      print "Found tag $line, converting to git tag $tag\n";
      system("git tag $tag $line");
   } elsif ($line =~ /remotes\/svn\//) {
      my $branch = $line;
      $branch =~ s/remotes\/svn\///;
      print "Found branch $line, converting to git branch $branch\n";
      system("git branch $branch $line");
   } else {
      print "Found non-svn branch $line, ignoring\n";
   }
}

