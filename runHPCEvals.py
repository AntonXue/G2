import collections
import os
import re
import subprocess
import sys
import time
NVALUE = 1000
TIMEOUT = 300 # seconds

projDir = "../liquidhaskell-study/wi15/smallcheck/benchmarks/"

listDir = "" #"eval-list/"
listTargets = [
    ("Catch.hs", "prop", 1000),
    ("Mux.hs", "prop_encDec", 11000),
    ("Mux.hs", "prop_mux", 1000),
    ("MuxSad.hs", "prop_binSad", 1000), #?
    ("Countdown.hs", "prop_lemma3", 1000),
    ("Countdown.hs", "prop_solutions", 1000), #?
    ("Huffman.hs", "prop_decEnc", 1000), #?
    ("Huffman.hs", "prop_optimal", 1000), #?
    #("ListSet.hs", "prop_insertSet"),
    ("Mate.hs", "prop_checkmate", 1000),
    ("Mux.hs", "prop_encode", 1000),
    ("RedBlack.hs", "prop_insertRB", 1000),
    ("RegExp.hs", "prop_regex", 1000),
    ("SumPuz.hs", "prop_Sound", 1000),
    ("Turner.hs", "prop_abstr", 1000),
]



# Evaluation runner.
def runEval(evalDir, evalList, runStats):
  for (file, f, nv) in evalList:
      command = "cabal run G2 -- {0}  {1}  {2} --n {3} --time {4}"\
                .format(projDir + evalDir, projDir + evalDir + file, f, nv, TIMEOUT)
      # print(command)
      startTime = time.time()
      p = subprocess.Popen(command, stdout=subprocess.PIPE, shell=True)
      (output, err) = p.communicate()
      p_status = p.wait()
      deltaTime = time.time() - startTime

      runStats.append((file, f, deltaTime))
      print((file, f, deltaTime))
      print(output)
      # if re.search("violating ([^f]*[^i]*[^x]*[^m]*[^e])\'s refinement type", output) is not None:
      #   hasConcrete = re.search("violating ([^f]*[^i]*[^x]*[^m]*[^e])\'s refinement type\nConcrete",
      #                           output) is not None
      #   hasAbstract = "Abstract" in output
      #   runStats.append((file, f, hasConcrete, hasAbstract, deltaTime))
      #   print((file, f, hasConcrete, hasAbstract, deltaTime))
      # else:
      #   runStats.append((file, f, False, False, deltaTime))
      #   print((file, f, False, False, deltaTime))

# Get all the RHS of the file-functions pairs.
rhs = [x for xs in (map(lambda p: p[1], listTargets))
         for x in xs]

# Generate a statistics over the source -- used for the LHS of the eval table.
sourceStats = {}
for x in rhs:
  if x in sourceStats:
    sourceStats[x] = sourceStats[x] + 1
  else:
    sourceStats[x] = 1

# Maybe print it :)
# print(sourceStats)


runStats = []
startTime = time.time()
runEval(listDir, listTargets, runStats)
# runEval(mapreduceDir, mapreduceTargets, runStats)
# runEval(kmeansDir, kmeansTargets, runStats)

# Some formatted printing -- pretty dull at the moment
for (file, fun, hasConcrete, hasAbstract, elapsed) in runStats:
  if hasAbstract or hasConcrete:
    print("PASS: {0}:{1}  -- C: {3}, A: {4} -- {2}"\
          .format(file, fun, elapsed, int(hasConcrete), int(hasAbstract)))
  else:
    print("FAIL: {0}:{1}  --                -- {2}"\
          .format(file, fun, elapsed))

print("Elapsed time: "  + str(time.time() - startTime))