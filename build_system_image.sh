#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration Variables ---
IMAGE_SIZE_BYTES=3221225472 # Target size for your new system.img (e.g., 3GB)
FINAL_IMAGE_NAME="system_new.img" # The name of the new image file
FINAL_MOUNT_POINT="final_system_mount" # Temporary mount point for the new image

# Ensure GITHUB_WORKSPACE is set if running locally outside GitHub Actions for testing
# In GitHub Actions, GITHUB_WORKSPACE is automatically set to the repository root.
: "${GITHUB_WORKSPACE:=$(pwd)}"

echo "--- Starting Comprehensive Image Creation and Modification Process ---"

# --- PART 1: Firmware Extraction and Environment Setup (Originally in .yml) ---

echo "--- Setting up environment and extracting firmware ---"

# Install Dependencies (Moved from .yml to ensure script self-sufficiency)
echo "Updating apt package list and installing necessary tools..."
sudo apt update
sudo apt install -y unace unrar zip unzip p7zip-full liblz4-tool brotli default-jre
sudo apt install -y libarchive-tools # For bsdtar etc.
sudo apt install -y e2fsprogs # For mkfs.ext4, tune2fs, used for image manipulation
echo "Dependencies installed."

# Apktool installation
echo "Installing Apktool..."
wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O apktool
wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O apktool.jar
chmod +x apktool apktool.jar
sudo mv apktool /usr/local/bin/
sudo mv apktool.jar /usr/local/bin/
echo "Apktool installed successfully."

# Assuming FIRMWARE_URL is passed as an environment variable or manually set here for local testing
# For GitHub Actions, this would typically come from workflow_dispatch inputs.
# Example for local testing (uncomment and replace with a real URL):
# FIRMWARE_URL="https://example.com/your_oneplus_firmware.zip"
if [ -z "${FIRMWARE_URL}" ]; then
  echo "Error: FIRMWARE_URL environment variable is not set. Please set it or uncomment in script for local testing."
  exit 1
fi

FIRMWARE_FILENAME=$(basename "$FIRMWARE_URL")
echo "Downloading firmware from: $FIRMWARE_URL"
wget --show-progress "$FIRMWARE_URL" -O "$FIRMWARE_FILENAME"
if [ ! -f "$FIRMWARE_FILENAME" ]; then
  echo "Error: Firmware download failed."
  exit 1
fi
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

if [ ! -d "firmware_extracted" ] || [ -z "$(ls -A firmware_extracted)" ]; then
    echo "Error: Firmware extraction failed or directory is empty."
    exit 1
fi
echo "Firmware extracted to firmware_extracted/"

# --- Cleanup 1: Remove downloaded firmware archive immediately after extraction ---
echo "--- Cleanup: Removing original firmware archive to save space ---"
if [ -f "$FIRMWARE_FILENAME" ]; then
  rm "$FIRMWARE_FILENAME"
  echo "Removed $FIRMWARE_FILENAME."
fi
echo "--- Cleanup Complete ---"

if [ -f firmware_extracted/payload.bin ]; then
  echo "payload.bin found. Extracting images using payload_dumper.py from vm03/payload_dumper.git..."

  PAYLOAD_DUMPER_DIR="payload_dumper"

  echo "Cloning https://github.com/vm03/payload_dumper.git into $PAYLOAD_DUMPER_DIR..."
  git clone https://github.com/vm03/payload_dumper.git "$PAYLOAD_DUMPER_DIR"
  if [ ! -d "$PAYLOAD_DUMPER_DIR" ]; then
    echo "Error: Failed to clone vm03/payload_dumper repository."
    exit 1
  fi

  if [ -f "$PAYLOAD_DUMPER_DIR/requirements.txt" ]; then
    echo "Installing payload_dumper requirements from $PAYLOAD_DUMPER_DIR/requirements.txt..."
    python3 -m pip install -r "$PAYLOAD_DUMPER_DIR/requirements.txt"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to install payload_dumper requirements."
      rm -rf "$PAYLOAD_DUMPER_DIR"
      exit 1
    fi
  else
    echo "Warning: No requirements.txt found in $PAYLOAD_DUMPER_DIR. Skipping pip install for this repo."
  fi

  echo "Running payload_dumper.py from $PAYLOAD_DUMPER_DIR/payload_dumper.py..."
  python3 "$PAYLOAD_DUMPER_DIR/payload_dumper.py" firmware_extracted/payload.bin
  
  if [ $? -ne 0 ]; then
      echo "Error: payload_dumper.py failed to extract images."
      rm -rf "$PAYLOAD_DUMPER_DIR"
      exit 1
  fi
  
  echo "Images extracted from payload.bin to ./output/"
  rm -rf "$PAYLOAD_DUMPER_DIR"
