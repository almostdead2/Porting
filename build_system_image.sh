#!/bin/bash

# Exit immediately if any command fails.
set -e

# Configuration variables
IMAGE_SIZE_BYTES=3221225472 # Target size for the new system.img (e.g., 3GB)
FINAL_IMAGE_NAME="system_new.img" # Name of the new image file
FINAL_MOUNT_POINT="final_system_mount" # Temporary mount point for the new image

# Ensure GITHUB_WORKSPACE is set (important for GitHub Actions)
: "${GITHUB_WORKSPACE:=$(pwd)}"

echo "--- Starting Image Creation and Modification Process ---"

# Set up environment and extract firmware
echo "--- Setting up environment and extracting firmware ---"
sudo apt update
sudo apt install -y unace unrar zip unzip p7zip-full liblz4-tool brotli default-jre libarchive-tools e2fsprogs android-sdk-libsparse-utils
echo "Dependencies installed."

wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O apktool
wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O apktool.jar
chmod +x apktool apktool.jar
sudo mv apktool /usr/local/bin/
sudo mv apktool.jar /usr/local/bin/
echo "Apktool installed successfully."

if [ -z "${FIRMWARE_URL}" ]; then
  echo "Error: FIRMWARE_URL environment variable is not set. Exiting."
  exit 1
fi

FIRMWARE_FILENAME=$(basename "$FIRMWARE_URL")
echo "Downloading firmware: $FIRMWARE_URL"
curl -L --progress-bar -o "$FIRMWARE_FILENAME" "$FIRMWARE_URL"
echo "Downloaded firmware: $FIRMWARE_FILENAME"

mkdir -p firmware_extracted
echo "Extracting $FIRMWARE_FILENAME..."
if [[ "$FIRMWARE_FILENAME" == *.zip ]]; then
  unzip -q "$FIRMWARE_FILENAME" -d firmware_extracted/
elif [[ "$FIRMWARE_FILENAME" == *.rar ]]; then
  unrar x "$FIRMWARE_FILENAME" firmware_extracted/
elif [[ "$FIRMWARE_FILENAME" == *.7z ]]; then
  7z x "$FIRMWARE_FILENAME" -ofirmware_extracted/
else
  echo "Error: Unsupported firmware archive format."
  exit 1
fi
echo "Firmware extracted to firmware_extracted/"

rm "$FIRMWARE_FILENAME" || true # Clean up downloaded archive
echo "Original firmware archive removed."

# Process payload.bin if found
if [ -f firmware_extracted/payload.bin ]; then
  echo "payload.bin found. Extracting images using payload_dumper.py..."
  PAYLOAD_DUMPER_DIR="payload_dumper"
  git clone https://github.com/vm03/payload_dumper.git "$PAYLOAD_DUMPER_DIR"
  python3 -m pip install -r "$PAYLOAD_DUMPER_DIR/requirements.txt"
  python3 "$PAYLOAD_DUMPER_DIR/payload_dumper.py" firmware_extracted/payload.bin
  rm "firmware_extracted/payload.bin" || true
  rm -rf "$PAYLOAD_DUMPER_DIR" || true
  echo "Images extracted from payload.bin to ./output/"
else
  echo "payload.bin not found. Using direct image files from extracted firmware."
fi

# Consolidate images into 'firmware_images'
REQUIRED_IMAGES=("system.img" "product.img" "system_ext.img" "odm.img" "vendor.img" "boot.img")
OPTIONAL_IMAGES=("opproduct.img")
TARGET_DIR="firmware_images"
mkdir -p "$TARGET_DIR"

echo "Consolidating images to '$TARGET_DIR'..."
for img in "${REQUIRED_IMAGES[@]}" "${OPTIONAL_IMAGES[@]}"; do
  source_path=""
  if [ -f "./output/$img" ]; then
    source_path="./output/$img"
  elif [ -f "firmware_extracted/$img" ]; then
    source_path="firmware_extracted/$img"
  fi

  if [ -n "$source_path" ]; then
    mv "$source_path" "$TARGET_DIR/"
  else
    if [[ " ${REQUIRED_IMAGES[*]} " =~ " ${img} " ]]; then
      echo "Warning: Required image $img not found. This may cause issues."
      ALL_IMAGES_FOUND=false
    fi
  fi
