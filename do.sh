#!/bin/bash

set -e

#target=konservendose
target=testrack
#hw_target=testrack-noel
hw_target=jv

cmd=$1

buildroot=$(realpath srcs/buildroot/)
dts=$(realpath srcs/dts/)
busybox=$(realpath srcs/busybox/)
jailhouse=$(realpath srcs/jailhouse/)
linux=$(realpath srcs/linux/)
qemu=$(realpath srcs/qemu/)
opensbi=$(realpath srcs/opensbi/)
res=$(realpath res/)

# requires absolute path
dst_busybox="$PWD/build/busybox/"
dst_buildroot_root="$PWD/build/buildroot_root/"
dst_buildroot_nonroot="$PWD/build/buildroot_nonroot/"
dst_initrd="$PWD/build/initrd/"
dst_rootfs="$dst_initrd/rootfs/"
dst_f_initrd="$dst_initrd/initramfs.cpio"
dst_linux="$PWD/build/linux/"
dst_opensbi="$PWD/build/opensbi/"
dst_qemu="$PWD/build/qemu/"
dtb="$PWD/build/dtb/"

buildroot_overlay="$PWD/build/buildroot-overlay"

busybox_res="$res/busybox/"

nproc=$(nproc)
MAKE="make -j $(nproc)"

. setenv
INITRD="$dst_buildroot_root/images/rootfs.cpio.gz"
#INITRD="$dst_initrd/initramfs.cpio"

DTB_QEMU="$dtb/qemu"

function debug() {
	${CROSS_COMPILE}gdb -q
}

function prepare_buildroot() {
	cd $buildroot
	make O=$dst_buildroot_root defconfig
	make O=$dst_buildroot_nonroot defconfig
	cd ../..
	cp res/buildroot-config $dst_buildroot_root/.config
	cp res/buildroot_nonroot-config $dst_buildroot_nonroot/.config
	cd $dst_buildroot_root
	make oldconfig
	cd $dst_buildroot_nonroot
	make oldconfig
}

