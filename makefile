FLAGS = -package ghc
CORE_SRC   = src/Core
SMT_SRC    = src/SMT
SAMPLE_SRC = src/Sample
HSK_SRC    = src/Haskell

all:
	ghc ${FLAGS} \
  Main.hs ${CORE_SRC}/*.hs ${SMT_SRC}/*.hs ${SAMPLE_SRC}/*.hs ${HSK_SRC}/*.hs \
  -odir build/ -o G2 && \
  rm *.hi ${CORE_SRC}/*.hi ${SMT_SRC}/*.hi ${SAMPLE_SRC}/*.hi ${HSK_SRC}/*.hi

clean:
	rm -rf G2 build/*