done

rm -rf firmware_extracted/ || true
rm -rf output/ || true
echo "Images moved to $TARGET_DIR/. Temporary directories cleaned."
echo "--- Firmware extraction and setup complete ---"

# Define apps to remove
APPS_TO_REMOVE=(
  "OnePlusCamera" "Drive" "Duo" "Gmail2" "Maps" "Music2" "Photos" "GooglePay"
  "GoogleTTS" "Videos" "YouTube" "HotwordEnrollmentOKGoogleWCD9340"
  "HotwordEnrollmentXGoogleWCD9340" "Velvet" "By_3rd_PlayAutoInstallConfigOverSeas"
  "OPBackup" "OPForum"
)

# Modify, mount, and unmount a source image
# This function directly modifies the image file by mounting, deleting apps, and unmounting.
modify_and_unmount_source() {
    local img_file_name="$1"
    local source_img_path="firmware_images/${img_file_name}"
    local mount_point="temp_mount_${img_file_name%.*}"

    echo "--- Modifying ${img_file_name}: Mount > Delete Apps > Unmount ---"

    if [ ! -f "$source_img_path" ]; then
        echo "Warning: Source image file ${source_img_path} not found. Skipping modification."
        return 0
    fi

    sudo e2fsck -f -y "$source_img_path" || echo "e2fsck found minor issues but proceeded."
    sudo resize2fs "$source_img_path"
    mkdir -p "$mount_point"

    LOOP_DEV=$(sudo losetup -f --show "$source_img_path")
    if [ -z "$LOOP_DEV" ]; then
        echo "Error: Failed to assign loop device for ${source_img_path}. Cannot mount."
        exit 1
    fi

    sudo mount -t ext4 -o rw "${LOOP_DEV}" "${mount_point}"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to mount ${source_img_path} in RW mode. This indicates an issue with the image itself (e.g., corruption or not valid ext4)."
        sudo losetup -d "${LOOP_DEV}" || true
        exit 1
    fi
    echo "Mounted ${source_img_path} to ${mount_point}/."

    echo "Deleting unwanted apps from ${mount_point}/..."
    declare -a COMMON_APP_PATHS=( "${mount_point}/app" "${mount_point}/priv-app" )
    for app_name in "${APPS_TO_REMOVE[@]}"; do
      for app_path_base in "${COMMON_APP_PATHS[@]}"; do
        TARGET_DIR="$app_path_base/$app_name"
        if [ -d "$TARGET_DIR" ]; then
          sudo rm -rf "$TARGET_DIR"
          break
        fi
      done
    done
    echo "App deletion from ${img_file_name} complete."

    sync
    sudo umount "${mount_point}"
    sudo losetup -d "${LOOP_DEV}"
    rmdir "${mount_point}"
    echo "${img_file_name} modified and unmounted. Changes saved."
}

# Phase 1: Modify individual source image files
echo "--- PHASE 1: Modifying individual source image files ---"
modify_and_unmount_source "system.img"
modify_and_unmount_source "product.img"
modify_and_unmount_source "system_ext.img"
modify_and_unmount_source "odm.img"
modify_and_unmount_source "opproduct.img"

echo "--- All source image files in 'firmware_images/' are now modified. ---"

# Phase 2: Create and populate system_new.img
echo "--- PHASE 2: Creating and Populating ${FINAL_IMAGE_NAME} from modified source images ---"

echo "Creating empty ${FINAL_IMAGE_NAME} with size ${IMAGE_SIZE_BYTES} bytes..."
truncate -s ${IMAGE_SIZE_BYTES} "${FINAL_IMAGE_NAME}"
echo "File created."