function prepare_overlay() {
	# Prepare root overlay
	mkdir -p $buildroot_overlay/usr/bin/ \
		 $buildroot_overlay/root/.ssh \
		 $buildroot_overlay/etc/jailhouse \
		 $buildroot_overlay/usr/lib/firmware/
	tar -xvf res/ssh.tar -C $buildroot_overlay/
	cp -v build/buildroot_nonroot/images/rootfs.cpio.gz $buildroot_overlay/root/
	cp -v res/authorized_keys $buildroot_overlay/root/.ssh/
	cp -v res/bash_history $buildroot_overlay/root/.bash_history
	cp -v res/bashrc $buildroot_overlay/root/.bashrc
	echo bash > $buildroot_overlay/root/.bash_login
	cp -v $KERNEL $buildroot_overlay/root/

	cp -av $jailhouse/driver/jailhouse.ko $buildroot_overlay/root/
	cp -av $jailhouse/hypervisor/jailhouse.bin $buildroot_overlay/usr/lib/firmware
	cp -av $jailhouse/tools/jailhouse $buildroot_overlay/usr/bin/
	cp -av $jailhouse/tools/jailhouse-cell-stats $buildroot_overlay/usr/bin/

	cp -av $jailhouse/configs/riscv/*.cell $buildroot_overlay/etc/jailhouse/
	cp -av $jailhouse/configs/riscv/dts/*.dtb $buildroot_overlay/etc/jailhouse
	cp -av $jailhouse/inmates/demos/riscv/*.bin $buildroot_overlay/etc/jailhouse
	cp -av $jailhouse/inmates/tools/riscv/*.bin $buildroot_overlay/etc/jailhouse
	cp -av res/scripts/* $buildroot_overlay/usr/bin/
}

function buildroot() {
	# Build buildroot for non-root cell
	cd $dst_buildroot_nonroot
	make
	cd ../..

	prepare_overlay

	cd $dst_buildroot_root
	make
}

function compile_dts() {
	cat $dts/noel-template.dts > $dts/noel-uc-noeth.dts
	cat $dts/noel-template.dts | sed '/MULTICORE/d' | sed '/NOETH/d' > $dts/noel-mc-noeth.dts
	cat $dts/noel-template.dts | sed '/ETHERNET/d' > $dts/noel-uc-eth.dts
	cat $dts/noel-template.dts | sed '/ETHERNET/d' | sed '/MULTICORE/d' > $dts/noel-mc-eth.dts
	for i in $dts/*; do
		dtc -I dts -O dtb -o $dtb/$(basename -s .dts $i).dtb  $i
	done
}

function start_qemu() {
	mkdir -p $dtb
	compile_dts

	if [[ $1 == "uc" ]]; then
		CPUS=1
	elif [[ $1 == "mc" ]]; then
		CPUS=6
	else
		echo "Unknown config $1"
		exit -1
	fi

	$QEMU \
		-monitor null \
		-cpu rv64,h=true -smp cpus=$CPUS \
		-m 1G \
		-display none \
		-serial mon:stdio \
		-monitor telnet:127.0.0.1:55555,server,nowait \
		-kernel $KERNEL \
		-initrd $INITRD \
		-machine $QEMU_MACHINE \
		-netdev user,id=net,hostfwd=::33333-:22,hostfwd=::33344-:23 \
		-device e1000e,addr=2.0,netdev=net \
		-append "mem=510M ip=dhcp earlycon=sbi" \
		-s
}

function build_initrd() {
	cd $dst_rootfs

	cp -av $KERNEL .
	mkdir -p ./etc/jailhouse
	cp -av $jailhouse/configs/riscv/dts/*.dtb \
		$jailhouse/configs/riscv/*.cell \
		$jailhouse/inmates/demos/riscv/*.bin \
		$jailhouse/inmates/tools/riscv/*.bin \
		./etc/jailhouse/
	cp -av $jailhouse/driver/jailhouse.ko .
	cp -av $jailhouse/hypervisor/jailhouse.bin ./lib/firmware
	cp -av $jailhouse/tools/jailhouse ./sbin/jailhouse
	cp -av $jailhouse/tools/jailhouse-cell-stats ./sbin/jailhouse

	cp -av $busybox_res/rcS ./etc/init.d/rcS
	cp -av $busybox_res/fstab ./etc/fstab
	cp -av $res/scripts/* ./usr/bin/

	find . | cpio -o -H newc > $dst_f_initrd
}

function build_linux() {
	cd $dst_linux
	$MAKE
}

function build_opensbi() {
	cd $opensbi
	# Remove OpenSBI firmware to enforce rebuild
	rm -rf $dst_opensbi/platform/generic/firmware
	$MAKE FW_TEXT_START=0 PLATFORM=generic FW_PIC= O=$dst_opensbi FW_PAYLOAD_PATH=$KERNEL
	cd ../..
	mkdir -p $dtb
}

function prepare_linux() {
	mkdir -p $dst_linux
	cp res/linux-config $dst_linux/.config
	cd $dst_linux
	$MAKE -C $linux O=$dst_linux oldconfig
}

function build_qemu() {
	mkdir -p $dst_qemu
	cd $dst_qemu
	$qemu/configure --disable-werror --target-list=riscv64-softmmu
	$MAKE
}

# We build Jailhouse inside the source directory. Eases Debugging.
function build_jailhouse() {
	cd $jailhouse
	$MAKE
}

function deploy() {
	rsync -avz -e ssh \
		$dtb/noel-*.dtb \
		$KERNEL \
		$VMLINUX \
		$dst_opensbi/platform/generic/firmware/fw_payload.elf \
		build/initrd/initramfs.cpio \
		$dst_buildroot_root/images/rootfs.cpio.gz \
		$jailhouse/driver/jailhouse.ko \
		$jailhouse/hypervisor/hypervisor.o \
		$target:
}

function deploy_target() {
	prepare_overlay
	cd $buildroot_overlay
	rsync --chown root:root -avz -e ssh --owner root \
		. $hw_target:/

}

function build_busybox() {
	mkdir -p $dst_busybox
	cp res/busybox/defconfig $dst_busybox/.config
	cd $busybox
	$MAKE O=$dst_busybox oldconfig
	cd $dst_busybox
	$MAKE CONFIG_PREFIX=$dst_rootfs install

	cd $dst_rootfs

	mkdir -p etc/init.d/ lib/firmware/ proc sys dev etc/dropbear dev/pts
	ln -svf /sbin/init ./init
}

if [[ $cmd == "debug" ]]; then
	debug
elif [[ $cmd == "initrd" ]]; then
	build_initrd
elif [[ $cmd == "dts" ]]; then
	compile_dts
elif [[ $cmd == "jailhouse" ]]; then
	build_jailhouse
elif [[ $cmd == "linux" ]]; then
	build_linux
elif [[ $cmd == "opensbi" ]]; then
	build_opensbi
elif [[ $cmd == "prepare_linux" ]]; then
	prepare_linux
elif [[ $cmd == "qemu" ]]; then
	build_qemu
elif [[ $cmd == "busybox" ]]; then
	build_busybox
elif [[ $cmd == "start" ]]; then
	start_qemu $2
elif [[ $cmd == "deploy" ]]; then
	deploy
elif [[ $cmd == "deploy_target" ]]; then
	deploy_target
elif [[ $cmd == "buildroot" ]]; then
	buildroot
elif [[ $cmd == "prepare_buildroot" ]]; then
	prepare_buildroot
elif [[ $cmd == "qemu_aplic_uc" ]]; then
	QEMU_MACHINE="virt,aia=aplic"
	build_jailhouse
	#build_initrd
	start_qemu uc virt
elif [[ $cmd == "qemu_aplic_mc" ]]; then
	QEMU_MACHINE="virt,aia=aplic"
	build_jailhouse
	#build_initrd
	start_qemu mc virt
elif [[ $cmd == "qemu_uc" ]]; then
	QEMU_MACHINE="virt"
	build_jailhouse
	#build_initrd
	start_qemu uc virt
elif [[ $cmd == "qemu_mc" ]]; then
	QEMU_MACHINE="virt"
	build_jailhouse
	#build_initrd
	start_qemu mc virt
else
	echo "Unknown target: $cmd"
fi
