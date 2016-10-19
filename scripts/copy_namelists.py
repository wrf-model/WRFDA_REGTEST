#!/usr/bin/python
#
# A python script for backing up the main WRF repository (at https://github.com/wrf-model/WRF) and
# all its branches to HPSS

import re
import sys
import subprocess

testdatadir="WRFDA-data-EM"
namelistdir = "namelists/"
url = "git@github.com:wrf-model/WRF"


# Call ls to get a list of test names in testdatadir
git_proc = subprocess.Popen(["ls", "-l", testdatadir], stdout=subprocess.PIPE)
(out, err) = git_proc.communicate()
if err:
   sys.exit("There was an error: " + err)

testdirs = out.splitlines()

for fullbranch in testdirs:
   testname = fullbranch.split(" ") 
   testname = testname[-1]            # need to extract "testname", which is in the last column of the "ls" output
   regexp = re.compile(r'tar$')
   if regexp.search(testname) is not None:
      print(testname + " is a tar file")
      continue
   print("Copying '" + testdatadir + "/" + testname + "/namelist.input' to '" + namelistdir + "/namelist.input." + testname)
   proc = subprocess.Popen(["cp", testdatadir + "/" + testname + "/namelist.input", namelistdir + "/namelist.input." + testname], stdout=subprocess.PIPE) 
   (out, err) = proc.communicate()
   if err:
      sys.exit("There was an error: " + err)

print(out)

print("\nDone!\n")

