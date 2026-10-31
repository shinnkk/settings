set -euo pipefail

get_microcode_package() {
    local vendor
    vendor=$(LC_ALL=C lscpu | awk '/Vendor ID/ {print $3}')

    case "$vendor" in
        GenuineIntel)
            printf '%s\n' "intel-ucode"
            ;;
        AuthenticAMD)
            printf '%s\n' "amd-ucode"
            ;;
        *)
            return 1
            ;;
    esac
}

set_password() {
    local prompt="$1"
    local pw1
    local pw2

    while true; do
        printf '%s: ' "$prompt" >&2
        IFS= read -r -s pw1
        printf '\n' >&2

        if [[ -z "$pw1" ]]; then
            printf 'Password must not be empty.\n' >&2
            continue
        fi

        printf 'Retype %s: ' "$prompt" >&2
        IFS= read -r -s pw2
        printf '\n' >&2

        if [[ "$pw1" == "$pw2" ]]; then
            printf '%s' "$pw1"
            printf '%s updated successfully\n' "$prompt" >&2
            break
        fi

        printf 'Passwords do not match. Try again.\n' >&2
    done
}


cleanup() {
    local status=0

    if mountpoint -q /mnt; then
        if ! umount -R /mnt; then
            echo "Failed to unmount /mnt" >&2
            status=1
        fi
    fi

    if cryptsetup status "$cryptname" >/dev/null 2>&1; then
        if ! cryptsetup close "$cryptname"; then
            echo "Failed to close $cryptname" >&2
            status=1
        fi
    fi

    return "$status"
}


on_exit() {
    local status=$?

    trap - EXIT

    if [[ -n "$yay_pkg_path" ]]; then
        rm -rf -- "/mnt${yay_pkg_path}"
    fi

    if ! cleanup; then
        (( status != 0 )) || status=1
    fi

    exit "$status"
}

trap on_exit EXIT



# Initialize
cleanup

loadkeys "$kb_layout"

luks_password=$(set_password "LUKS password")
user_password=$(set_password "User password")

while true; do
    printf '\nWarning: Selected disk %s will be erased. Confirm the disk name then type YES.\n' "$disk"

    text=""
    IFS= read -r text

    if [[ "$text" == [Yy][Ee][Ss] ]]; then
        break
    fi
done



# System Config
# Time adjustment
timedatectl set-ntp true

# Partitioning
sgdisk --zap-all "$disk"
sgdisk --new=1:0:+1G --typecode=1:EF00 "$disk"
sgdisk --new=2:0:0 --typecode=2:8309 "$disk"

partprobe "$disk"
udevadm settle

# Formatting the ESP
esp_guid='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
esp=$(lsblk -rno PATH,PARTTYPE "$disk" | awk -v guid="$esp_guid" '$2 == guid {print $1; exit}')

mkfs.fat -F32 "$esp"

# Encryption
luks_guid='ca7d7ccb-63ed-4c53-861c-1742536059cc'
root_partition=$(lsblk -rno PATH,PARTTYPE "$disk" | awk -v guid="$luks_guid" '$2 == guid {print $1; exit}')

printf '%s' "$luks_password" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$root_partition"

printf '%s' "$luks_password" | cryptsetup open --key-file=- "$root_partition" "$cryptname"

# Formatting the root file system
mkfs.ext4 "/dev/mapper/$cryptname"

# Mounting partitions
mount "/dev/mapper/$cryptname" "/mnt"
mount --mkdir "$esp" "/mnt/efi"

# Selecting up server mirrors
# worldwideに変更
reflector --country $(IFS=,; printf '%s' "${countries[*]}") --protocol https --age 24 --sort rate --number 10 --save /etc/pacman.d/mirrorlist

# Package installation
if microcode_package=$(get_microcode_package); then
    packages+=("$microcode_package")
fi
pacstrap -K /mnt "${packages[@]}"

# fstab
genfstab -U /mnt > /mnt/etc/fstab

