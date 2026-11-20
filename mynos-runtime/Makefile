# The MyNOS OCaml runtime: the upstream bytecode runtime (OCAML_RUNTIME_LIB,
# set by the dev container) linked with a MyNOS main() and the primitives of
# the Mynos library (mynos_stubs.c, built on libmynos).
#
# Also the C stubs of OCaml's unix, threads and str libraries (mynos-09i,
# mynos-rld), from the sources the container keeps beside the runtime:
# threads.cma needs unix.cma, so every Unix primitive is in the table;
# those whose Linux calls MyNOS lacks fail when called (ENOSYS). And the
# stubs of Num (third_party/num, mynos-yux), with its portable C digits.
#
# Outputs: ocamlrun, and primitives (the full primitive list, which ocamlc
# needs with -use-prims to link programs that use Mynos).
include ../mynos.mk
CC = $(MYNOS_CC)

OCAML_RUNTIME_LIB ?= /opt/ocaml-runtime-musl
CFLAGS = -Wall -O2 -I$(OCAML_RUNTIME_LIB) -I../mynos-lib/include

STUBS = mynos_stubs.c gfx_stubs.c

all: ocamlrun

# OCaml's unix and threads libraries (as otherlibs/unix/Makefile lists them)
OTHERLIBS = $(OCAML_RUNTIME_LIB)/otherlibs
OC_FLAGS = -O2 -fno-strict-aliasing -fwrapv -pthread -D_FILE_OFFSET_BITS=64 \
           -I$(OCAML_RUNTIME_LIB) -w
UNIX_C = $(addsuffix .c, \
  access addrofstr chdir chmod cst2constr cstringv execv execve execvp fsync \
  mkdir exit getaddrinfo getcwd gethost gethostname getnameinfo getproto \
  getserv gmtime mmap_ba putenv rename rmdir socketaddr strofaddr time unlink) \
  $(addsuffix _unix.c, \
  accept bind channels close connect dup envir errmsg getpeername getpid \
  getsockname gettimeofday isatty link listen lockf lseek mmap open pipe read \
  readlink realpath select sendrecv shutdown sleep socket socketpair sockopt \
  stat symlink times truncate unixsupport utimes write) \
  $(addsuffix .c, \
  alarm chown chroot closedir dup2 fchmod fchown fcntl fork ftruncate \
  getegid geteuid getgid getgr getgroups getlogin getppid getpw getuid \
  initgroups itimer kill mkfifo nice opendir readdir rewinddir setgid \
  setgroups setsid setuid signals spawn termios umask wait)
UNIX_SRC = $(addprefix $(OTHERLIBS)/unix/, $(UNIX_C))
UNIX_OBJ = $(addprefix unix/, $(UNIX_C:.c=.o))
THREADS_SRC = $(OTHERLIBS)/systhreads/st_stubs.c
THREADS_OBJ = threads/st_stubs.o
STR_SRC = $(OTHERLIBS)/str/strstubs.c
STR_OBJ = str/strstubs.o
NUM_SRC = ../third_party/num/nat_stubs.c ../third_party/num/bng.c
NUM_OBJ = num/nat_stubs.o num/bng.o
LIB_OBJ = $(UNIX_OBJ) $(THREADS_OBJ) $(STR_OBJ) $(NUM_OBJ)

unix/%.o: $(OTHERLIBS)/unix/%.c
	@mkdir -p unix
	$(CC) $(OC_FLAGS) -DCAML_BUILDING_UNIX -I$(OTHERLIBS)/unix -c $< -o $@

$(THREADS_OBJ): $(THREADS_SRC)
	@mkdir -p threads
	$(CC) $(OC_FLAGS) -I$(OTHERLIBS)/systhreads -c $< -o $@

$(STR_OBJ): $(STR_SRC)
	@mkdir -p str
	$(CC) $(OC_FLAGS) -c $< -o $@

num/%.o: ../third_party/num/%.c ../third_party/num/bng.h ../third_party/num/nat.h
	@mkdir -p num
	$(CC) $(OC_FLAGS) -c $< -o $@

primitives prims.c: gen_prims.sh $(STUBS) $(OCAML_RUNTIME_LIB)/primitives $(NUM_SRC)
	./gen_prims.sh $(OCAML_RUNTIME_LIB) $(STUBS) $(UNIX_SRC) $(THREADS_SRC) \
	  $(STR_SRC) $(NUM_SRC)

prims.o: prims.c
	$(CC) $(CFLAGS) -c prims.c

ocamlrun: main.o mynos_stubs.o gfx_stubs.o prims.o $(LIB_OBJ) \
          $(OCAML_RUNTIME_LIB)/libcamlrun.a ../mynos-lib/lib/libmynos.a
	$(CC) -o $@ main.o mynos_stubs.o gfx_stubs.o prims.o $(LIB_OBJ) \
	  $(OCAML_RUNTIME_LIB)/libcamlrun.a -L../mynos-lib/lib -lmynos \
	  -lm -lpthread $(MYNOS_LDFLAGS)

clean:
	rm -f *~ *.o ocamlrun primitives prims.c
	rm -rf unix threads str num
