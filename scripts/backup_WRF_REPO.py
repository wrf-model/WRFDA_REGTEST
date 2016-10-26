#!/usr/bin/python
#
# A python script for backing up the main WRF repository (at https://github.com/wrf-model/WRF) and
# all its branches to HPSS

import os
import re
import sys
import time
import string
import shutil
import tarfile
import subprocess

now = time.strftime("%Y-%m-%d_%H:%M:%S")

print ("Starting backup script at " + now)

print ("Printing environment:\n")
print "Content-Type: text/plain\n\n"
for key in os.environ.keys():
    print "%30s %s \n" % (key,os.environ[key])


wrfdir = "WRF"
url = "git@github.com:wrf-model/WRF"

# Remove old WRF directory if it exists (it shouldn't, but never a bad idea to check)
#if os.path.isdir(wrfdir):
#   print("Removing old directory " + wrfdir)
#   shutil.rmtree(wrfdir)
#
#print("Cloning current WRF repository from github: " + url)
#os.system("git clone " + url + " " + wrfdir)
#os.chdir(wrfdir)
#
## Check out all remote branches locally
#
## Call git branch -a to get a list of remote branches
#git_proc = subprocess.Popen(["git", "branch", "-a"], stdout=subprocess.PIPE)
#(out, err) = git_proc.communicate()
#if err:
#   sys.exit("There was an error: " + err)
#
#git_branches = out.splitlines()
#
#for fullbranch in git_branches:
#   branch = fullbranch.split("/") # Remote branches are listed as remote/origin/branchname;
#   branch = branch[-1]            # need to extract "branchname"
#   regexp = re.compile(r'^.*\*\s')# `git branch -a` returns the current branch (master) with an asterisk at the beginning; skip this entry
#   if regexp.search(branch) is not None:
#      print(branch + " is checked out")
#      continue
#   proc = subprocess.Popen(["git", "checkout", branch], stdout=subprocess.PIPE) # Check out remote branch locally 
#   (out, err) = proc.communicate()
#   if err:
#      sys.exit("There was an error: " + err)
#
#print("Remove remote/origin: we don't want to keep the origin since this is a self-contained backup")
#git_proc = subprocess.Popen(["git", "remote", "rm", "origin"], stdout=subprocess.PIPE)
#(out, err) = git_proc.communicate()
#if err:
#   sys.exit("There was an error: " + err)
#
#print("Finally, checking out master so backup is neat and clean")
#os.system("git checkout master")
#
#os.chdir("..")

# Create tar file
tarname = "WRF_BACKUP_" + now + ".tar"
print("Creating tar file " + tarname)
out = tarfile.open(tarname, mode='w')
try:
    out.add(wrfdir) # Adding WRF directory to tar file
finally:
    print("Done creating " + tarname)
    out.close() # Close tar file

# Remove WRF directory

print("Removing local WRF clone (no longer needed): " + wrfdir)
#shutil.rmtree(wrfdir)

# Upload tar to HPSS

print("Putting " + tarname + " to HPSS under WRF_REPO_BACKUPS/" + tarname)
bsub_proc = subprocess.Popen(["/ncar/opt/lsf/9.1/linux2.6-glibc2.3-x86_64/bin/bsub", "-n", "1", "-q", "hpss", "-W", "10", "-P", "P64000400", "hsi", "cput", tarname + " : WRF_REPO_BACKUPS/" + tarname], stdout=subprocess.PIPE)
(out, err) = bsub_proc.communicate()
if err:
   sys.exit("There was an error: " + err)
#os.system("bsub -n 1 -q hpss -W 10 -P P64000400 hsi cput " + tarname + " : WRF_REPO_BACKUPS/" + tarname)

print(out)