# Time zone
arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$timezone" "/etc/localtime"

# Hardware clock
arch-chroot /mnt hwclock --systohc --utc

# Enable timedatectl
arch-chroot /mnt systemctl enable systemd-timesyncd.service

# locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

# Keymap
echo KEYMAP="$kb_layout" > /mnt/etc/vconsole.conf

# Hostname
echo "$hostname" > /mnt/etc/hostname

# Network
arch-chroot /mnt systemctl enable NetworkManager

# Enable trim
printf '%s' "$luks_password" |  cryptsetup --allow-discards --persistent refresh --key-file=- "$cryptname"
arch-chroot /mnt systemctl enable fstrim.timer

# tlp
arch-chroot /mnt systemctl enable tlp.service
arch-chroot /mnt systemctl enable NetworkManager-dispatcher.service
arch-chroot /mnt systemctl mask systemd-rfkill.service systemd-rfkill.socket

cat > /mnt/etc/tlp.conf <<EOF
START_CHARGE_THRESH_BAT0=0
STOP_CHARGE_THRESH_BAT0="$battery_max"
EOF

# cups
arch-chroot /mnt systemctl enable cups.service

# Firewall
arch-chroot /mnt systemctl enable nftables.service

# Bluetooth
arch-chroot /mnt systemctl enable bluetooth

# Setting up pacman
arch-chroot /mnt systemctl enable paccache.timer
sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
arch-chroot /mnt systemctl enable reflector.timer

cat > /mnt/etc/xdg/reflector/reflector.conf <<EOF
--save /etc/pacman.d/mirrorlist
--country $(IFS=,; printf '%s' "${countries[*]}")
--protocol https
--age 24
--sort rate
--number 10
EOF

# Setting HOOKS
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf

# kernel command line
luks_uuid=$(cryptsetup luksUUID "$root_partition")

cat > /mnt/etc/kernel/cmdline <<EOF
rd.luks.name=${luks_uuid}=${cryptname} rd.luks.options=${luks_uuid}=tpm2-device=auto root=/dev/mapper/${cryptname} rw
EOF

# Enable UKI
sed -i 's/^default_image=/#default_image=/' /mnt/etc/mkinitcpio.d/linux.preset
sed -i 's|^#default_uki=.*|default_uki="/efi/EFI/Linux/arch-linux.efi"|' /mnt/etc/mkinitcpio.d/linux.preset

# Creating a UKI directory
mkdir -p /mnt/efi/EFI/Linux

# UKIの署名の設定
cat > /mnt/etc/kernel/uki.conf <<EOF
[PCRSignature:initrd]
Phases=enter-initrd
PCRPrivateKey=/etc/systemd/tpm2-pcr-private-key-initrd.pem
PCRPublicKey=/etc/systemd/tpm2-pcr-public-key-initrd.pem
EOF

# UKIのPCR署名鍵の生成
arch-chroot /mnt ukify genkey --config=/etc/kernel/uki.conf

# Generating initramfsとUKIの生成
arch-chroot /mnt mkinitcpio -P

# Secure Boot用の鍵を生成
arch-chroot /mnt sbctl create-keys

# UKIにSecure Bootを署名
arch-chroot /mnt sbctl sign -s /efi/EFI/Linux/arch-linux.efi

# Setting boot entry
esp_partition_number=$(lsblk -no PARTN "$esp")

efibootmgr \
    --create \
    --disk "$disk" \
    --part "$esp_partition_number" \
    --label "$hostname" \
    --loader '\EFI\Linux\arch-linux.efi' \
    --unicode



# User Config
#Adding User
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh "$username"

# Setting up password
printf '%s:%s\n' "$username" "$user_password" | arch-chroot /mnt chpasswd

# sudoを設定
cat > /mnt/etc/sudoers.d/10-wheel <<EOF
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /mnt/etc/sudoers.d/10-wheel
arch-chroot /mnt visudo -cf /etc/sudoers

