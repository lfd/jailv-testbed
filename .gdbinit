tar ext :1234
set history save on

set scheduler-locking step

layout src
winheight src 23
#winheight asm 13
fs cmd

add-symbol-file build/linux/vmlinux
add-symbol-file ./srcs/jailhouse/driver/jailhouse.ko 0xffffffff00f1e000  -s .bss  0xffffffff00f23d38  -s .data  0xffffffff00f23040
add-symbol-file ./srcs/jailhouse/hypervisor/hypervisor.o
add-symbol-file ./srcs/jailhouse/inmates/demos/riscv/tiny-demo-linked.o