else
  echo "payload.bin not found. Proceeding with direct image files from extracted firmware (if any)."
fi

  # --- Cleanup 2: Remove payload.bin and payload_dumper directory after use ---
  echo "--- Cleanup: Removing payload.bin and payload_dumper directory ---"
if [ -f "firmware_extracted/payload.bin" ]; then
    rm "firmware_extracted/payload.bin"
    echo "Removed firmware_extracted/payload.bin."
  fi
  if [ -d "$PAYLOAD_DUMPER_DIR" ]; then
    rm -rf "$PAYLOAD_DUMPER_DIR"
    echo "Removed payload_dumper directory."
  fi
    echo "--- Cleanup Complete ---"
else
    echo "payload.bin not found. Proceeding with direct image files from extracted firmware (if any)."
fi

REQUIRED_IMAGES=("system.img" "product.img" "system_ext.img" "odm.img" "vendor.img" "boot.img")
OPTIONAL_IMAGES=("opproduct.img")
ALL_IMAGES_FOUND=true
TARGET_DIR="firmware_images"
mkdir -p "$TARGET_DIR"

echo "Consolidating and selecting required images..."
for img in "${REQUIRED_IMAGES[@]}"; do
  if [ -f "./output/$img" ]; then
    echo "Found $img in ./output/"
    mv "./output/$img" "$TARGET_DIR/"
  elif [ -f "firmware_extracted/$img" ]; then
    echo "Found $img in firmware_extracted/"
    mv "firmware_extracted/$img" "$TARGET_DIR/"
  else
    echo "Warning: Required image $img not found in ./output/ or firmware_extracted/."
    ALL_IMAGES_FOUND=false
  fi
done

for img in "${OPTIONAL_IMAGES[@]}"; do
  if [ -f "./output/$img" ]; then
    echo "Found optional image $img in ./output/"
    mv "./output/$img" "$TARGET_DIR/"
  elif [ -f "firmware_extracted/$img" ]; then
    echo "Found optional image $img in firmware_extracted/"
    mv "firmware_extracted/$img" "$TARGET_DIR/"
  else
    echo "Optional image $img not found."
  fi
done