echo "Formatting ${FINAL_IMAGE_NAME} as ext4 filesystem..."
sudo mkfs.ext4 -F -b 4096 "${FINAL_IMAGE_NAME}"
echo "${FINAL_IMAGE_NAME} formatted as ext4."

echo "Disabling automatic filesystem checks (fsck) for ${FINAL_IMAGE_NAME}..."
sudo tune2fs -c0 -i0 "${FINAL_IMAGE_NAME}"
echo "Automatic fsck disabled."

echo "Mounting ${FINAL_IMAGE_NAME} to ${FINAL_MOUNT_POINT}/..."
mkdir -p "${FINAL_MOUNT_POINT}"
FINAL_LOOP_DEV=$(sudo losetup -f --show "${FINAL_IMAGE_NAME}")
if [ -z "$FINAL_LOOP_DEV" ]; then
  echo "Error: Failed to assign loop device for ${FINAL_IMAGE_NAME}. Cannot mount."
  exit 1
fi
sudo mount -t ext4 -o rw "${FINAL_LOOP_DEV}" "${FINAL_MOUNT_POINT}"
if [ $? -ne 0 ]; then
  echo "Error: Failed to mount ${FINAL_IMAGE_NAME} in RW mode."
  sudo losetup -d "${FINAL_LOOP_DEV}" || true
  exit 1
fi
echo "Mounted ${FINAL_IMAGE_NAME} to ${FINAL_MOUNT_POINT}/."

# Copy modified image contents to final_system_mount
# This function mounts a modified source image (read-only) and copies its content to the final image.
copy_source_to_final() {
    local source_img_file="$1"
    local dest_subdir="$2"
    local source_img_path="firmware_images/${source_img_file}"
    local source_mount_point="copy_temp_mount_${source_img_file%.*}"

    if [ ! -f "$source_img_path" ]; then
        echo "Warning: Modified source image ${source_img_path} not found. Skipping copy."
        return 0
    fi

    echo "Copying contents from modified ${source_img_file}..."
    mkdir -p "$source_mount_point"
    local COPY_LOOP_DEV=$(sudo losetup -f --show "$source_img_path")
    if [ -z "$COPY_LOOP_DEV" ]; then
        echo "Error: Failed to assign loop device for copying ${source_img_file}. Skipping copy."
        return 1
    fi
    sudo mount -t ext4 -o ro "${COPY_LOOP_DEV}" "$source_mount_point"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to mount ${source_img_file} for copying. Skipping copy."
        sudo losetup -d "${COPY_LOOP_DEV}" || true
        return 1
    fi

    sudo mkdir -p "${FINAL_MOUNT_POINT}/${dest_subdir}"
    sudo rsync -a "${source_mount_point}/" "${FINAL_MOUNT_POINT}/${dest_subdir}/"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to copy contents from ${source_img_file}."
        sync || true
        sudo umount "${source_mount_point}" || true
        sudo losetup -d "${COPY_LOOP_DEV}" || true
        return 1
    fi
    echo "Contents copied for ${source_img_file}."

    sync
    sudo umount "${source_mount_point}"
    sudo losetup -d "${COPY_LOOP_DEV}"
    rmdir "${source_mount_point}"
    rm "$source_img_path"
}

# Call copy function for each modified source image
copy_source_to_final "system.img" ""
copy_source_to_final "system_ext.img" "system_ext"
copy_source_to_final "product.img" "product"
copy_source_to_final "odm.img" "odm"
copy_source_to_final "opproduct.img" "opproduct"

rm -rf firmware_images/ || true # Clean up firmware_images directory
echo "--- All base partitions copied to ${FINAL_IMAGE_NAME}. ---"

# Start custom modification steps
echo "--- Applying Custom Modifications to ${FINAL_IMAGE_NAME} ---"

# Replace OPWallpaperResources.apk
TARGET_APK_DIR="${FINAL_MOUNT_POINT}/system_ext/app/OPWallpaperResources"
TARGET_APK_PATH="$TARGET_APK_DIR/OPWallpaperResources.apk"
SOURCE_APK_PATH="${GITHUB_WORKSPACE}/for_OPWallpaperResources/OPWallpaperResources.apk"

