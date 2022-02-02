tar ext :1234
set history save on

set scheduler-locking step

layout split
winheight src 13
winheight asm 13
fs cmd

add-symbol-file build/linux/vmlinux
add-symbol-file ./srcs/jailhouse/driver/jailhouse.ko 0xffffffff00f0c000  -s .bss  0xffffffff00f11ab0  -s .data  0xffffffff00f11000
add-symbol-file ./srcs/jailhouse/hypervisor/hypervisor.o
add-symbol-file ./srcs/jailhouse/inmates/demos/riscv/tiny-demo-linked.o