# rootの無効化
arch-chroot /mnt passwd -l root

# zsh
for file in "$zshrc_path" "$zprofile_path"; do
    if [[ -f "$file" ]]; then
        dest="/home/$username/${file##*/}"

        install -m 644 "$file" "/mnt$dest"

        arch-chroot /mnt chown "$username:$username" "$dest"
    fi
done

# yay
yay_pkg_path=$(arch-chroot /mnt runuser -u "$username" -- mktemp -d "/home/$username/yay-build.XXXXXX")
arch-chroot /mnt runuser -u "$username" -- git clone https://aur.archlinux.org/yay.git "$yay_pkg_path"
arch-chroot /mnt runuser -u "$username" -- makepkg -D "$yay_pkg_path" --noconfirm
yay_built_path=("/mnt${yay_pkg_path}"/yay-[0-9]*-*.pkg.tar.zst)
arch-chroot /mnt pacman -U --noconfirm "${yay_built_path[0]#/mnt}"
rm -rf -- "/mnt${yay_pkg_path}"

if (( ${#aur_packages[@]} > 0 )); then
    arch-chroot /mnt runuser -u "$username" -- \
        yay -S --noconfirm \
        --answerclean None \
        --answerdiff None \
        "${aur_packages[@]}"
fi



# Installing a script to enable secure boot on the next boot
# setup modeがONの時にサービスを実行
# setting.shは起動時に実行するスクリプト
cat > /mnt/etc/systemd/system/set-secure-boot.service <<EOF
[Unit]
ConditionPathExists=/root/set-secure-boot.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /root/set-secure-boot.sh
ExecStartPost=/bin/systemctl disable set-secure-boot.service
ExecStartPost=/bin/rm -f /root/set-secure-boot.sh
ExecStartPost=/bin/rm -f /etc/systemd/system/set-secure-boot.service

[Install]
WantedBy=multi-user.target
EOF

arch-chroot /mnt systemctl enable set-secure-boot.service

cat > /mnt/root/set-secure-boot.sh <<'EOF'
#!/bin/bash
set -euo pipefail

reference_path="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"

if [ "$(od -An -tu1 -j4 -N1 "$reference_path" | tr -d '[:space:]')" = "1" ]; then
    sbctl enroll-keys -m
else
    exit 1
fi
EOF

# TPM2を設定するための処理のフック
cat > /mnt/etc/systemd/system/set-tpm2.service <<EOF
[Unit]
ConditionPathExists=/root/set-tpm2.sh
ConditionPathExists=!/root/set-secure-boot.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /root/set-tpm2.sh /dev/disk/by-uuid/${luks_uuid}
ExecStartPost=/bin/systemctl disable set-tpm2.service
ExecStartPost=/bin/rm -f /root/set-tpm2.sh
ExecStartPost=/bin/rm -f /etc/systemd/system/set-tpm2.service

[Install]
WantedBy=multi-user.target
EOF

arch-chroot /mnt systemctl enable set-tpm2.service

cat > /mnt/root/set-tpm2.sh <<'EOF'
#!/bin/bash
set -euo pipefail

reference_path="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

if [ "$(od -An -tu1 -j4 -N1 "$reference_path" | tr -d '[:space:]')" = "1" ]; then
    systemd-cryptenroll \
        --wipe-slot=tpm2 \
        --tpm2-device=auto \
        --tpm2-pcrs=7 \
        --tpm2-public-key=/etc/systemd/tpm2-pcr-public-key-initrd.pem \
        --tpm2-public-key-pcrs=11 \
        "$1"
else
    exit 1
fi
EOF

# Reboot
cleanup

printf '%s\n' \
    '' \
    'Installation is complete.' \
    'After removing the installation USB drive, type YES to reboot into the firmware setup.' \
    'If you press any other key, the script will exit.'

text=""
IFS= read -r text

if [[ "$text" == [Yy][Ee][Ss] ]]; then
    systemctl reboot --firmware-setup
else
    exit 0
fi
