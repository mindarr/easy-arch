#!/usr/bin/env bash

set -e  # Exit script on error
set -x  # Enable verbose mode for debugging

# Variabili configurabili
DISK="/dev/nvme1n1"
HOSTNAME="hostname"
LOCALE_LANG="en_GB.UTF-8"
LOCALE_OTHER="it_IT.UTF-8"
TIMEZONE="Europe/Rome"
KEYMAP="it"
ROOT_PASSWORD="rockstar"
USER_NAME="ioan"
USER_PASSWORD="rockstar"

# Funzione per convertire input in MB
convert_to_mb() {
    local size="$1"
    local unit="${size: -1}"
    local value="${size%?}"

    if [[ "$unit" == "G" || "$unit" == "g" ]]; then
        echo $((value * 1024))
    elif [[ "$unit" == "M" || "$unit" == "m" ]]; then
        echo "$value"
    else
        echo "Invalid size format. Please use G (for GB) or M (for MB)."
        exit 1
    fi
}

# Input dimensioni partizioni
echo "Specify the size for each partition (use format <size>[G|M]):"

read -p "EFI Partition Size (default 1G): " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-1G}  # Default to 1G if not provided
EFI_SIZE_MB=$(convert_to_mb "$EFI_SIZE")

read -p "Root Partition Size (default 100G): " ROOT_SIZE
ROOT_SIZE=${ROOT_SIZE:-100G}  # Default to 100G if not provided
ROOT_SIZE_MB=$(convert_to_mb "$ROOT_SIZE")

read -p "Home Partition Size (default remaining space): " HOME_SIZE
if [[ -z "$HOME_SIZE" ]]; then
    HOME_SIZE_MB=0  # Use remaining space if not provided
else
    HOME_SIZE_MB=$(convert_to_mb "$HOME_SIZE")
fi

# Make sure we are root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi

# Verify if the disk exists and is a block device
if [ ! -b "$DISK" ]; then
  echo "Error: $DISK is not a valid block device. Please check the device path and try again."
  exit 1
fi

# Double-check with the user before proceeding with destructive operations
echo "WARNING: This script will wipe and partition $DISK."
echo "All data on $DISK will be permanently deleted."
read -p "Are you sure you want to continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Operation aborted by the user."
  exit 1
fi

# Clear existing partition tables to avoid signature conflicts
echo "Wiping existing partition tables on $DISK..."
wipefs -a "$DISK"

# Use dd to clear the first 1MB of the disk (be cautious with dd!)
echo "Clearing the first 1MB of $DISK using dd..."
read -p "This will permanently destroy any existing data on $DISK. Type 'yes' to continue: " dd_confirm
if [[ "$dd_confirm" != "yes" ]]; then
  echo "dd operation aborted by the user."
  exit 1
fi
dd if=/dev/zero of="$DISK" bs=1M count=1

# Partition the main disk using fdisk
echo "Partitioning $DISK using fdisk..."
(
echo g  # Create a new GPT partition table
echo n  # New partition for EFI
echo 1  # Partition number 1
echo    # Default - start at beginning of disk
echo "+${EFI_SIZE_MB}M"  # EFI partition size in MB
echo n  # New partition for root
echo 2  # Partition number 2
echo    # Default - start immediately after previous partition
echo "+${ROOT_SIZE_MB}M"  # Root partition size in MB
echo n  # New partition for home
echo 3  # Partition number 3
echo    # Default - start immediately after previous partition
if [[ "$HOME_SIZE_MB" -gt 0 ]]; then
    echo "+${HOME_SIZE_MB}M"  # Home partition size in MB
else
    echo    # Use the rest of the disk
fi
echo t  # Change partition type for partition 1
echo 1  # Select partition 1
echo 1  # Set type to EFI (code 1)
echo w  # Write changes
) | fdisk "$DISK"

# Create the filesystems
echo "Creating filesystems..."
mkfs.fat -F32 "${DISK}p1"  # EFI partition
mkfs.ext4 "${DISK}p2"  # Root partition
mkfs.ext4 "${DISK}p3"  # Home partition

# Mount the partitions
echo "Mounting the partitions..."
mount "${DISK}p2" /mnt  # Mount root
mkdir /mnt/boot
mount "${DISK}p1" /mnt/boot  # Mount EFI
mkdir /mnt/home
mount "${DISK}p3" /mnt/home  # Mount home

# Ensure /mnt/etc directory exists
mkdir -p /mnt/etc

# Install the base system and required packages
echo "Installing the base system and packages..."
pacstrap /mnt base linux linux-firmware linux-lts linux-lts-headers linux-headers plasma-meta konsole kwrite dolphin ark plasma-workspace egl-wayland partitionmanager kio-admin git nano firefox dosfstools base-devel grub efibootmgr mtools networkmanager os-prober sudo

# Generate the fstab
echo "Generating the fstab for main partitions..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot into the new system
echo "Chrooting into the new system..."
arch-chroot /mnt /bin/bash << EOF

# Network settings
echo "Configuring network..."
hostnamectl set-hostname $HOSTNAME

# Set the locales
echo "Setting locales..."
echo "$LOCALE_LANG UTF-8" >> /etc/locale.gen
echo "$LOCALE_OTHER UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE_LANG" > /etc/locale.conf

# Set the timezone
echo "Setting timezone..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Configure the keyboard layout
echo "Configuring keyboard layout..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set the root password
echo "Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd

# Create a non-root user with the same password
echo "Creating a new user '$USER_NAME'..."
useradd -m -G wheel -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

# Configure sudo for user '$USER_NAME'
echo "Configuring sudo..."
echo "$USER_NAME ALL=(ALL) ALL" >> /etc/sudoers.d/$USER_NAME
chmod 440 /etc/sudoers.d/$USER_NAME

# Enable the multilib repository
echo "Enabling the multilib repository..."
echo "[multilib]" >> /etc/pacman.conf
echo "Include = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf

# Update packages and install drivers
echo "Updating packages and installing Mesa drivers..."
pacman -Sy --needed
pacman -S --needed mesa lib32-mesa nvidia-dkms nvidia-utils lib32-nvidia-utils lib32-gtk3 lib32-libx11

# Add NVIDIA modules to mkinitcpio
echo "Adding NVIDIA modules to mkinitcpio..."
echo "MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" >> /etc/mkinitcpio.conf

# Remove KMS from hooks in mkinitcpio
echo "Removing KMS from hooks in mkinitcpio..."
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf

# Regenerate the initramfs
echo "Regenerating the initramfs..."
mkinitcpio -P

# Add nvidia_drm.modeset=1 and nvidia-drm.fbdev=1 to GRUB
echo "Adding nvidia_drm.modeset=1 and nvidia-drm.fbdev=1 to GRUB..."
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\\1 nvidia_drm.modeset=1 nvidia-drm.fbdev=1"/' /etc/default/grub

# Monta la partizione EFI
mount "${DISK}p1" /boot

# Install the bootloader (GRUB)
echo "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Enable SDDM (KDE display manager)
echo "Enabling SDDM..."
systemctl enable sddm

# Enable NetworkManager
systemctl enable NetworkManager

EOF

# Unmount and reboot
echo "Unmounting partitions and rebooting..."
umount -R /mnt
sleep5
reboot
