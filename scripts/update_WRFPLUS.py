#!/usr/bin/python
#
# A python script for updating the WRFPLUSV3 branch of the main WRF repository (at https://github.com/wrf-model/WRF)
# with the master branch. It achieves this by using the "cherry-pick" option since a proper merge is impractical
#
# Usage: ./update_WRFPLUS.py date/hash
#                            date should be in ISO 8601 format (YYYY-MM-DD)
#                            hash should be abbreviated or full hash of the desired commit
# 
# Script will update the WRFPLUS branch with all the commits to the master since the specified date or hash


import os
import re
import sys
import warnings
import subprocess

if not (len(sys.argv)==2):
   print("\nError: you must specify a date or hash on the command line. See script comments for details\n")
   sys.exit("Usage: " + os.path.basename(__file__) + " date/hash")

wrfplusbranch = "WRFPLUSV3_update_test2"

since = str(sys.argv) # Specify starting point for cherry pick on the command line

print("Number of arguments: " + str(len(sys.argv)))
print("Since: " + since)


# Call git log with special options to get a list of hashes of commits since the specified date (or commit)
git_proc = subprocess.Popen(["git", "log", "--pretty=format:%h", "--since=" + since, "--reverse", "master"], stdout=subprocess.PIPE)
(out, err) = git_proc.communicate()
if err:
   sys.exit("There was an error: " + err)

print("Out : " + out)

git_commits = out.splitlines()

i = 0 # Set counter to keep track of commits
for commit in git_commits:
   print("Cherry-picking commit: " + commit)
#   proc = subprocess.call(["git", "cherry-pick", "-x", commit], stdout=subprocess.PIPE) # Cherry pick the commit; -x will leave
#   (out, err) = proc.communicate()

   try:
#  This line will cherry-pick the commit from the master onto the WRFPLUS branch; the -x option appends a line "(cherry picked from commit ...)" to the original commit message when it is applied to the branch
      proc = subprocess.check_output(["git", "cherry-pick", "-x", commit], stderr=subprocess.STDOUT)
   except subprocess.CalledProcessError, e: # I'm not sure if there's a better way to do the following, but this checks for errors and prompts user to continue
      cont = ''
      print("\nWARNING WARNING WARNING\n\n" + str(e.output))
      while not cont:
         cont = raw_input("Do you wish to continue? (y/n) ")
         if re.match('y', cont, re.IGNORECASE) is not None:
            break
         elif re.match('n', cont, re.IGNORECASE) is not None:
            if i > 0:
               print("User specified exit.\nCHANGES THAT HAVE APPLIED WILL NOT BE REVERSED: CHECK `git log` TO SEE CHANGES")
            sys.exit(1)
         else:
            print("Unrecognized input: " + cont)
            cont=''
   i += 1 #increment counter

print("Done! WRFPLUSV3 is up to date!\n")


