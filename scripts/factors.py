#!/usr/bin/env python



for x in range(0, 1000):
    print('For number ' + str(x))
    for n in range(x, x+60):
       if ( (n % 8 == 0) and (n % 5 == 0) and (n % 9 == 0)):
          print("We found a factor!")
          continue
       if (n == x+60):
          print("NO FACTORS FOUND FOR")
          print n


