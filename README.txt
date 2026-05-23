=== bootstrap ===

Bootstrap a system using Arch Linux and my dotfiles.

Usage
=====

From a fresh Arch install, after partitioning and pacstrap:

  1. Read PRE-INSTALL.md and complete all steps
  2. arch-chroot /mnt
  3. Copy or `git clone` this directory into the chroot
  4. bash install.sh

Files
=====

  install.sh        Main bootstrap script
  packages.csv      Package list (pacman + AUR)
  PRE-INSTALL.md    Pre-requisite steps (partitioning, locale, bootloader)
