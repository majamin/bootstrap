#!/bin/bash
# Bootstrap — adapted from LARBS by Luke Smith
# Run as root on a fresh Arch install.

dotfilesrepo="https://github.com/majamin/dotfiles.git"
progsfile="$(realpath "$(dirname "$0")/packages.csv")"
aurhelper="yay"
export TERM=ansi

### FUNCTIONS ###

error() { printf "%s\n" "$1" >&2; exit 1; }

installpkg() { pacman --noconfirm --needed -S "$1" >/dev/null 2>&1; }

welcomemsg() {
	whiptail --title "Bootstrap" \
		--msgbox "This script installs the system from a post-chroot Arch environment.\n\nBefore running this, make sure you have already completed:\n  - Partitioning, formatting, pacstrap\n  - genfstab, locale, timezone, hostname\n  - Bootloader (grub) installed and configured\n  - arch-chroot /mnt\n  - An active internet connection" \
		18 65
	whiptail --title "Ready?" --yes-button "Engage!" --no-button "Cancel" \
		--yesno "The rest of the installation will run unattended.\n\nPress Engage! to begin." \
		8 60 || { clear; exit 1; }
}

getuserandpass() {
	name=$(whiptail --inputbox "Enter the username for this machine." 10 60 3>&1 1>&2 2>&3 3>&1) || exit 1
	while ! echo "$name" | grep -q "^[a-z_][a-z0-9_-]*$"; do
		name=$(whiptail --nocancel --inputbox "Invalid username. Use only lowercase letters, numbers, - or _." 10 60 3>&1 1>&2 2>&3 3>&1)
	done
	pass1=$(whiptail --nocancel --passwordbox "Password for $name:" 10 60 3>&1 1>&2 2>&3 3>&1)
	pass2=$(whiptail --nocancel --passwordbox "Retype password:" 10 60 3>&1 1>&2 2>&3 3>&1)
	while ! [ "$pass1" = "$pass2" ]; do
		unset pass2
		pass1=$(whiptail --nocancel --passwordbox "Passwords don't match. Try again:" 10 60 3>&1 1>&2 2>&3 3>&1)
		pass2=$(whiptail --nocancel --passwordbox "Retype password:" 10 60 3>&1 1>&2 2>&3 3>&1)
	done
}

adduserandpass() {
	whiptail --infobox "Creating user \"$name\"..." 7 40
	useradd -m -g wheel -s /bin/zsh "$name" >/dev/null 2>&1 ||
		usermod -aG wheel "$name"
	echo "$name:$pass1" | chpasswd
	unset pass1 pass2
}

refreshkeys() {
	whiptail --infobox "Refreshing Arch keyring..." 7 40
	pacman --noconfirm -S archlinux-keyring >/dev/null 2>&1
}

manualinstall() {
	pacman -Qq "$1" && return 0
	whiptail --infobox "Bootstrapping $1..." 7 50
	sudo -u "$name" mkdir -p "/home/$name/.local/src/$1"
	sudo -u "$name" git -C "/home/$name/.local/src" clone --depth 1 --single-branch \
		--no-tags -q "https://aur.archlinux.org/$1.git" "/home/$name/.local/src/$1" ||
		{ cd "/home/$name/.local/src/$1" && sudo -u "$name" git pull --force origin master; }
	cd "/home/$name/.local/src/$1" || exit 1
	sudo -u "$name" makepkg --noconfirm -si >/dev/null 2>&1 || return 1
}

installationloop() {
	grep -v "^#" "$progsfile" | grep -v "^$" > /tmp/packages.csv
	total=$(wc -l < /tmp/packages.csv)
	n=0
	while IFS=, read -r tag program comment; do
		n=$((n + 1))
		comment="$(echo "$comment" | sed -E 's/(^\"|\"$)//g')"
		whiptail --title "Installing packages" \
			--infobox "[$n/$total] $program\n$comment" 8 65
		case "$tag" in
			A) sudo -u "$name" $aurhelper -S --noconfirm "$program" >/dev/null 2>&1 ;;
			*) installpkg "$program" ;;
		esac
	done < /tmp/packages.csv
}

installdotfiles() {
	whiptail --infobox "Installing dotfiles..." 7 50
	# Clone as bare repo and check out into home dir
	sudo -u "$name" git clone --bare "$dotfilesrepo" "/home/$name/.dotfiles" >/dev/null 2>&1
	sudo -u "$name" git --git-dir="/home/$name/.dotfiles" --work-tree="/home/$name" \
		checkout 2>/dev/null ||
	{
		# Back up conflicting files and retry
		sudo -u "$name" git --git-dir="/home/$name/.dotfiles" --work-tree="/home/$name" \
			checkout 2>&1 | grep "^\s" | awk '{print $1}' | \
			xargs -I{} mv "/home/$name/{}" "/home/$name/{}.bak"
		sudo -u "$name" git --git-dir="/home/$name/.dotfiles" --work-tree="/home/$name" \
			checkout
	}
	sudo -u "$name" git --git-dir="/home/$name/.dotfiles" --work-tree="/home/$name" \
		config status.showUntrackedFiles no
}