rm -rf firmware_extracted/*
rm -rf output/ || true
echo "Only relevant images moved to $TARGET_DIR/. Others cleaned up."

if ! $ALL_IMAGES_FOUND; then
  echo "Error: One or more required images were not found. Exiting."
  exit 1
fi
echo "--- Firmware extraction and setup complete ---"

# --- PART 2: Image Creation and Modifications (Consolidated) ---

echo "--- Starting Image Creation Process ---"

# 1. Create and Format the empty system_new.img file
echo "Creating empty ${FINAL_IMAGE_NAME} with size ${IMAGE_SIZE_BYTES} bytes..."
truncate -s ${IMAGE_SIZE_BYTES} "${FINAL_IMAGE_NAME}"
if [ $? -ne 0 ]; then echo "Error: Failed to create ${FINAL_IMAGE_NAME} file."; exit 1; fi
echo "File created."

echo "Formatting ${FINAL_IMAGE_NAME} as ext4 filesystem..."
sudo mkfs.ext4 -F -b 4096 "${FINAL_IMAGE_NAME}" # -F to force, -b 4096 for common Android block size
if [ $? -ne 0 ]; then echo "Error: Failed to format ${FINAL_IMAGE_NAME} as ext4."; exit 1; fi
echo "${FINAL_IMAGE_NAME} formatted as ext4."

# 2. Disable automatic filesystem checks (fsck)
echo "Disabling automatic filesystem checks (fsck) for ${FINAL_IMAGE_NAME}..."
sudo tune2fs -c0 -i0 "${FINAL_IMAGE_NAME}" # -c0: disable mount count check, -i0: disable time interval check
if [ $? -ne 0 ]; then echo "Error: Failed to tune filesystem parameters."; exit 1; fi
echo "Automatic fsck disabled."

# 3. Mount the newly created system_new.img in Read/Write Mode
echo "Mounting ${FINAL_IMAGE_NAME} to ${FINAL_MOUNT_POINT}/ in read/write mode..."
mkdir -p "${FINAL_MOUNT_POINT}" # Create the mount directory

# Find and assign a loop device to the new image file
FINAL_LOOP_DEV=$(sudo losetup -f --show "${FINAL_IMAGE_NAME}")
if [ -z "$FINAL_LOOP_DEV" ]; then
  echo "Error: Failed to assign loop device for ${FINAL_IMAGE_NAME}."
  exit 1
fi
echo "Loop device assigned for ${FINAL_IMAGE_NAME}: ${FINAL_LOOP_DEV}"

# Mount the new image
sudo mount -t ext4 -o rw "${FINAL_LOOP_DEV}" "${FINAL_MOUNT_POINT}"
if [ $? -ne 0 ]; then
  echo "Error: Failed to mount ${FINAL_IMAGE_NAME} in RW mode. Attempting to detach loop device."
  sudo losetup -d "${FINAL_LOOP_DEV}" || true # Detach even if mount failed
  exit 1
fi
echo "Mounted ${FINAL_IMAGE_NAME} to ${FINAL_MOUNT_POINT}/."

# --- Helper function to mount source image and copy its contents directly ---
copy_from_source_to_final() {
  local img_file_name="$1"        # e.g., "system.img", "system_ext.img"
  local destination_subdir="$2" # Subdirectory within final_system_mount (e.g., "", "system_ext", "product")
  local source_mount_point="${img_file_name}_source_mount" # Temporary mount point for source image
  local source_img_path="firmware_images/${img_file_name}" # Path to the original firmware image

  echo "--- Processing ${img_file_name} ---"

  if [ ! -f "$source_img_path" ]; then
    echo "Warning: Source image file ${source_img_path} not found. Skipping extraction for this image."
    return 0 # Return success to continue with other images
  fi

  mkdir -p "$source_mount_point"
  
  SOURCE_LOOP_DEV=$(sudo losetup -f --show "$source_img_path")
  if [ -z "$SOURCE_LOOP_DEV" ]; then
    echo "Error: Failed to assign loop device for ${source_img_path}."
    return 1
  fi
  echo "Loop device assigned for ${source_img_path}: ${SOURCE_LOOP_DEV}"

  sudo mount -t ext4 -o ro "${SOURCE_LOOP_DEV}" "${source_mount_point}"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to mount ${source_img_path}. Attempting to detach loop device."
    sudo losetup -d "${SOURCE_LOOP_DEV}" || true
    return 1
  fi
  echo "Mounted ${source_img_path} to ${source_mount_point}/."

  local full_destination_path="${FINAL_MOUNT_POINT}/${destination_subdir}"
  mkdir -p "${full_destination_path}"

  echo "Copying contents from ${source_mount_point}/ to ${full_destination_path}/ using rsync -a..."
  sudo rsync -a "${source_mount_point}/" "${full_destination_path}/"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to copy contents from ${source_img_path} to ${FINAL_IMAGE_NAME}."
    sync || true
    sudo umount "${source_mount_point}" || true
    sudo losetup -d "${SOURCE_LOOP_DEV}" || true
    return 1
  fi
  echo "Contents copied for ${img_file_name}."

  echo "Syncing data for ${source_mount_point} before unmount..."
  sync
  sudo umount "${source_mount_point}"
  echo "Unmounted ${source_mount_point}."
  sudo losetup -d "${SOURCE_LOOP_DEV}"
  echo "Detached loop device ${SOURCE_LOOP_DEV}."
  rmdir "${source_mount_point}"

  # --- Cleanup 4: Remove individual source image after it's copied ---
  echo "--- Cleanup: Removing source image ${source_img_path} ---"
  if [ -f "$source_img_path" ]; then
    rm "$source_img_path"
    echo "Removed $source_img_path."
  fi
  echo "--- Cleanup Complete ---"

  return 0
}

# Call the helper function for each required partition
copy_from_source_to_final "system.img" "" || exit 1
copy_from_source_to_final "system_ext.img" "system_ext" || exit 1
copy_from_source_to_final "product.img" "product" || exit 1
copy_from_source_to_final "odm.img" "odm" || exit 1

if [ -f "firmware_images/opproduct.img" ]; then
  copy_from_source_to_final "opproduct.img" "opproduct" || exit 1
else
  echo "opproduct.img not found in firmware_images. Skipping its processing."
fi

# --- Cleanup 5: Remove the firmware_images directory after all images are processed ---
echo "--- Cleanup: Removing firmware_images directory ---"
if [ -d "firmware_images" ]; then
  rm -rf firmware_images/
  echo "Removed firmware_images/."
fi
echo "--- Cleanup Complete ---"

echo "--- All base partitions copied to ${FINAL_IMAGE_NAME}. Applying custom modifications... ---"

# --- Custom Modification Steps ---

# 1. Create empty keylayout files
KEYLAYOUT_DIR="${FINAL_MOUNT_POINT}/usr/keylayout"
sudo mkdir -p "$KEYLAYOUT_DIR"
echo "Creating empty uinput-fpc.kl and uinput-goodix.kl..."
sudo touch "$KEYLAYOUT_DIR/uinput-fpc.kl"
sudo touch "$KEYLAYOUT_DIR/uinput-goodix.kl"
echo "Keylayout files created."

# 2. Replace OPWallpaperResources.apk
TARGET_APK_DIR="${FINAL_MOUNT_POINT}/system_ext/app/OPWallpaperResources"
TARGET_APK_PATH="$TARGET_APK_DIR/OPWallpaperResources.apk"
SOURCE_APK_PATH="${GITHUB_WORKSPACE}/for_OPWallpaperResources/OPWallpaperResources.apk"

echo "Attempting to replace OPWallpaperResources.apk..."

if [ ! -d "$TARGET_APK_DIR" ]; then
  echo "Error: Target directory not found: $TARGET_APK_DIR"
  echo "Please verify the path 'system_ext/app/OPWallpaperResources' within the mounted image."
  exit 1
fi

if [ -f "$TARGET_APK_PATH" ]; then
  echo "Deleting original OPWallpaperResources.apk: $TARGET_APK_PATH"
  sudo rm "$TARGET_APK_PATH"
  if [ $? -ne 0 ]; then echo "Failed to delete original OPWallpaperResources.apk."; exit 1; fi
else
  echo "Original OPWallpaperResources.apk not found at $TARGET_APK_PATH (might be already deleted or path is wrong, proceeding)."
fi

if [ ! -f "$SOURCE_APK_PATH" ]; then
  echo "Error: Custom OPWallpaperResources.apk not found at source: $SOURCE_APK_PATH"
  echo "Please ensure 'for_OPWallpaperResources/OPWallpaperResources.apk' is in your repository root."
  exit 1
fi

echo "Copying custom OPWallpaperResources.apk from $SOURCE_APK_PATH to $TARGET_APK_DIR"
sudo cp "$SOURCE_APK_PATH" "$TARGET_APK_DIR/"
if [ $? -ne 0 ]; then echo "Failed to copy custom OPWallpaperResources.apk."; exit 1; fi
echo "OPWallpaperResources.apk replaced successfully."

sudo chown 0:0 "$TARGET_APK_PATH"
sudo chmod 0644 "$TARGET_APK_PATH"
echo "Permissions for $TARGET_APK_PATH set."

# 3. Remove Unwanted Apps
echo "Attempting to remove unwanted apps from various partitions..."

APPS_TO_REMOVE=(
  "OnePlusCamera"
  "Drive"
  "Duo"
  "Gmail2"
  "Maps"
  "Music2"
  "Photos"
  "GooglePay"
  "GoogleTTS"
  "Videos"
  "YouTube"
  "HotwordEnrollmentOKGoogleWCD9340"
  "HotwordEnrollmentXGoogleWCD9340"
  "Velvet"
  "By_3rd_PlayAutoInstallConfigOverSeas"
  "OPBackup"
  "OPForum"
)

declare -a APP_PATHS=(
  "${FINAL_MOUNT_POINT}/app"
  "${FINAL_MOUNT_POINT}/priv-app"
  "${FINAL_MOUNT_POINT}/product/app"
  "${FINAL_MOUNT_POINT}/product/priv-app"
  "${FINAL_MOUNT_POINT}/system_ext/app"
  "${FINAL_MOUNT_POINT}/system_ext/priv-app"
  "${FINAL_MOUNT_POINT}/reserve"
)

for app_name in "${APPS_TO_REMOVE[@]}"; do
  APP_FOUND=false
  for app_path_base in "${APP_PATHS[@]}"; do
    TARGET_DIR="$app_path_base/$app_name"
    if [ -d "$TARGET_DIR" ]; then
      echo "Removing $TARGET_DIR..."
      sudo rm -rf "$TARGET_DIR"
      APP_FOUND=true
      break
    fi
  done
  if ! $APP_FOUND; then
    echo "Warning: App folder '$app_name' not found in common directories. Skipping."
  fi
done
echo "Unwanted apps removal attempt complete."

# 4. Patch services.jar (Smali Modification)
SERVICES_JAR_PATH="${FINAL_MOUNT_POINT}/system/framework/services.jar"
SMALI_DIR="services_decompiled"
SMALI_FILE="$SMALI_DIR/smali_classes2/com/android/server/wm/ActivityTaskManagerService\$LocalService.smali"

if [ ! -f "$SERVICES_JAR_PATH" ]; then
  echo "Error: services.jar not found at $SERVICES_JAR_PATH."
  exit 1
fi

echo "Decompiling services.jar..."
sudo apktool d -f -r "$SERVICES_JAR_PATH" -o "$SMALI_DIR"
if [ $? -ne 0 ]; then echo "Apktool decompilation failed."; exit 1; fi

if [ ! -f "$SMALI_FILE" ]; then
  echo "Error: Smali file not found at $SMALI_FILE. Decompilation might have failed or path is incorrect."
  exit 1
fi

echo "Applying smali modifications to $SMALI_FILE..."

sudo sed -i '/invoke-static {}, Landroid\/os\/Build;->isBuildConsistent()Z/{
  n
  s/    move-result v1/    move-result v1\n\n    const\/4 v1, 0x1\n/
}' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "First sed replacement failed."; exit 1; fi
echo "First modification (const/4 v1, 0x1) applied."

sudo sed -i 's/if-nez v1, :cond_42/if-nez v1, :cond_43/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Second sed replacement failed."; exit 1; fi
echo "Second modification (cond_42 to cond_43) applied."

sudo sed -i 's/:cond_42/:cond_43/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Third sed replacement failed."; exit 1; fi
echo "Third modification (:cond_42 to :cond_43 label) applied."

sudo sed -i 's/\(:try_end_43\)\n    .catchall {:try_start_29 .. :try_end_43} :catchall_26/\:try_end_44\n    .catchall {:try_start_29 .. :try_end_44} :catchall_26/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Fourth sed replacement (try_end_43) failed."; exit 1; fi
echo "Fourth modification (:try_end_43 to :try_end_44) applied."

sudo sed -i 's/:goto_47/:goto_48/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Fifth sed replacement (goto_47) failed."; exit 1; fi
echo "Fifth modification (:goto_47 to :goto_48) applied."

sudo sed -i 's/\(:try_start_47\)\n    monitor-exit v0\n    :try_end_48/\:try_start_48\n    monitor-exit v0\n    :try_end_49/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Sixth sed replacement (try_start/end_4x) failed."; exit 1; fi
echo "Sixth modification (:try_start/end_4x) applied."

echo "Recompiling services.jar..."
sudo apktool b "$SMALI_DIR" -o "$SERVICES_JAR_PATH"
if [ $? -ne 0 ]; then echo "Apktool recompilation failed."; exit 1; fi
echo "services.jar recompiled successfully."

sudo rm -rf "$SMALI_DIR"

# 5. Modify OPSystemUI.apk
APK_PATH="${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
DECOMPILED_DIR="OPSystemUI_decompiled"
PLUGIN_SOURCE_DIR="${GITHUB_WORKSPACE}/plugin_files"

if [ ! -f "$APK_PATH" ]; then
  echo "Error: OPSystemUI.apk not found at $APK_PATH."
  exit 1
fi

echo "Decompiling $APK_PATH..."
sudo apktool d -f "$APK_PATH" -o "$DECOMPILED_DIR"
if [ $? -ne 0 ]; then echo "Apktool decompilation failed for OPSystemUI.apk."; exit 1; fi

echo "Applying smali modifications..."

OP_VOLUME_DIALOG_IMPL_FILE="$DECOMPILED_DIR/smali_classes2/com/oneplus/volume/OpVolumeDialogImpl.smali"
if [ -f "$OP_VOLUME_DIALOG_IMPL_FILE" ]; then
  echo "Modifying OpVolumeDialogImpl.smali..."
  sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_VOLUME_DIALOG_IMPL_FILE"
  sudo sed -i 's/const\/16 v4, 0x13/const\/16 v4, 0x15/g' "$OP_VOLUME_DIALOG_IMPL_FILE"
else
  echo "Warning: OpVolumeDialogImpl.smali not found. Skipping modification."
fi

OP_OUTPUT_CHOOSER_DIALOG_FILE="$DECOMPILED_DIR/smali_classes2/com/oneplus/volume/OpOutputChooserDialog.smali"
if [ -f "$OP_OUTPUT_CHOOSER_DIALOG_FILE" ]; then
  echo "Modifying OpOutputChooserDialog.smali..."
  sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_OUTPUT_CHOOSER_DIALOG_FILE"
else
  echo "Warning: OpOutputChooserDialog.smali not found. Skipping modification."
fi

VOLUME_DIALOG_IMPL_FILE="$DECOMPILED_DIR/smali/com/android/systemui/volume/VolumeDialogImpl.smali"
if [ -f "$VOLUME_DIALOG_IMPL_FILE" ]; then
  echo "Modifying VolumeDialogImpl.smali..."
  sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$VOLUME_DIALOG_IMPL_FILE"
else
  echo "Warning: VolumeDialogImpl.smali not found. Skipping modification."
fi

DOZE_SENSORS_PICKUP_CHECK_FILE="$DECOMPILED_DIR/smali/com/android/systemui/doze/DozeSensors\$PickupCheck.smali"
if [ -f "$DOZE_SENSORS_PICKUP_CHECK_FILE" ]; then
  echo "Modifying DozeSensors\$PickupCheck.smali..."
  sudo sed -i 's/0x1fa2652/0x1fa265c/g' "$DOZE_SENSORS_PICKUP_CHECK_FILE"
else
  echo "Warning: DozeSensors\$PickupCheck.smali not found. Skipping modification."
fi

DOZE_MACHINE_STATE_FILE="$DECOMPILED_DIR/smali/com/android/systemui/doze/DozeMachine\$State.smali"
if [ -f "$DOZE_MACHINE_STATE_FILE" ]; then
  echo "Modifying DozeMachine\$State.smali..."
  sudo sed -i '/.method screenState/{n;s/    const\/4 v1, 0x3/    const\/4 v1, 0x2/}' "$DOZE_MACHINE_STATE_FILE"
else
  echo "Warning: DozeMachine\$State.smali not found. Skipping modification."
fi

echo "Applying Smali file replacement for OpCustomizeSettingsG2.smali..."

TARGET_SMALI_DIR="$DECOMPILED_DIR/smali_classes2/com/oneplus/custom/utils"
ORIGINAL_SMALI_FILE="$TARGET_SMALI_DIR/OpCustomizeSettingsG2.smali"
NEW_SMALI_FILE="${GITHUB_WORKSPACE}/my_G2/for_SystemUI/OpCustomizeSettingsG2.smali"

if [ ! -d "$TARGET_SMALI_DIR" ]; then
  echo "Error: Target Smali directory not found: $TARGET_SMALI_DIR"
  echo "Please verify the 'smali_classesX' folder or the path 'com/oneplus/custom/utils' within OPSystemUI.apk's decompiled structure."
  exit 1
fi

if [ -f "$ORIGINAL_SMALI_FILE" ]; then
  echo "Deleting original OpCustomizeSettingsG2.smali: $ORIGINAL_SMALI_FILE"
  sudo rm "$ORIGINAL_SMALI_FILE"
  if [ $? -ne 0 ]; then echo "Failed to delete original OpCustomizeSettingsG2.smali."; exit 1; fi
else
  echo "Original OpCustomizeSettingsG2.smali not found at $ORIGINAL_SMALI_FILE (might be already deleted or path is wrong, proceeding)."
fi

if [ ! -f "$NEW_SMALI_FILE" ]; then
  echo "Error: New OpCustomizeSettingsG2.smali not found at source: $NEW_SMALI_FILE"
  echo "Please ensure '$NEW_SMALI_FILE' is in your repository and accessible."
  exit 1
fi

echo "Copying new OpCustomizeSettingsG2.smali from $NEW_SMALI_FILE to $TARGET_SMALI_DIR"
sudo cp "$NEW_SMALI_FILE" "$TARGET_SMALI_DIR/"
if [ $? -ne 0 ]; then echo "Failed to copy new OpCustomizeSettingsG2.smali."; exit 1; fi
echo "OpCustomizeSettingsG2.smali replaced successfully."

echo "Smali file replacement complete."
echo "Smali modifications complete."

PLUGIN_DEST_DIR="$DECOMPILED_DIR/smali_classes2/com/oneplus/plugin"
echo "Replacing plugin files in $PLUGIN_DEST_DIR..."

if [ ! -d "$PLUGIN_SOURCE_DIR" ]; then
  echo "Error: Source plugin directory '$PLUGIN_SOURCE_DIR' not found. Cannot replace plugin files."
  exit 1
fi

if [ -d "$PLUGIN_DEST_DIR" ]; then
  sudo rm -rf "$PLUGIN_DEST_DIR"/*
else
  sudo mkdir -p "$PLUGIN_DEST_DIR"
fi

sudo cp -r "$PLUGIN_SOURCE_DIR"/* "$PLUGIN_DEST_DIR/"
if [ $? -ne 0 ]; then echo "Error: Failed to copy new plugin files."; exit 1; fi
echo "Plugin files replaced."

echo "Recompiling OPSystemUI.apk..."
sudo apktool b "$DECOMPILED_DIR" -o "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
if [ $? -ne 0 ]; then echo "Apktool recompilation failed for OPSystemUI.apk."; exit 1; fi

echo "Recompiled OPSystemUI.apk created and placed."
sudo rm -rf "$DECOMPILED_DIR"

sudo chown 0:0 "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
sudo chmod 0644 "${FINAL_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
echo "Permissions for OPSystemUI.apk set."

# 6. Modify Settings.apk
SETTINGS_APK_PATH="${FINAL_MOUNT_POINT}/system_ext/priv-app/Settings/Settings.apk"
DECOMPILED_SETTINGS_DIR="Settings_decompiled"

if [ ! -f "$SETTINGS_APK_PATH" ]; then
  echo "Error: Settings.apk not found at $SETTINGS_APK_PATH."
  exit 1
fi

echo "Decompiling $SETTINGS_APK_PATH..."
sudo apktool d -f "$SETTINGS_APK_PATH" -o "$DECOMPILED_SETTINGS_DIR"
if [ $? -ne 0 ]; then echo "Apktool decompilation failed for Settings.apk."; exit 1; fi

echo "Applying smali modifications to OPUtils.smali..."

OP_UTILS_FILE="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/settings/utils/OPUtils.smali"
if [ -f "$OP_UTILS_FILE" ]; then
  echo "Modifying $OP_UTILS_FILE..."

  sudo sed -i -z 's/\(OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT\)/\1/g' "$OP_UTILS_FILE"

  sudo sed -i -z '
    /\.method.*OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT/ {
      :a
      n
      /    move-result v0\n\n    return v0/ {
        s/\(    move-result v0\n\n\)    return v0/\1    const\/4 v0, 0x1\n\n    return v0/
        b end_sed_block
      }
      ba
    }
    :end_sed_block
  ' "$OP_UTILS_FILE"

  if [ $? -ne 0 ]; then
    echo "Error: Smali modification for OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT failed."
    exit 1
  fi
  echo "Smali modification for OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT applied."

else
  echo "Warning: OPUtils.smali not found at $OP_UTILS_FILE. Skipping modification."
fi

echo "Applying Smali file replacement for OpCustomizeSettingsG2.smali..."

TARGET_SMALI_DIR="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/custom/utils"
ORIGINAL_SMALI_FILE="$TARGET_SMALI_DIR/OpCustomizeSettingsG2.smali"
NEW_SMALI_FILE="${GITHUB_WORKSPACE}/my_G2/for_Settings/OpCustomizeSettingsG2.smali"

if [ ! -d "$TARGET_SMALI_DIR" ]; then
  echo "Error: Target Smali directory not found for Settings.apk: $TARGET_SMALI_DIR"
  echo "Please verify the 'smali_classesX' folder or the path 'com/oneplus/custom/utils' within Settings.apk's decompiled structure."
  exit 1
fi

if [ -f "$ORIGINAL_SMALI_FILE" ]; then
  echo "Deleting original OpCustomizeSettingsG2.smali: $ORIGINAL_SMALI_FILE"
  sudo rm "$ORIGINAL_SMALI_FILE"
  if [ $? -ne 0 ]; then echo "Failed to delete original OpCustomizeSettingsG2.smali."; exit 1; fi
else
  echo "Original OpCustomizeSettingsG2.smali not found at $ORIGINAL_SMALI_FILE (might be already deleted or path is wrong, proceeding)."
fi

if [ ! -f "$NEW_SMALI_FILE" ]; then
  echo "Error: New OpCustomizeSettingsG2.smali not found at source: $NEW_SMALI_FILE"
  echo "Please ensure '$NEW_SMALI_FILE' is in your repository and accessible."
  exit 1
fi

echo "Copying new OpCustomizeSettingsG2.smali from $NEW_SMALI_FILE to $TARGET_SMALI_DIR"
sudo cp "$NEW_SMALI_FILE" "$TARGET_SMALI_DIR/"
if [ $? -ne 0 ]; then echo "Failed to copy new OpCustomizeSettingsG2.smali."; exit 1; fi
echo "OpCustomizeSettingsG2.smali replaced successfully."

echo "Smali file replacement complete."
echo "Smali modifications complete."

echo "Recompiling Settings.apk..."
sudo apktool b "$DECOMPILED_SETTINGS_DIR" -o "$SETTINGS_APK_PATH"
if [ $? -ne 0 ]; then echo "Apktool recompilation failed for Settings.apk."; exit 1; fi
echo "Settings.apk recompiled and replaced in its original location."

sudo rm -rf "$DECOMPILED_SETTINGS_DIR"

sudo chown 0:0 "$SETTINGS_APK_PATH"
sudo chmod 0644 "$SETTINGS_APK_PATH"
echo "Permissions for $SETTINGS_APK_PATH set."

# 7. Prepare Reserve Partition and Create Image
OLD_RESERVE_SOURCE_DIR="${FINAL_MOUNT_POINT}/reserve"
NEW_RESERVE_WORKSPACE_DIR="${GITHUB_WORKSPACE}/reserve_new_content"
CUST_MOUNTPOINT_DIR="${FINAL_MOUNT_POINT}/cust"
SYMLINK_TARGET_DIR="${FINAL_MOUNT_POINT}/reserve"

echo "1. Copying contents from $OLD_RESERVE_SOURCE_DIR to $NEW_RESERVE_WORKSPACE_DIR (for separate image creation)..."
sudo mkdir -p "$NEW_RESERVE_WORKSPACE_DIR"
if [ -d "$OLD_RESERVE_SOURCE_DIR" ]; then
  sudo rsync -a "$OLD_RESERVE_SOURCE_DIR"/* "$NEW_RESERVE_WORKSPACE_DIR/"
  echo "   Contents copied to $NEW_RESERVE_WORKSPACE_DIR."
else
  echo "   Warning: Original reserve directory ($OLD_RESERVE_SOURCE_DIR) not found in the mounted system image. Proceeding assuming $NEW_RESERVE_WORKSPACE_DIR will be populated by other means if needed."
fi

echo "2. Setting permissions for files and folders in $NEW_RESERVE_WORKSPACE_DIR..."
sudo chown -R 1004:1004 "$NEW_RESERVE_WORKSPACE_DIR"
find "$NEW_RESERVE_WORKSPACE_DIR" -type d -exec sudo chmod 0775 {} +
echo "   Directory permissions set to 0775."
find "$NEW_RESERVE_WORKSPACE_DIR" -name "*.apk" -type f -exec sudo chmod 0664 {} +
echo "   APK file permissions set to 0664."
echo "   Permissions set for $NEW_RESERVE_WORKSPACE_DIR."

echo "3. Creating reserve_new.img from $NEW_RESERVE_WORKSPACE_DIR..."
IMAGE_SIZE_MB=830
IMAGE_SIZE_BYTES=$(($IMAGE_SIZE_MB * 1024 * 1024))

if command -v make_ext4fs &> /dev/null; then
  make_ext4fs -s -J -T 0 -L cust -l $IMAGE_SIZE_BYTES -a cust "${GITHUB_WORKSPACE}/reserve_new.img" "$NEW_RESERVE_WORKSPACE_DIR"
  if [ $? -ne 0 ]; then
    echo "   Error: Failed to create reserve_new.img using make_ext4fs. Please check the tool's output for details."
    exit 1
  fi
  echo "   reserve_new.img created at ${GITHUB_WORKSPACE}/reserve_new.img"
else
  echo "   Error: 'make_ext4fs' command not found. This tool is essential for creating the image."
  echo "   Please ensure 'e2fsprogs' is installed. Aborting."
  exit 1
fi
sudo rm -rf "$NEW_RESERVE_WORKSPACE_DIR"

echo "4. Preparing $CUST_MOUNTPOINT_DIR (empty mount point) in the mounted system.img..."
sudo mkdir -p "$CUST_MOUNTPOINT_DIR"
sudo rm -rf "$CUST_MOUNTPOINT_DIR"/*
echo "   Mount point directory $CUST_MOUNTPOINT_DIR prepared as empty."

echo "5. Creating symlinks in $SYMLINK_TARGET_DIR (inside the mounted system.img) pointing to $CUST_MOUNTPOINT_DIR..."
sudo mkdir -p "$SYMLINK_TARGET_DIR"
sudo rm -rf "$SYMLINK_TARGET_DIR"/*

TEMP_RESERVE_MOUNT="/tmp/temp_reserve_mount"
mkdir -p "$TEMP_RESERVE_MOUNT"
TEMP_RESERVE_LOOP=$(sudo losetup -f --show "${GITHUB_WORKSPACE}/reserve_new.img")
sudo mount -t ext4 -o ro "$TEMP_RESERVE_LOOP" "$TEMP_RESERVE_MOUNT"

find "$TEMP_RESERVE_MOUNT" -maxdepth 1 -mindepth 1 -type d | while read -r app_folder_path; do
    dirname=$(basename "$app_folder_path")
    sudo ln -s "../../cust/$dirname" "$SYMLINK_TARGET_DIR/$dirname"
    if [ $? -ne 0 ]; then
      echo "   Warning: Failed to create symlink for directory $dirname. This might cause issues if the app relies on it."
    fi
done

sudo umount "$TEMP_RESERVE_MOUNT"
sudo losetup -d "$TEMP_RESERVE_LOOP"
rmdir "$TEMP_RESERVE_MOUNT"

echo "   Folder symlinks created in $SYMLINK_TARGET_DIR."
echo "All reserve partition preparation and image creation steps complete."

echo "--- Custom modifications complete. ---"

echo "--- Finalizing ${FINAL_IMAGE_NAME} ---"
# Unmount and Clean Up the Final system_new.img
echo "Syncing data for ${FINAL_MOUNT_POINT} before unmount..."
sync
sudo umount "${FINAL_MOUNT_POINT}"
echo "Unmounted ${FINAL_MOUNT_POINT}."
sudo losetup -d "${FINAL_LOOP_DEV}"
echo "Detached loop device ${FINAL_LOOP_DEV}."
rmdir "${FINAL_MOUNT_POINT}"
echo "Successfully populated and unmounted ${FINAL_IMAGE_NAME}."

echo "--- Script execution complete ---"
