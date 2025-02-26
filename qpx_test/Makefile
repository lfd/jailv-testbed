CROSS_COMPILE=riscv64-linux-gnu-
CC=$(CROSS_COMPILE)gcc

CFLAGS=-Wall -Werror -Wextra

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $^

all: qpx_test

qpx_test: main.o
	$(CC) -static $(CFLAGS) -o $@ $^

clean:
	rm -fv qpx_test *.o
