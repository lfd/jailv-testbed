#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/ioctl.h>

typedef uint64_t u64;

struct qpx_rpc {
	u64 cmd;
	u64 a0;
	u64 a1;
	u64 a2;
} __attribute__((packed));

int main(int argc, char **argv)
{
	struct qpx_rpc rpc;
	const char *dev;
	int err, fd;

	if (argc != 2) {
		printf("usage: %s device\n", argv[0]);
		return -1;
	}

	dev = argv[1];
	printf("QPX: opening device %s\n", dev);
	fd = open(dev, O_RDWR);

	rpc.cmd = 0;
	rpc.a0 = 0xdeadbeefd00dfeed;
	rpc.a1 = rpc.a2 = 0xaa55;

	if (write(fd, &rpc, sizeof(rpc)) != sizeof(rpc)) {
		err = -EINVAL;
		printf("QPX: write error\n");
		goto close_out;
	}

	err = ioctl(fd, 0);
	if (err) {
		printf("QPX: ioctl error\n");
		goto close_out;
	}

close_out:
	printf("QPX: closing device %s\n", dev);
	close(fd);

	return err;
}
