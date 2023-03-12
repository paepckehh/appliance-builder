#!/bin/sh
if [ -e /var/lock.ssh.global ]; then exit; fi
touch /var/lock.ssh.global
. /etc/rc.conf
. /etc/ssh/airgap-client-ed25519/.init.conf
. /etc/ssh/airgap-client-ed25519/.init.keys
SSHCMD=/usr/bin/ssh
$SSHCMD -V
if [ $(ifconfig $NIC_L_IF | grep status | sha224) = 55fac085fcdbc2e3d9cc033ee9b94bd51f531683a1134ffd00eee4af ]; then
	echo "[ssh] [client] [fail]  $NIC_L_IF -> status: down (no carrier) "
	rm -rf /var/lock.ssh.global
	exit 1
fi

case $1 in
sh | zsh | bash | fish)
	SSH_TARGET_USER=$1
	;;
*)
	SSH_TARGET_USER="zsh"
	echo "[ssh] [client] invalid or no target user specified, fallback to default: zsh"
	;;
esac

test_lockdown_key() {
	SYSKEY_READ="INVALID"
	SYSKEY_CURR=$(echo "$(date "+%Y%m%d" | sha256)$(uname -a | sha256)$(echo "SHARED-SALT-CODE" | sha256)" | sha512)
	if [ -f /var/init.ssh_client_hw_lockdown_key ]; then SYSKEY_READ=$(cat /var/init.ssh_client_hw_lockdown_key); fi
	case $SYSKEY_CURR in
	$SYSKEY_READ)
		echo "[ssh] [client] session init"
		if [ ! -e /var/init.ssh_servertime_sync ]; then adjust_sstime; fi
		if [ "$(sysctl -n kern.securelevel)" != "4" ]; then
			echo "############################################"
			echo "# system integrity damaged - shutdown now! #"
			echo "############################################"
			shutdown -h NOW
		fi
		rm -f /var/lock.ssh.global
		echo "[ssh] [client] interactive session startup"
		/usr/sbin/jexec -U sshclient sshclient $SSHCMD -4akxy \
			-B $NIC_L_IF \
			-b $NIC_L_IP \
			-i /etc/ssh/airgap-client-ed25519/id_ed25519 \
			-m hmac-sha2-512-etm@openssh.com \
			-c chacha20-poly1305@openssh.com \
			-o MACs=hmac-sha2-512-etm@openssh.com \
			-o Ciphers=chacha20-poly1305@openssh.com \
			-o KexAlgorithms=curve25519-sha256 \
			-o PubkeyAcceptedKeyTypes=ssh-ed25519 \
			-o UserKnownHostsFile=/etc/ssh/airgap-client-ed25519/known_hosts \
			-o StrictHostKeyChecking=yes \
			-o UpdateHostKeys=no \
			-o User=$SSH_TARGET_USER \
			-o HashKnownHosts=yes \
			-o LogLevel=DEBUG1 \
			-o ServerAliveInterval=120 \
			-o ServerAliveCountMax=3 \
			-o TCPKeepAlive=no \
			-o Tunnel=no \
			-o VisualHostKey=no \
			-o Compression=no \
			-o VerifyHostKeyDNS=no \
			-o AddKeysToAgent=no \
			-o ForwardAgent=no \
			-o ClearAllForwardings=yes \
			-o IdentitiesOnly=yes \
			-o IdentityAgent=none \
			-p $SSH_TARGET_PORT $SSH_TARGET_IP
		exit
		;;
	*)
		echo "[ssh] [client] [lockdown] init"
		if [ -e /var/init.ssh_client_hw_lockdown_key ]; then rm -rf /var/init.ssh_client_hw_lockdown_key; fi
		if [ -e /var/init.ssh_servertime_sync ]; then rm -rf /var/init.ssh_servertime_sync; fi
		if [ -x /usr/bin/wg ]; then start_wg0; fi
		adjust_sstime
		mkdir -p /.worker/sshclient/var/sshclient/etc/ssh
		mount -t unionfs /.worker/sshclient/var/sshclient/etc/ssh /.worker/sshclient/etc/ssh
		chown -R sshclient:sshclient /.worker/sshclient/etc/ssh
		chmod -R u=rX,g=rX,o= /.worker/sshclient/etc/ssh
		SYSKEY_CURR=$(echo "$(date "+%Y%m%d" | sha256)$(uname -a | sha256)$(echo "SHARED-SALT-CODE" | sha256)" | sha512)
		echo $SYSKEY_CURR > /var/init.ssh_client_hw_lockdown_key
		test_lockdown_key
		exit
		;;
	esac
}
start_wg0() {
	echo "[ssh] [client] startup interface wg0 on $NIC_L_IF / $NIC_L_IP to $SSH_TARGET_IP"
	/usr/bin/ifconfig wg0 down > /dev/null 2>&1
	/usr/bin/ifconfig wg0 destroy > /dev/null 2>&1
	/usr/bin/ifconfig wg0 create
	/usr/bin/ifconfig wg0 description "wireguard tunnel via $NIC_L_IF / $NIC_L_IP to $SSH_TARGET_IP"
	/usr/bin/wg setconf wg0 /etc/wg/sshc.ini
	/usr/bin/ifconfig wg0 inet 192.168.250.11 netmask 255.255.255.0 broadcast 192.168.250.255
	/usr/bin/ifconfig wg0 up
	/usr/bin/ifconfig wg0 debug
}
test_arch() {
	SYSKEY_SSID="$(sysctl -b kern.build_id | sha224)"
	echo "[ssh] [client] jump source id: $SYSKEY_SSID"
	case "$(uname -m)" in
	arm)
		echo "[ssh] [client] generic arm32 ssh client plattform detected!"
		case $SYSKEY_SSID in
		$C32_01 | $C32_02 | $C32_03)
			echo "[ssh] [client] secure arm32 client build detected, starting ossp key assembly procedure!"
			beep INF
			sleep 10
			/usr/bin/hq /etc/.shadow/.init.geli.arm32.keygen.hqx
			/usr/bin/hq /etc/.shadow/.init.hqx
			;;
		esac
		;;
	arm64)
		echo "[ssh] [client] generic arm64 ssh client plattform detected!"
		case $SYSKEY_SSID in
		$C64_01)
			echo "[ssh] [client] secure arm64 client build detected, starting ossp key assembly procedure!"
			beep INF
			sleep 10
			/usr/bin/hq /etc/.shadow/.init.geli.arm64.keygen.hqx
			/usr/bin/hq /etc/.shadow/.init.hqx
			;;
		esac
		;;

	*)
		echo "[ssh] [client] [fail] unknown, unsecure or remote ssh client architecture dectected!"
		exit
		;;

	esac
}
adjust_sstime() {
	echo "[ssh] [client] [timeservice] trying to align client time via trusted server/key!"
	date $($SSHCMD -4akxy \
		-B $NIC_L_IF \
		-b $NIC_L_IP \
		-m hmac-sha2-512-etm@openssh.com \
		-c chacha20-poly1305@openssh.com \
		-i /etc/ssh/airgap-client-ed25519/id_ed25519 \
		-o MACs=hmac-sha2-512-etm@openssh.com \
		-o Ciphers=chacha20-poly1305@openssh.com \
		-o KexAlgorithms=curve25519-sha256 \
		-o PubkeyAcceptedKeyTypes=ssh-ed25519 \
		-o UserKnownHostsFile=/etc/ssh/airgap-client-ed25519/known_hosts \
		-o StrictHostKeyChecking=yes \
		-o UpdateHostKeys=no \
		-o User=$SSH_TARGET_USER \
		-o HashKnownHosts=yes \
		-o LogLevel=DEBUG1 \
		-o ServerAliveInterval=0 \
		-o ServerAliveCountMax=0 \
		-o TCPKeepAlive=no \
		-o Tunnel=no \
		-o VisualHostKey=no \
		-o Compression=no \
		-o VerifyHostKeyDNS=no \
		-p $SSH_TARGET_PORT $SSH_TARGET_IP date "+%Y%m%d%H%M.%S")
	echo "[ssh] [client] [timeservice] initial configuration done! Sending system into kernel secure lockdown mode [4] now!"
	sysctl kern.securelevel=4
	touch /var/init.ssh_servertime_sync
}

test_arch
test_lockdown_key
##########################################################################'