echo "Replacing OPWallpaperResources.apk..."
if [ ! -d "$TARGET_APK_DIR" ]; then echo "Error: Target directory not found: $TARGET_APK_DIR"; exit 1; fi
sudo rm -f "$TARGET_APK_PATH" # Use -f for force, suppress error if not found
if [ ! -f "$SOURCE_APK_PATH" ]; then echo "Error: Custom APK not found at: $SOURCE_APK_PATH"; exit 1; fi
sudo cp "$SOURCE_APK_PATH" "$TARGET_APK_DIR/"
sudo chown 0:0 "$TARGET_APK_PATH"
sudo chmod 0644 "$TARGET_APK_PATH"
echo "OPWallpaperResources.apk replaced."

# Remove Unwanted Apps (global check)
echo "Removing unwanted apps (global check)..."
APPS_TO_REMOVE_GLOBAL=(
  "OnePlusCamera" "Drive" "Duo" "Gmail2" "Maps" "Music2" "Photos" "GooglePay"
  "GoogleTTS" "Videos" "YouTube" "HotwordEnrollmentOKGoogleWCD9340"
  "HotwordEnrollmentXGoogleWCD9340" "Velvet" "By_3rd_PlayAutoInstallConfigOverSeas"
  "OPBackup" "OPForum"
)
declare -a APP_PATHS_GLOBAL=(
  "${FINAL_MOUNT_POINT}/app" "${FINAL_MOUNT_POINT}/priv-app"
  "${FINAL_MOUNT_POINT}/product/app" "${FINAL_MOUNT_POINT}/product/priv-app"
  "${FINAL_MOUNT_POINT}/system_ext/app" "${FINAL_MOUNT_POINT}/system_ext/priv-app"
  "${FINAL_MOUNT_POINT}/reserve" "${FINAL_MOUNT_POINT}/odm/app"
  "${FINAL_MOUNT_POINT}/odm/priv-app" "${FINAL_MOUNT_POINT}/opproduct/app"
  "${FINAL_MOUNT_POINT}/opproduct/priv-app"
)
for app_name in "${APPS_TO_REMOVE_GLOBAL[@]}"; do
  for app_path_base in "${APP_PATHS_GLOBAL[@]}"; do
    TARGET_DIR="$app_path_base/$app_name"
    if [ -d "$TARGET_DIR" ]; then
      sudo rm -rf "$TARGET_DIR"
      break
    fi
  done
done
echo "Unwanted apps removal complete."

# Create empty keylayout files
KEYLAYOUT_DIR="${FINAL_MOUNT_POINT}/usr/keylayout"
sudo mkdir -p "$KEYLAYOUT_DIR"
sudo touch "$KEYLAYOUT_DIR/uinput-fpc.kl"
sudo touch "$KEYLAYOUT_DIR/uinput-goodix.kl"
echo "Keylayout files created."

# Patch services.jar
SERVICES_JAR_PATH="${FINAL_MOUNT_POINT}/system/framework/services.jar"
SMALI_DIR="services_decompiled"
SMALI_FILE="$SMALI_DIR/smali_classes2/com/android/server/wm/ActivityTaskManagerService\$LocalService.smali"

echo "Patching services.jar..."
if [ ! -f "$SERVICES_JAR_PATH" ]; then echo "Error: services.jar not found: $SERVICES_JAR_PATH"; exit 1; fi
sudo apktool d -f -r "$SERVICES_JAR_PATH" -o "$SMALI_DIR"
if [ ! -f "$SMALI_FILE" ]; then echo "Error: Smali file not found: $SMALI_FILE"; exit 1; fi

