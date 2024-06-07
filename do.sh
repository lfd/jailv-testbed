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
dst_buildroot_non_root="$PWD/build/buildroot_non_root/"
dst_initrd="$PWD/build/initrd/"
dst_rootfs="$dst_initrd/rootfs/"
dst_f_initrd="$dst_initrd/initramfs.cpio"
dst_linux="$PWD/build/linux/"
dst_opensbi="$PWD/build/opensbi/"
dst_qemu="$PWD/build/qemu/"
dtb="$PWD/build/dtb/"

buildroot_root_overlay="$PWD/build/buildroot_root_overlay"
buildroot_non_root_overlay="$PWD/build/buildroot_non_root_overlay"

busybox_res="$res/busybox/"

nproc=$(nproc)
MAKE="make -j $(nproc)"

. setenv

INITRD="$dst_buildroot_root/images/rootfs.cpio.gz"
#INITRD="$dst_buildroot_non_root/images/rootfs.cpio.gz"
#INITRD="$dst_initrd/initramfs.cpio.gz"

DTB_QEMU="$dtb/qemu"

function debug() {
	${CROSS_COMPILE}gdb -q
}

function prepare_buildroot() {
	cd $buildroot
	make O=$dst_buildroot_root defconfig
	make O=$dst_buildroot_non_root defconfig
	cd ../..
	cp res/buildroot_root-config $dst_buildroot_root/.config
	cp res/buildroot_non_root-config $dst_buildroot_non_root/.config
	cd $dst_buildroot_root
	make oldconfig
	cd $dst_buildroot_non_root
	make oldconfig
}

function prepare_non_root_overlay() {
	# Prepare non-root overlay
	mkdir -p $buildroot_non_root_overlay/etc/systemd/network \
		 $buildroot_non_root_overlay/root/.ssh
	cp -av res/1-jailhouse-non-root.network $buildroot_non_root_overlay/etc/systemd/network/
	tar -xvf res/ssh.tar -C $buildroot_non_root_overlay/
	cp -v res/authorized_keys $buildroot_non_root_overlay/root/.ssh/
	echo bash > $buildroot_non_root_overlay/root/.bash_login
}

function prepare_root_overlay() {
	# Prepare root overlay
	mkdir -p $buildroot_root_overlay/usr/bin/ \
		 $buildroot_root_overlay/root/.ssh \
		 $buildroot_root_overlay/etc/jailhouse \
		 $buildroot_root_overlay/usr/lib/firmware/ \
		 $buildroot_root_overlay/etc/systemd/network/
	tar -xvf res/ssh.tar -C $buildroot_root_overlay/
	cp -v build/buildroot_non_root/images/rootfs.cpio.gz $buildroot_root_overlay/root/
	cp -v res/authorized_keys $buildroot_root_overlay/root/.ssh/
	cp -v res/bash_history $buildroot_root_overlay/root/.bash_history
	cp -v res/bashrc $buildroot_root_overlay/root/.bashrc
	echo bash > $buildroot_root_overlay/root/.bash_login
	cp -v $KERNEL $buildroot_root_overlay/root/

	cp -av $jailhouse/driver/jailhouse.ko $buildroot_root_overlay/root/
	cp -av $jailhouse/hypervisor/jailhouse.bin $buildroot_root_overlay/usr/lib/firmware
	cp -av $jailhouse/tools/jailhouse $buildroot_root_overlay/usr/bin/
	cp -av $jailhouse/tools/jailhouse-cell-stats $buildroot_root_overlay/usr/bin/

	cp -av $jailhouse/configs/riscv/*.cell $buildroot_root_overlay/etc/jailhouse/
	cp -av $jailhouse/configs/riscv/dts/*.dtb $buildroot_root_overlay/etc/jailhouse
	cp -av $jailhouse/inmates/demos/riscv/*.bin $buildroot_root_overlay/etc/jailhouse
	cp -av $jailhouse/inmates/tools/riscv/*.bin $buildroot_root_overlay/etc/jailhouse
	cp -av res/scripts/* $buildroot_root_overlay/usr/bin/
	cp -av res/1-jailhouse-root.network $buildroot_root_overlay/etc/systemd/network/
}

function buildroot() {
	prepare_non_root_overlay

	# Build buildroot for non-root cell
	cd $dst_buildroot_non_root
	make
	cd ../..

	prepare_root_overlay

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
		-append "mem=548M ip=dhcp" \
		-s
}

function build_initrd() {
	cd $dst_rootfs

	mkdir -p root
	cp -av $KERNEL ./root/
	cp -av ../../buildroot_non_root/images/rootfs.cpio.gz ./root/

	mkdir -p ./etc/jailhouse
	cp -av $jailhouse/configs/riscv/dts/*.dtb \
		$jailhouse/configs/riscv/*.cell \
		$jailhouse/inmates/demos/riscv/*.bin \
		$jailhouse/inmates/tools/riscv/*.bin \
		./etc/jailhouse/
	cp -av $jailhouse/driver/jailhouse.ko .
	cp -av $jailhouse/hypervisor/jailhouse.bin ./lib/firmware
	cp -av $jailhouse/tools/jailhouse ./sbin/jailhouse
	cp -av $jailhouse/tools/jailhouse-cell-stats ./sbin/jailhouse-cell-stats

	cp -av $busybox_res/rcS ./etc/init.d/rcS
	cp -av $busybox_res/fstab ./etc/fstab
	cp -av $res/scripts/* ./usr/bin/

	find . | cpio -o -H newc > $dst_f_initrd
	pigz -f $dst_f_initrd
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
		build/initrd/initramfs.cpio.gz \
		$dst_buildroot_root/images/rootfs.cpio.gz \
		$jailhouse/driver/jailhouse.ko \
		$jailhouse/hypervisor/hypervisor.o \
		$target:jailv/
}

function deploy_target() {
	prepare_root_overlay
	cd $buildroot_root_overlay
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
elif [[ $cmd == "qemu_aplic_imsic_uc" ]]; then
	QEMU_MACHINE="virt,aia=aplic-imsic,aia-guests=3"
	build_jailhouse
	#build_initrd
	start_qemu uc virt
elif [[ $cmd == "qemu_aplic_imsic_mc" ]]; then
	QEMU_MACHINE="virt,aia=aplic-imsic,aia-guests=3"
	build_jailhouse
	#build_initrd
	start_qemu mc virt
elif [[ $cmd == "qemu_plic_uc" ]]; then
	QEMU_MACHINE="virt"
	build_jailhouse
	#build_initrd
	start_qemu uc virt
elif [[ $cmd == "qemu_plic_mc" ]]; then
	QEMU_MACHINE="virt"
	build_jailhouse
	#build_initrd
	start_qemu mc virt
else
	echo "Unknown target: $cmd"
fi