enableservices() {
	whiptail --infobox "Enabling system services..." 7 50
	systemctl enable sddm
	systemctl enable NetworkManager
	systemctl enable tlp
	systemctl enable bluetooth
	systemctl enable fstrim.timer
	systemctl enable ufw
	systemctl enable syncthing@"$name"
}

sanitychecks() {
	warnings=""

	[ "$(id -u)" != "0" ] && \
		warnings="$warnings\n- Not running as root"

	[ ! -d /sys/firmware/efi ] && \
		warnings="$warnings\n- Not an EFI system (GRUB EFI install will fail)"

	ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 || \
		warnings="$warnings\n- No internet connection detected"

	[ ! -f /etc/locale.conf ] && \
		warnings="$warnings\n- /etc/locale.conf missing (locale not configured)"

	{ [ -z "$(cat /etc/hostname 2>/dev/null)" ] || \
	  [ "$(cat /etc/hostname 2>/dev/null)" = "archiso" ]; } && \
		warnings="$warnings\n- Hostname not set"

	grep -qv "^#" /etc/fstab 2>/dev/null || \
		warnings="$warnings\n- /etc/fstab is empty (genfstab not run?)"

	[ ! -L /etc/localtime ] && \
		warnings="$warnings\n- Timezone not configured (/etc/localtime not set)"

	efibootmgr 2>/dev/null | grep -qi "grub" || \
		warnings="$warnings\n- GRUB not found in EFI boot entries"

	[ ! -f /boot/grub/grub.cfg ] && \
		warnings="$warnings\n- /boot/grub/grub.cfg missing (grub-mkconfig not run?)"

	ls /boot/vmlinuz-linux* >/dev/null 2>&1 || \
		warnings="$warnings\n- No kernel found in /boot"

	ls /boot/initramfs-linux*.img >/dev/null 2>&1 || \
		warnings="$warnings\n- No initramfs found in /boot (mkinitcpio not run?)"

	if [ -n "$warnings" ]; then
		whiptail --title "Warnings — prerequisites may not be met" \
			--yes-button "Continue anyway" --no-button "Abort" \
			--yesno "The following issues were detected:$warnings\n\nSee PRE-INSTALL.md for guidance." \
			20 70 || { clear; exit 1; }
	fi
}

finalize() {
	whiptail --title "Done!" \
		--msgbox "Bootstrap complete.\n\nReboot and log in as $name.\n\nNote: SSH keys for the dotfiles remote (git@github.com) will need to be set up manually after first login." \
		12 65
}

### MAIN ###

pacman --noconfirm --needed -Sy libnewt ||
	error "Run this as root on an Arch system with an internet connection."

welcomemsg || error "Aborted."
sanitychecks
getuserandpass || error "Aborted."

[ -f /etc/sudoers.pacnew ] && cp /etc/sudoers.pacnew /etc/sudoers

# Temporary passwordless sudo for AUR builds
trap 'rm -f /etc/sudoers.d/bootstrap-temp' HUP INT QUIT TERM PWR EXIT
echo "%wheel ALL=(ALL) NOPASSWD: ALL
Defaults:%wheel,root runcwd=*" > /etc/sudoers.d/bootstrap-temp

grep -q "ILoveCandy" /etc/pacman.conf || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf
sed -i "s/-j2/-j$(nproc)/;/^#MAKEFLAGS/s/^#//" /etc/makepkg.conf

refreshkeys || error "Keyring refresh failed."

for pkg in curl ca-certificates base-devel git ntp zsh; do
	installpkg "$pkg"
done

ntpd -q -g >/dev/null 2>&1

adduserandpass || error "Failed to create user."

manualinstall $aurhelper || error "Failed to install $aurhelper."
$aurhelper -Y --save --devel

installationloop
installdotfiles
enableservices

chsh -s /bin/zsh "$name" >/dev/null 2>&1

rmmod pcspkr 2>/dev/null
echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf

rm -f /etc/sudoers.d/bootstrap-temp
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/00-wheel-sudo
echo "%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/systemctl suspend,/usr/bin/mount,/usr/bin/umount,/usr/bin/pacman -Syu,/usr/bin/pacman -Syyu,/usr/bin/brightnessctl" \
	> /etc/sudoers.d/01-nopasswd-cmds

finalize