sudo sed -i '/invoke-static {}, Landroid\/os\/Build;->isBuildConsistent()Z/{n;s/    move-result v1/    move-result v1\n\n    const\/4 v1, 0x1\n/}' "$SMALI_FILE"
sudo sed -i 's/if-nez v1, :cond_42/if-nez v1, :cond_43/g' "$SMALI_FILE"
sudo sed -i 's/:cond_42/:cond_43/g' "$SMALI_FILE"
sudo sed -i 's/\(:try_end_43\)\n    .catchall {:try_start_29 .. :try_end_43} :catchall_26/\:try_end_44\n    .catchall {:try_start_29 .. :try_end_44} :catchall_26/g' "$SMALI_FILE"
sudo sed -i 's/:goto_47/:goto_48/g' "$SMALI_FILE"
sudo sed -i 's/\(:try_start_47\)\n    monitor-exit v0\n    :try_end_48/\:try_start_48\n    monitor-exit v0\n    :try_end_49/g' "$SMALI_FILE"

sudo apktool b "$SMALI_DIR" -o "$SERVICES_JAR_PATH"
sudo chown 0:0 "$SERVICES_JAR_PATH"
sudo chmod 0644 "$SERVICES_JAR_PATH"
rm -rf "$SMALI_DIR"
echo "services.jar patched."

# Modify OPSystemUI.apk
APK_PATH="${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
DECOMPILED_DIR="OPSystemUI_decompiled"
PLUGIN_SOURCE_DIR="${GITHUB_WORKSPACE}/plugin_files"

echo "Modifying OPSystemUI.apk..."
if [ ! -f "$APK_PATH" ]; then echo "Error: OPSystemUI.apk not found: $APK_PATH"; exit 1; fi
sudo apktool d -f "$APK_PATH" -o "$DECOMPILED_DIR"

OP_VOLUME_DIALOG_IMPL_FILE="$DECOMPILED_DIR/smali_classes2/com/oneplus/volume/OpVolumeDialogImpl.smali"
if [ -f "$OP_VOLUME_DIALOG_IMPL_FILE" ]; then
  sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_VOLUME_DIALOG_IMPL_FILE"
  sudo sed -i 's/const\/16 v4, 0x13/const\/16 v4, 0x15/g' "$OP_VOLUME_DIALOG_IMPL_FILE"
fi

OP_OUTPUT_CHOOSER_DIALOG_FILE="$DECOMPILED_DIR/smali_classes2/com/oneplus/volume/OpOutputChooserDialog.smali"
if [ -f "$OP_OUTPUT_CHOOSER_DIALOG_FILE" ]; then sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_OUTPUT_CHOOSER_DIALOG_FILE"; fi

VOLUME_DIALOG_IMPL_FILE="$DECOMPILED_DIR/smali/com/android/systemui/volume/VolumeDialogImpl.smali"
if [ -f "$VOLUME_DIALOG_IMPL_FILE" ]; then sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$VOLUME_DIALOG_IMPL_FILE"; fi

DOZE_SENSORS_PICKUP_CHECK_FILE="$DECOMPILED_DIR/smali/com/android/systemui/doze/DozeSensors\$PickupCheck.smali"
if [ -f "$DOZE_SENSORS_PICKUP_CHECK_FILE" ]; then sudo sed -i 's/0x1fa2652/0x1fa265c/g' "$DOZE_SENSORS_PICKUP_CHECK_FILE"; fi

DOZE_MACHINE_STATE_FILE="$DECOMPILED_DIR/smali/com/android/systemui/doze/DozeMachine\$State.smali"
if [ -f "$DOZE_MACHINE_STATE_FILE" ]; then sudo sed -i '/.method screenState/{n;s/    const\/4 v1, 0x3/    const\/4 v1, 0x2/}' "$DOZE_MACHINE_STATE_FILE"; fi

# Replace OpCustomizeSettingsG2.smali
TARGET_SMALI_DIR="$DECOMPILED_DIR/smali_classes2/com/oneplus/custom/utils"
NEW_SMALI_FILE="${GITHUB_WORKSPACE}/my_G2/for_SystemUI/OpCustomizeSettingsG2.smali"
if [ ! -d "$TARGET_SMALI_DIR" ]; then echo "Error: Target Smali directory not found for OPSystemUI: $TARGET_SMALI_DIR"; exit 1; fi
sudo rm -f "$TARGET_SMALI_DIR/OpCustomizeSettingsG2.smali"
if [ ! -f "$NEW_SMALI_FILE" ]; then echo "Error: New OpCustomizeSettingsG2.smali not found: $NEW_SMALI_FILE"; exit 1; fi
sudo cp "$NEW_SMALI_FILE" "$TARGET_SMALI_DIR/"

# Replace plugin files
PLUGIN_DEST_DIR="$DECOMPILED_DIR/smali_classes2/com/oneplus/plugin"
if [ ! -d "$PLUGIN_SOURCE_DIR" ]; then echo "Error: Source plugin directory '$PLUGIN_SOURCE_DIR' not found."; exit 1; fi
sudo rm -rf "$PLUGIN_DEST_DIR"/* || true
sudo mkdir -p "$PLUGIN_DEST_DIR"
sudo cp -r "$PLUGIN_SOURCE_DIR"/* "$PLUGIN_DEST_DIR/"

sudo apktool b "$DECOMPILED_DIR" -o "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
sudo chown 0:0 "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
sudo chmod 0644 "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
rm -rf "$DECOMPILED_DIR"
echo "OPSystemUI.apk modified."

# Modify Settings.apk
SETTINGS_APK_PATH="${FINAL_MOUNT_POINT}/system_ext/priv-app/Settings/Settings.apk"
DECOMPILED_SETTINGS_DIR="Settings_decompiled"

echo "Modifying Settings.apk..."
if [ ! -f "$SETTINGS_APK_PATH" ]; then echo "Error: Settings.apk not found: $SETTINGS_APK_PATH"; exit 1; fi
sudo apktool d -f "$SETTINGS_APK_PATH" -o "$DECOMPILED_SETTINGS_DIR"

OP_UTILS_FILE="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/settings/utils/OPUtils.smali"
if [ -f "$OP_UTILS_FILE" ]; then
  sudo sed -i -z 's/\(OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT\)/\1/g' "$OP_UTILS_FILE"
  sudo sed -i -z '
    /\.method.*OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT/ {
      :a
      n
      /    move-result v0\n\n    return v0/ {
        s/\(    move-result v0\n\n\)    const\/4 v0, 0x1\n\n    return v0/
        b end_sed_block
      }
      ba
    }
    :end_sed_block
  ' "$OP_UTILS_FILE"
fi

# Replace OpCustomizeSettingsG2.smali
TARGET_SMALI_DIR_SETTINGS="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/custom/utils"
NEW_SMALI_FILE_SETTINGS="${GITHUB_WORKSPACE}/my_G2/for_Settings/OpCustomizeSettingsG2.smali"
if [ ! -d "$TARGET_SMALI_DIR_SETTINGS" ]; then echo "Error: Target Smali directory not found for Settings: $TARGET_SMALI_DIR_SETTINGS"; exit 1; fi
sudo rm -f "$TARGET_SMALI_DIR_SETTINGS/OpCustomizeSettingsG2.smali"
if [ ! -f "$NEW_SMALI_FILE_SETTINGS" ]; then echo "Error: New OpCustomizeSettingsG2.smali not found: $NEW_SMALI_FILE_SETTINGS"; exit 1; fi
sudo cp "$NEW_SMALI_FILE_SETTINGS" "$TARGET_SMALI_DIR_SETTINGS/"

sudo apktool b "$DECOMPILED_SETTINGS_DIR" -o "$SETTINGS_APK_PATH"
sudo chown 0:0 "$SETTINGS_APK_PATH"
sudo chmod 0644 "$SETTINGS_APK_PATH"
rm -rf "$DECOMPILED_SETTINGS_DIR"
echo "Settings.apk modified."

# Prepare Reserve Partition and Create Image
OLD_RESERVE_SOURCE_DIR="${FINAL_MOUNT_POINT}/reserve"
NEW_RESERVE_WORKSPACE_DIR="${GITHUB_WORKSPACE}/reserve_new_content"
CUST_MOUNTPOINT_DIR="${FINAL_MOUNT_POINT}/cust"
SYMLINK_TARGET_DIR="${FINAL_MOUNT_POINT}/reserve"

echo "Preparing Reserve Partition..."
sudo mkdir -p "$NEW_RESERVE_WORKSPACE_DIR"
if [ -d "$OLD_RESERVE_SOURCE_DIR" ]; then sudo rsync -a "$OLD_RESERVE_SOURCE_DIR"/* "$NEW_RESERVE_WORKSPACE_DIR/"; fi

sudo chown -R 1004:1004 "$NEW_RESERVE_WORKSPACE_DIR"
find "$NEW_RESERVE_WORKSPACE_DIR" -type d -exec sudo chmod 0775 {} +
find "$NEW_RESERVE_WORKSPACE_DIR" -name "*.apk" -type f -exec sudo chmod 0664 {} +

IMAGE_SIZE_MB=830
IMAGE_SIZE_BYTES_RESERVE=$(($IMAGE_SIZE_MB * 1024 * 1024))
if command -v make_ext4fs &> /dev/null; then
  make_ext4fs -s -J -T 0 -L cust -l $IMAGE_SIZE_BYTES_RESERVE -a cust "${GITHUB_WORKSPACE}/reserve_new.img" "$NEW_RESERVE_WORKSPACE_DIR"
else
  echo "Error: 'make_ext4fs' command not found. Aborting."
  exit 1
fi
rm -rf "$NEW_RESERVE_WORKSPACE_DIR"

sudo mkdir -p "$CUST_MOUNTPOINT_DIR"
sudo rm -rf "$CUST_MOUNTPOINT_DIR"/*

sudo mkdir -p "$SYMLINK_TARGET_DIR"
sudo rm -rf "$SYMLINK_TARGET_DIR"/*

TEMP_RESERVE_MOUNT="/tmp/temp_reserve_mount"
mkdir -p "$TEMP_RESERVE_MOUNT"
TEMP_RESERVE_LOOP=$(sudo losetup -f --show "${GITHUB_WORKSPACE}/reserve_new.img")
if [ -z "$TEMP_RESERVE_LOOP" ]; then
    echo "Error: Failed to assign loop device for reserve_new.img. Cannot create symlinks."
    rmdir "$TEMP_RESERVE_MOUNT"
    exit 1
fi
sudo mount -t ext4 -o ro "$TEMP_RESERVE_LOOP" "$TEMP_RESERVE_MOUNT"
if [ $? -ne 0 ]; then
    echo "Error: Failed to mount reserve_new.img. Cannot create symlinks."
    sudo losetup -d "$TEMP_RESERVE_LOOP" || true
    rmdir "$TEMP_RESERVE_MOUNT"
    exit 1
fi

find "$TEMP_RESERVE_MOUNT" -maxdepth 1 -mindepth 1 -type d | while read -r app_folder_path; do
    dirname=$(basename "$app_folder_path")
    sudo ln -s "../../cust/$dirname" "$SYMLINK_TARGET_DIR/$dirname"
done

sudo umount "$TEMP_RESERVE_MOUNT"
sudo losetup -d "$TEMP_RESERVE_LOOP"
rmdir "$TEMP_RESERVE_MOUNT"
echo "Reserve partition prepared."
echo "--- Custom modifications complete. ---"

# Finalize system_new.img
echo "--- Finalizing ${FINAL_IMAGE_NAME} ---"
sync
sudo umount "$FINAL_MOUNT_POINT"
sudo losetup -d "$FINAL_LOOP_DEV"
rmdir "$FINAL_MOUNT_POINT"
echo "Successfully created and unmounted ${FINAL_IMAGE_NAME}."

echo "--- Script execution complete ---"
