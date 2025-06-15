#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

log_step() {
    echo ""
    echo "==================================================================="
    echo "STEP $1: $2"
    echo "==================================================================="
    echo ""
}

# --- Workflow Inputs (passed as environment variables from the YAML) ---
FIRMWARE_URL="$1"
if [ -z "$FIRMWARE_URL" ]; then
  echo "Error: Firmware URL is required. Usage: $0 <firmware_url>"
  exit 1
fi

echo "Starting Android ROM Porting script..."

# --- Setup Paths ---
ROM_ROOT="$(pwd)" # Current working directory will be the repository root
PAYLOAD_DUMPER_DIR="payload_dumper"
MY_INIT_FILES_DIR="${ROM_ROOT}/my_init_files"
FOR_OPWALLPAPER_RESOURCES_DIR="${ROM_ROOT}/for_OPWallpaperResources"
PLUGIN_FILES_DIR="${ROM_ROOT}/plugin_files"
MY_G2_FOR_SYSTEMUI_DIR="${ROM_ROOT}/my_G2/for_SystemUI"
MY_G2_FOR_SETTINGS_DIR="${ROM_ROOT}/my_G2/for_Settings"

# --- Helper function for mounting and unmounting ---
mount_image_rw() {
  local img_path="$1"
  local mount_point="$2"
  sudo mkdir -p "$mount_point"
  LOOP_DEV=$(sudo losetup -f --show "$img_path")
  if [ -z "$LOOP_DEV" ]; then echo "Error: Failed to assign loop device for $img_path."; return 1; fi
  echo "Loop device assigned: $LOOP_DEV"
  sudo mount -t ext4 "$LOOP_DEV" "$mount_point"
  if [ $? -ne 0 ]; then echo "Error: Failed to mount $img_path. Unmounting loop device."; sudo losetup -d "$LOOP_DEV"; return 1; fi
  echo "$img_path mounted to $mount_point."
  echo "$LOOP_DEV" # Return loop device by echoing it
}

unmount_image() {
  local mount_point="$1"
  local loop_dev="$2"
  sudo sync
  echo "Syncing $mount_point..."
  sudo umount "$mount_point"
  if [ $? -ne 0 ]; then echo "Error: Failed to unmount $mount_point."; return 1; fi
  echo "Unmounted $mount_point."
  sudo losetup -d "$loop_dev"
  if [ $? -ne 0 ]; then echo "Error: Failed to detach loop device $loop_dev."; return 1; fi
  echo "Detached loop device $loop_dev."
  sudo rmdir "$mount_point" 2>/dev/null || true # Remove if empty, suppress error if not
  echo "Cleaned up $mount_point directory."
}

# --- Step: Install Dependencies ---
log_step 1 "Installing Dependencies"
sudo apt update
sudo apt install -y unace unrar zip unzip p7zip-full liblz4-tool brotli default-jre
sudo apt install -y libarchive-tools
sudo apt install -y android-sdk-libsparse-utils
sudo apt install -y e2fsprogs

pip install protobuf

wget https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool -O apktool
wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar -O apktool.jar
chmod +x apktool apktool.jar
sudo mv apktool /usr/local/bin/
sudo mv apktool.jar /usr/local/bin/
echo "Apktool installed successfully."
echo ""

# --- Step: Download OnePlus Firmware ---
log_step 2 "Downloading OnePlus Firmware"
FIRMWARE_FILENAME=$(basename "$FIRMWARE_URL")
echo "Downloading firmware from: $FIRMWARE_URL"
wget -q "$FIRMWARE_URL" -O "$FIRMWARE_FILENAME"
if [ ! -f "$FIRMWARE_FILENAME" ]; then
  echo "Error: Firmware download failed."
  exit 1
fi
echo "Downloaded firmware: $FIRMWARE_FILENAME"
echo ""

# --- Step: Extract Firmware ---
log_step 3 "Extracting Firmware Archive"
mkdir -p firmware_extracted
echo "Extracting $FIRMWARE_FILENAME..."
if [[ "$FIRMWARE_FILENAME" == *.zip ]]; then
  unzip -q "$FIRMWARE_FILENAME" -d firmware_extracted/
elif [[ "$FIRMWARE_FILENAME" == *.rar ]]; then
  unrar x "$FIRMWARE_FILENAME" firmware_extracted/
elif [[ "$FIRMWARE_FILENAME" == *.7z ]]; then
  7z x "$FIRMWARE_FILENAME" -o firmware_extracted/
else
  echo "Error: Unsupported firmware archive format."
  exit 1
fi

if [ ! -d "firmware_extracted" ] || [ -z "$(ls -A firmware_extracted)" ]; then
    echo "Error: Firmware extraction failed or directory is empty."
    exit 1
fi
echo "Firmware extracted to firmware_extracted/"
echo ""

# --- Step: Extract Images from payload.bin (if present) ---
log_step 4 "Extracting Images from payload.bin (if present)"
if [ -f firmware_extracted/payload.bin ]; then
  echo "payload.bin found. Extracting images using payload_dumper.py from vm03/payload_dumper.git..."

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
  
  echo "Images extracted from payload.bin to output/"
  # The output directory from payload_dumper.py is typically 'output' in the current working directory.
  # We need to move these to 'firmware_images'
  
  # --- Consolidate and Select Required Images ---
  log_step 5 "Consolidating and Selecting Required Images"
  REQUIRED_IMAGES=("system.img" "product.img" "system_ext.img" "odm.img" "vendor.img" "boot.img")
  OPTIONAL_IMAGES=("opproduct.img")
  ALL_IMAGES_FOUND=true
  TARGET_IMG_DIR="firmware_images" # Use a consistent directory for all image files
  mkdir -p "$TARGET_IMG_DIR"

  for img in "${REQUIRED_IMAGES[@]}"; do
    if [ -f "output/$img" ]; then
      echo "Found $img"
      mv "output/$img" "$TARGET_IMG_DIR/"
    else
      echo "Warning: Required image $img not found in output/."
      ALL_IMAGES_FOUND=false
    fi
  done

  for img in "${OPTIONAL_IMAGES[@]}"; do
    if [ -f "output/$img" ]; then
      echo "Found optional image $img"
      mv "output/$img" "$TARGET_IMG_DIR/"
    else
      echo "Optional image $img not found in output/."
    fi
  done
  
  if ! $ALL_IMAGES_FOUND; then
    echo "Error: One or more required images were not found after payload.bin extraction. Exiting."
    exit 1
  fi
  echo "Required and optional images moved to $TARGET_IMG_DIR/."
  rm -rf output # Clean up the dumper's output directory
  rm -rf "$PAYLOAD_DUMPER_DIR"
  
else
  echo "payload.bin not found. Proceeding with direct image files if they exist in firmware_extracted/."
  # If payload.bin is not present, assume system.img, etc., are directly in firmware_extracted.
  # Move them to firmware_images for consistency.
  log_step 5 "Consolidating direct image files (no payload.bin)"
  TARGET_IMG_DIR="firmware_images"
  mkdir -p "$TARGET_IMG_DIR"
  for img_file in "firmware_extracted/"*.img; do
    if [ -f "$img_file" ]; then
      echo "Found direct image file: $(basename "$img_file")"
      mv "$img_file" "$TARGET_IMG_DIR/"
    fi
  done
  echo "Image files moved to $TARGET_IMG_DIR/."
fi
echo ""


# --- Proposed Step 1: Delete payload.bin and downloaded zip ---
log_step 6 "Cleaning up initial downloaded files"
sudo rm -f "$FIRMWARE_FILENAME" # This is the downloaded zip/archive
sudo rm -rf firmware_extracted # Remove the extraction dir completely
echo "Deleted downloaded firmware archive and firmware_extracted directory."
echo ""

# --- Proposed Step 2: Mount system.img, delete unwanted apps, sync, umount ---
log_step 7 "Mounting system.img, deleting unwanted apps, and unmounting"

SYSTEM_IMG_PATH="firmware_images/system.img"
SYSTEM_MOUNT_POINT="system_mount_point"

if [ ! -f "$SYSTEM_IMG_PATH" ]; then
  echo "Error: system.img not found at $SYSTEM_IMG_PATH. Cannot proceed with mounting."
  exit 1
fi

SYSTEM_LOOP_DEV=$(mount_image_rw "$SYSTEM_IMG_PATH" "$SYSTEM_MOUNT_POINT")
if [ $? -ne 0 ]; then echo "Failed to mount system.img."; exit 1; fi

APPS_TO_REMOVE=(
  "OnePlusCamera" "Drive" "Duo" "Gmail2" "Maps" "Music2" "Photos" "GooglePay"
  "GoogleTTS" "Videos" "YouTube" "HotwordEnrollmentOKGoogleWCD9340"
  "HotwordEnrollmentXGoogleWCD9340" "Velvet" "By_3rd_PlayAutoInstallConfigOverSeas"
  "OPBackup" "OPForum"
)

declare -a SYSTEM_APP_PATHS=(
  "${SYSTEM_MOUNT_POINT}/system/app"
  "${SYSTEM_MOUNT_POINT}/system/priv-app"
  "${SYSTEM_MOUNT_POINT}/system/reserve"
  "${SYSTEM_MOUNT_POINT}/system_ext/app"
  "${SYSTEM_MOUNT_POINT}/system_ext/priv-app"
  "${SYSTEM_MOUNT_POINT}/product/app"
  "${SYSTEM_MOUNT_POINT}/product/priv-app"
  "${SYSTEM_MOUNT_POINT}/system/system_ext/app" # If merged already in the image
  "${SYSTEM_MOUNT_POINT}/system/system_ext/priv-app"
  "${SYSTEM_MOUNT_POINT}/system/product/app"
  "${SYSTEM_MOUNT_POINT}/system/product/priv-app"
)

for app_name in "${APPS_TO_REMOVE[@]}"; do
  APP_FOUND=false
  for app_path_base in "${SYSTEM_APP_PATHS[@]}"; do
    TARGET_DIR="$app_path_base/$app_name"
    if [ -d "$TARGET_DIR" ]; then
      echo "Removing $TARGET_DIR from system.img..."
      sudo rm -rf "$TARGET_DIR"
      APP_FOUND=true
      break
    fi
  done
  if ! $APP_FOUND; then
    echo "Warning: App folder '$app_name' not found in system.img common directories. Skipping."
  fi
done

echo "Unwanted apps removal attempt complete for system.img."

# Fix permissions for build.prop (applied within mounted system.img)
echo "Fixing permissions for build.prop within mounted system.img..."
sudo chmod -R a+rwX "${SYSTEM_MOUNT_POINT}/system"
echo "Permissions set."

# Modify build.prop (within mounted system.img)
log_step 7.1 "Modifying build.prop within mounted system.img"
ODT_BUILD_PROP="${SYSTEM_MOUNT_POINT}/odm/etc/buildinfo/build.prop"
OPPRODUCT_BUILD_PROP="${SYSTEM_MOUNT_POINT}/opproduct/build.prop"
SYSTEM_BUILD_PROP="${SYSTEM_MOUNT_POINT}/system/build.prop"
SOURCE_BUILD_PROP=""

if [ -f "$ODT_BUILD_PROP" ]; then
  SOURCE_BUILD_PROP="$ODT_BUILD_PROP"
  echo "Found source build.prop at $ODT_BUILD_PROP. Using it for modification."
elif [ -f "$OPPRODUCT_BUILD_PROP" ]; then
  SOURCE_BUILD_PROP="$OPPRODUCT_BUILD_PROP"
  echo "Warning: $ODT_BUILD_PROP not found. Using $OPPRODUCT_BUILD_PROP as source build.prop instead."
else
  echo "Warning: Neither $ODT_BUILD_PROP nor $OPPRODUCT_BUILD_PROP found. Skipping source build.prop modification."
fi

if [ ! -f "$SYSTEM_BUILD_PROP" ]; then
  echo "Error: $SYSTEM_BUILD_PROP not found. Cannot modify build.prop."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV" # Clean up before exiting
  exit 1
fi

if [ -n "$SOURCE_BUILD_PROP" ]; then
  echo "Extracting lines from $SOURCE_BUILD_PROP..."
  awk '/# autogenerated by oem_log_prop.sh/{flag=1} flag' "$SOURCE_BUILD_PROP" > tmp_lines.txt

  if [ ! -s tmp_lines.txt ]; then
    echo "Warning: No lines found to copy from $SOURCE_BUILD_PROP starting from '# autogenerated by oem_log_prop.sh'. Skipping build.prop append."
    rm -f tmp_lines.txt
  else
    echo "Appending lines to $SYSTEM_BUILD_PROP..."
    awk '/# end build properties/ && !x {print; system("cat tmp_lines.txt"); x=1; next} 1' "$SYSTEM_BUILD_PROP" > tmp_build.prop && sudo mv tmp_build.prop "$SYSTEM_BUILD_PROP"
    rm -f tmp_lines.txt
  fi
fi

echo "Adding 'ro.boot.cust=6' and a blank line to $SYSTEM_BUILD_PROP..."
PROPERTY_LINE="ro.boot.cust=6" 
BLANK_LINE="" 

echo "$PROPERTY_LINE" | sudo tee -a "$SYSTEM_BUILD_PROP" > /dev/null
echo "$BLANK_LINE" | sudo tee -a "$SYSTEM_BUILD_PROP" > /dev/null

echo "ro.boot.cust=6 and blank line successfully added."
echo "Verifying last 3 lines of $SYSTEM_BUILD_PROP to confirm format:"
sudo tail -n 3 "$SYSTEM_BUILD_PROP"

echo "build.prop modification complete."

# Create empty keylayout files (within mounted system.img)
log_step 7.2 "Creating empty keylayout files within mounted system.img"
KEYLAYOUT_DIR="${SYSTEM_MOUNT_POINT}/system/usr/keylayout"
sudo mkdir -p "$KEYLAYOUT_DIR"

echo "Creating empty uinput-fpc.kl and uinput-goodix.kl..."
sudo touch "$KEYLAYOUT_DIR/uinput-fpc.kl"
sudo touch "$KEYLAYOUT_DIR/uinput-goodix.kl"
echo "Keylayout files created."

# Replace init Binary (from repo) (within mounted system.img)
log_step 7.3 "Replacing init Binary within mounted system.img"
SOURCE_INIT_PATH="${MY_INIT_FILES_DIR}/init"
INIT_TARGET_PATH="${SYSTEM_MOUNT_POINT}/system/bin/init"

if [ ! -f "$SOURCE_INIT_PATH" ]; then
  echo "Warning: Custom init binary not found at $SOURCE_INIT_PATH."
  echo "Skipping init replacement. If you intended to replace init, please place your 'init' file in the 'my_init_files' directory in your repository root."
else
  echo "Custom init binary found at $SOURCE_INIT_PATH."
  if [ -f "$INIT_TARGET_PATH" ]; then
    echo "Deleting old init: $INIT_TARGET_PATH"
    sudo rm "$INIT_TARGET_PATH"
  else
    echo "Old init not found at $INIT_TARGET_PATH, will place new one."
  fi
  echo "Copying new init from $SOURCE_INIT_PATH to $INIT_TARGET_PATH and setting permissions."
  sudo cp "$SOURCE_INIT_PATH" "$INIT_TARGET_PATH"
  sudo chown 1000:1000 "$INIT_TARGET_PATH"
  sudo chmod 0755 "$INIT_TARGET_PATH"
  echo "Init binary replaced and permissions set."
fi

# Patch services.jar (Smali Modification) (within mounted system.img)
log_step 7.4 "Patching services.jar (Smali Modification) within mounted system.img"
SERVICES_JAR_PATH="${SYSTEM_MOUNT_POINT}/system/framework/services.jar"
SMALI_DIR="${ROM_ROOT}/services_decompiled" # Decompile to a temporary folder in ROM_ROOT

if [ ! -f "$SERVICES_JAR_PATH" ]; then
  echo "Error: services.jar not found at $SERVICES_JAR_PATH."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV" # Clean up before exiting
  exit 1
fi

echo "Decompiling services.jar..."
sudo apktool d -f -r "$SERVICES_JAR_PATH" -o "$SMALI_DIR"
if [ $? -ne 0 ]; then echo "Apktool decompilation failed."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi

SMALI_FILE="$SMALI_DIR/smali_classes2/com/android/server/wm/ActivityTaskManagerService\$LocalService.smali"
if [ ! -f "$SMALI_FILE" ]; then
  echo "Error: Smali file not found at $SMALI_FILE. Decompilation might have failed or path is incorrect."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"
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
if [ $? -ne 0 ]; then echo "Apktool recompilation failed."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi
echo "services.jar recompiled successfully."

sudo rm -rf "$SMALI_DIR"
echo ""

unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"
echo "system.img unmounted."
echo ""

# --- Proposed Step 3: Mount system_ext.img, delete unwanted apps, Replace OPWallpaperResources.apk, sync, umount ---
log_step 8 "Mounting system_ext.img, deleting unwanted apps, replacing OPWallpaperResources.apk, and unmounting"

SYSTEM_EXT_IMG_PATH="firmware_images/system_ext.img"
SYSTEM_EXT_MOUNT_POINT="system_ext_mount_point"

if [ ! -f "$SYSTEM_EXT_IMG_PATH" ]; then
  echo "Warning: system_ext.img not found at $SYSTEM_EXT_IMG_PATH. Skipping this step."
  echo ""
else
  SYSTEM_EXT_LOOP_DEV=$(mount_image_rw "$SYSTEM_EXT_IMG_PATH" "$SYSTEM_EXT_MOUNT_POINT")
  if [ $? -ne 0 ]; then echo "Failed to mount system_ext.img."; exit 1; fi

  declare -a SYSTEM_EXT_APP_PATHS=(
    "${SYSTEM_EXT_MOUNT_POINT}/app"
    "${SYSTEM_EXT_MOUNT_POINT}/priv-app"
  )

  for app_name in "${APPS_TO_REMOVE[@]}"; do # Re-use APPS_TO_REMOVE from above
    APP_FOUND=false
    for app_path_base in "${SYSTEM_EXT_APP_PATHS[@]}"; do
      TARGET_DIR="$app_path_base/$app_name"
      if [ -d "$TARGET_DIR" ]; then
        echo "Removing $TARGET_DIR from system_ext.img..."
        sudo rm -rf "$TARGET_DIR"
        APP_FOUND=true
        break
      fi
    done
    if ! $APP_FOUND; then
      echo "Warning: App folder '$app_name' not found in system_ext.img common directories. Skipping."
    fi
  done
  echo "Unwanted apps removal attempt complete for system_ext.img."


  # Replace OPWallpaperResources.apk
  TARGET_APK_DIR="${SYSTEM_EXT_MOUNT_POINT}/app/OPWallpaperResources"
  TARGET_APK_PATH="$TARGET_APK_DIR/OPWallpaperResources.apk"
  SOURCE_APK_PATH="${FOR_OPWALLPAPER_RESOURCES_DIR}/OPWallpaperResources.apk"

  echo "Attempting to replace OPWallpaperResources.apk in system_ext.img..."

  if [ ! -d "$TARGET_APK_DIR" ]; then
    echo "Warning: Target directory not found in system_ext.img: $TARGET_APK_DIR. Skipping OPWallpaperResources.apk replacement."
  else
    if [ -f "$TARGET_APK_PATH" ]; then
      echo "Deleting original OPWallpaperResources.apk: $TARGET_APK_PATH"
      sudo rm "$TARGET_APK_PATH"
      if [ $? -ne 0 ]; then echo "Failed to delete original OPWallpaperResources.apk."; fi
    else
      echo "Original OPWallpaperResources.apk not found at $TARGET_APK_PATH (might be already deleted or path is wrong, proceeding)."
    fi

    if [ ! -f "$SOURCE_APK_PATH" ]; then
      echo "Error: Custom OPWallpaperResources.apk not found at source: $SOURCE_APK_PATH. Cannot replace."
    else
      echo "Copying custom OPWallpaperResources.apk from $SOURCE_APK_PATH to $TARGET_APK_DIR"
      sudo cp "$SOURCE_APK_PATH" "$TARGET_APK_DIR/"
      if [ $? -ne 0 ]; then echo "Failed to copy custom OPWallpaperResources.apk."; fi
      echo "OPWallpaperResources.apk replaced successfully."

      sudo chown 0:0 "$TARGET_APK_PATH"
      sudo chmod 0644 "$TARGET_APK_PATH"
      echo "Permissions for $TARGET_APK_PATH set."
    fi
  fi
  echo "OPWallpaperResources.apk modification complete for system_ext.img."

  # Modify OPSystemUI.apk (within mounted system_ext.img)
  log_step 8.1 "Modifying OPSystemUI.apk within mounted system_ext.img"
  APK_PATH="${SYSTEM_EXT_MOUNT_POINT}/priv-app/OPSystemUI/OPSystemUI.apk"
  DECOMPILED_DIR="${ROM_ROOT}/OPSystemUI_decompiled"

  if [ ! -f "$APK_PATH" ]; then
    echo "Error: OPSystemUI.apk not found at $APK_PATH. Skipping OPSystemUI.apk modification."
  else
    echo "Decompiling $APK_PATH..."
    sudo apktool d -f "$APK_PATH" -o "$DECOMPILED_DIR"
    if [ $? -ne 0 ]; then echo "Apktool decompilation failed for OPSystemUI.apk."; unmount_image "$SYSTEM_EXT_MOUNT_POINT" "$SYSTEM_EXT_LOOP_DEV"; exit 1; fi

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
    NEW_SMALI_FILE="${MY_G2_FOR_SYSTEMUI_DIR}/OpCustomizeSettingsG2.smali" 

    if [ ! -d "$TARGET_SMALI_DIR" ]; then
      echo "Error: Target Smali directory not found: $TARGET_SMALI_DIR"
      echo "Please verify the 'smali_classesX' folder (e.g., smali_classes2) or the path 'com/oneplus/custom/utils' within OPSystemUI.apk's decompiled structure."
    else
      if [ -f "$ORIGINAL_SMALI_FILE" ]; then
        echo "Deleting original OpCustomizeSettingsG2.smali: $ORIGINAL_SMALI_FILE"
        sudo rm "$ORIGINAL_SMALI_FILE"
        if [ $? -ne 0 ]; then echo "Failed to delete original OpCustomizeSettingsG2.smali."; fi
      else
        echo "Original OpCustomizeSettingsG2.smali not found at $ORIGINAL_SMALI_FILE (might be already deleted or path is wrong, proceeding)."
      fi

      if [ ! -f "$NEW_SMALI_FILE" ]; then
        echo "Error: New OpCustomizeSettingsG2.smali not found at source: $NEW_SMALI_FILE"
        echo "Please ensure '$NEW_SMALI_FILE' is in your repository and accessible."
      else
        echo "Copying new OpCustomizeSettingsG2.smali from $NEW_SMALI_FILE to $TARGET_SMALI_DIR"
        sudo cp "$NEW_SMALI_FILE" "$TARGET_SMALI_DIR/"
        if [ $? -ne 0 ]; then echo "Failed to copy new OpCustomizeSettingsG2.smali."; fi
        echo "OpCustomizeSettingsG2.smali replaced successfully."
      fi
    fi
    echo "Smali file replacement complete."

    PLUGIN_DEST_DIR="$DECOMPILED_DIR/smali_classes2/com/oneplus/plugin"
    echo "Replacing plugin files in $PLUGIN_DEST_DIR..."

    if [ ! -d "$PLUGIN_FILES_DIR" ]; then
      echo "Error: Source plugin directory '$PLUGIN_FILES_DIR' not found. Cannot replace plugin files."
    else
      if [ -d "$PLUGIN_DEST_DIR" ]; then
        sudo rm -rf "$PLUGIN_DEST_DIR"/*
      else
        sudo mkdir -p "$PLUGIN_DEST_DIR"
      fi

      sudo cp -r "$PLUGIN_FILES_DIR"/* "$PLUGIN_DEST_DIR/"
      if [ $? -ne 0 ]; then echo "Error: Failed to copy new plugin files."; fi
      echo "Plugin files replaced."
    fi

    echo "Recompiling OPSystemUI.apk..."
    # Recompile directly to the mounted image path
    sudo apktool b "$DECOMPILED_DIR" -o "$APK_PATH"
    if [ $? -ne 0 ]; then echo "Apktool recompilation failed for OPSystemUI.apk."; unmount_image "$SYSTEM_EXT_MOUNT_POINT" "$SYSTEM_EXT_LOOP_DEV"; exit 1; fi
    echo "OPSystemUI.apk recompiled and replaced in its original location."

    sudo rm -rf "$DECOMPILED_DIR"
    sudo chown 0:0 "$APK_PATH"
    sudo chmod 0644 "$APK_PATH"
    echo "Permissions for $APK_PATH set."
  fi
  echo "OPSystemUI.apk modification complete."

  # Modify Settings.apk (within mounted system_ext.img)
  log_step 8.2 "Modifying Settings.apk within mounted system_ext.img"
  SETTINGS_APK_DIR="${SYSTEM_EXT_MOUNT_POINT}/priv-app/Settings" # Assuming Settings.apk is here
  SETTINGS_APK_PATH="$SETTINGS_APK_DIR/Settings.apk"
  DECOMPILED_SETTINGS_DIR="${ROM_ROOT}/Settings_decompiled"

  if [ ! -f "$SETTINGS_APK_PATH" ]; then
    echo "Error: Settings.apk not found at $SETTINGS_APK_PATH. Skipping Settings.apk modification."
  else
    echo "Decompiling $SETTINGS_APK_PATH..."
    sudo apktool d -f "$SETTINGS_APK_PATH" -o "$DECOMPILED_SETTINGS_DIR"
    if [ $? -ne 0 ]; then echo "Apktool decompilation failed for Settings.apk."; unmount_image "$SYSTEM_EXT_MOUNT_POINT" "$SYSTEM_EXT_LOOP_DEV"; exit 1; fi

    echo "Applying smali modifications to OPUtils.smali..."

    OP_UTILS_FILE="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/settings/utils/OPUtils.smali"
    if [ -f "$OP_UTILS_FILE" ]; then
      echo "Modifying $OP_UTILS_FILE..."

      sudo sed -i -z '
        /\.method.*OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT/ {
          :a
          n
          /    move-result v0\n\n    return v0/ {
            s/\(    move-result v0\n\n\)    const\/4 v0, 0x0\n\n    return v0/\1    const\/4 v0, 0x1\n\n    return v0/
            b end_sed_block
          }
          ba
        }
        :end_sed_block
      ' "$OP_UTILS_FILE"
      
      if [ $? -ne 0 ]; then
        echo "Error: Smali modification for OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT failed."
      fi
      echo "Smali modification for OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT applied."

    else
      echo "Warning: OPUtils.smali not found at $OP_UTILS_FILE. Skipping modification."
    fi

    echo "Applying Smali file replacement for OpCustomizeSettingsG2.smali..."

    TARGET_SMALI_DIR_SETTINGS="$DECOMPILED_SETTINGS_DIR/smali_classes2/com/oneplus/custom/utils"
    ORIGINAL_SMALI_FILE_SETTINGS="$TARGET_SMALI_DIR_SETTINGS/OpCustomizeSettingsG2.smali"
    NEW_SMALI_FILE_SETTINGS="${MY_G2_FOR_SETTINGS_DIR}/OpCustomizeSettingsG2.smali"

    if [ ! -d "$TARGET_SMALI_DIR_SETTINGS" ]; then
      echo "Error: Target Smali directory not found for Settings.apk: $TARGET_SMALI_DIR_SETTINGS"
      echo "Please verify the 'smali_classesX' folder (e.g., smali_classes2) or the path 'com/oneplus/custom/utils' within Settings.apk's decompiled structure."
    else
      if [ -f "$ORIGINAL_SMALI_FILE_SETTINGS" ]; then
        echo "Deleting original OpCustomizeSettingsG2.smali: $ORIGINAL_SMALI_FILE_SETTINGS"
        sudo rm "$ORIGINAL_SMALI_FILE_SETTINGS"
        if [ $? -ne 0 ]; then echo "Failed to delete original OpCustomizeSettingsG2.smali."; fi
      else
        echo "Original OpCustomizeSettingsG2.smali not found at $ORIGINAL_SMALI_FILE_SETTINGS (might be already deleted or path is wrong, proceeding)."
      fi

      if [ ! -f "$NEW_SMALI_FILE_SETTINGS" ]; then
        echo "Error: New OpCustomizeSettingsG2.smali not found at source: $NEW_SMALI_FILE_SETTINGS"
        echo "Please ensure 'my_G2/OpCustomizeSettingsG2.smali' is in your repository and accessible."
      else
        echo "Copying new OpCustomizeSettingsG2.smali from $NEW_SMALI_FILE_SETTINGS to $TARGET_SMALI_DIR_SETTINGS"
        sudo cp "$NEW_SMALI_FILE_SETTINGS" "$TARGET_SMALI_DIR_SETTINGS/"
        if [ $? -ne 0 ]; then echo "Failed to copy new OpCustomizeSettingsG2.smali."; fi
        echo "OpCustomizeSettingsG2.smali replaced successfully."
      fi
    fi
    echo "Smali file replacement complete."

    echo "Recompiling Settings.apk..."
    sudo apktool b "$DECOMPILED_SETTINGS_DIR" -o "$SETTINGS_APK_PATH"
    if [ $? -ne 0 ]; then echo "Apktool recompilation failed for Settings.apk."; unmount_image "$SYSTEM_EXT_MOUNT_POINT" "$SYSTEM_EXT_LOOP_DEV"; exit 1; fi
    echo "Settings.apk recompiled and replaced in its original location."

    sudo rm -rf "$DECOMPILED_SETTINGS_DIR"

    sudo chown 0:0 "$SETTINGS_APK_PATH"
    sudo chmod 0644 "$SETTINGS_APK_PATH"
    echo "Permissions for $SETTINGS_APK_PATH set."
  fi
  echo "Settings.apk modification complete."

  unmount_image "$SYSTEM_EXT_MOUNT_POINT" "$SYSTEM_EXT_LOOP_DEV"
  echo ""
fi

# --- Proposed Step 4: Mount product.img, delete unwanted apps, sync, umount ---
log_step 9 "Mounting product.img, deleting unwanted apps, and unmounting"

PRODUCT_IMG_PATH="firmware_images/product.img"
PRODUCT_MOUNT_POINT="product_mount_point"

if [ ! -f "$PRODUCT_IMG_PATH" ]; then
  echo "Warning: product.img not found at $PRODUCT_IMG_PATH. Skipping this step."
  echo ""
else
  PRODUCT_LOOP_DEV=$(mount_image_rw "$PRODUCT_IMG_PATH" "$PRODUCT_MOUNT_POINT")
  if [ $? -ne 0 ]; then echo "Failed to mount product.img."; exit 1; fi

  declare -a PRODUCT_APP_PATHS=(
    "${PRODUCT_MOUNT_POINT}/app"
    "${PRODUCT_MOUNT_POINT}/priv-app"
  )

  for app_name in "${APPS_TO_REMOVE[@]}"; do # Re-use APPS_TO_REMOVE
    APP_FOUND=false
    for app_path_base in "${PRODUCT_APP_PATHS[@]}"; do
      TARGET_DIR="$app_path_base/$app_name"
      if [ -d "$TARGET_DIR" ]; then
        echo "Removing $TARGET_DIR from product.img..."
        sudo rm -rf "$TARGET_DIR"
        APP_FOUND=true
        break
      fi
    done
    if ! $APP_FOUND; then
      echo "Warning: App folder '$app_name' not found in product.img common directories. Skipping."
    fi
  done
  echo "Unwanted apps removal attempt complete for product.img."

  unmount_image "$PRODUCT_MOUNT_POINT" "$PRODUCT_LOOP_DEV"
  echo ""
fi

# --- Proposed Step 5: Create empty system_new.img ---
log_step 10 "Creating empty system_new.img"

TARGET_SYSTEM_IMG_SIZE_BYTES=3221225472 # 3.22 GB
SYSTEM_NEW_IMG_NAME="system_new.img"

echo "Creating an empty EXT4 image file: $SYSTEM_NEW_IMG_NAME with size ${TARGET_SYSTEM_IMG_SIZE_BYTES} bytes."
# Create an empty file first, then format it.
dd if=/dev/zero of="$SYSTEM_NEW_IMG_NAME" bs=1 count=0 seek="$TARGET_SYSTEM_IMG_SIZE_BYTES"
if [ $? -ne 0 ]; then echo "Error: Failed to create empty file for system_new.img."; exit 1; fi

sudo mkfs.ext4 -L system "$SYSTEM_NEW_IMG_NAME"
if [ $? -ne 0 ]; then echo "Error: Failed to format $SYSTEM_NEW_IMG_NAME as ext4."; exit 1; fi

echo "$SYSTEM_NEW_IMG_NAME created."
echo ""

# --- Proposed Step 6: Mount system_new.img and system.img, then copy system.img contents ---
log_step 11 "Mounting system_new.img and system.img, then copying system.img contents"

SYSTEM_NEW_IMG_PATH="$SYSTEM_NEW_IMG_NAME"
SYSTEM_NEW_MOUNT_POINT="system_new_mount_point"
SYSTEM_IMG_PATH="firmware_images/system.img"
SYSTEM_ORIGINAL_MOUNT_POINT="system_original_mount_point"

if [ ! -f "$SYSTEM_NEW_IMG_PATH" ]; then
  echo "Error: system_new.img not found. Cannot proceed."
  exit 1
fi
if [ ! -f "$SYSTEM_IMG_PATH" ]; then
  echo "Error: system.img not found at $SYSTEM_IMG_PATH. Cannot proceed."
  exit 1
fi

SYSTEM_NEW_LOOP_DEV=$(mount_image_rw "$SYSTEM_NEW_IMG_PATH" "$SYSTEM_NEW_MOUNT_POINT")
if [ $? -ne 0 ]; then echo "Failed to mount system_new.img."; exit 1; fi

SYSTEM_ORIGINAL_LOOP_DEV=$(mount_image_rw "$SYSTEM_IMG_PATH" "$SYSTEM_ORIGINAL_MOUNT_POINT")
if [ $? -ne 0 ]; then echo "Failed to mount system.img for copying."; exit 1; fi

echo "Copying contents from $SYSTEM_ORIGINAL_MOUNT_POINT to $SYSTEM_NEW_MOUNT_POINT/..."
sudo cp -a "$SYSTEM_ORIGINAL_MOUNT_POINT/." "$SYSTEM_NEW_MOUNT_POINT/"
if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from system.img to system_new.img."; exit 1; fi
echo "Contents copied successfully."

unmount_image "$SYSTEM_ORIGINAL_MOUNT_POINT" "$SYSTEM_ORIGINAL_LOOP_DEV"
echo "system.img unmounted."
echo "system_new.img remains mounted."
echo ""

# --- Proposed Step 7: Mount system_ext.img, copy to system_new, then unmount system_ext.img ---
log_step 12 "Mounting system_ext.img, copying to system_new.img"

SYSTEM_EXT_IMG_PATH="firmware_images/system_ext.img"
SYSTEM_EXT_ORIGINAL_MOUNT_POINT="system_ext_original_mount_point"

if [ ! -f "$SYSTEM_EXT_IMG_PATH" ]; then
  echo "Warning: system_ext.img not found at $SYSTEM_EXT_IMG_PATH. Skipping this copy step."
  echo ""
else
  SYSTEM_EXT_ORIGINAL_LOOP_DEV=$(mount_image_rw "$SYSTEM_EXT_IMG_PATH" "$SYSTEM_EXT_ORIGINAL_MOUNT_POINT")
  if [ $? -ne 0 ]; then echo "Failed to mount system_ext.img for copying."; exit 1; fi

  echo "Copying contents from $SYSTEM_EXT_ORIGINAL_MOUNT_POINT to $SYSTEM_NEW_MOUNT_POINT/system_ext/..."
  sudo mkdir -p "${SYSTEM_NEW_MOUNT_POINT}/system_ext" # Create destination directory if it doesn't exist
  sudo cp -a "$SYSTEM_EXT_ORIGINAL_MOUNT_POINT/." "${SYSTEM_NEW_MOUNT_POINT}/system_ext/"
  if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from system_ext.img to system_new.img."; exit 1; fi
  echo "Contents copied successfully."

  unmount_image "$SYSTEM_EXT_ORIGINAL_MOUNT_POINT" "$SYSTEM_EXT_ORIGINAL_LOOP_DEV"
  echo "system_ext.img unmounted."
  echo "system_new.img remains mounted."
  echo ""
fi

# --- Proposed Step 8: Mount product.img, copy to system_new, then unmount product.img ---
log_step 13 "Mounting product.img, copying to system_new.img"

PRODUCT_IMG_PATH="firmware_images/product.img"
PRODUCT_ORIGINAL_MOUNT_POINT="product_original_mount_point"

if [ ! -f "$PRODUCT_IMG_PATH" ]; then
  echo "Warning: product.img not found at $PRODUCT_IMG_PATH. Skipping this copy step."
  echo ""
else
  PRODUCT_ORIGINAL_LOOP_DEV=$(mount_image_rw "$PRODUCT_IMG_PATH" "$PRODUCT_ORIGINAL_MOUNT_POINT")
  if [ $? -ne 0 ]; then echo "Failed to mount product.img for copying."; exit 1; fi

  echo "Copying contents from $PRODUCT_ORIGINAL_MOUNT_POINT to $SYSTEM_NEW_MOUNT_POINT/product/..."
  sudo mkdir -p "${SYSTEM_NEW_MOUNT_POINT}/product" # Create destination directory if it doesn't exist
  sudo cp -a "$PRODUCT_ORIGINAL_MOUNT_POINT/." "${SYSTEM_NEW_MOUNT_POINT}/product/"
  if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from product.img to system_new.img."; exit 1; fi
  echo "Contents copied successfully."

  unmount_image "$PRODUCT_ORIGINAL_MOUNT_POINT" "$PRODUCT_ORIGINAL_LOOP_DEV"
  echo "product.img unmounted."
  echo "system_new.img remains mounted."
  echo ""
fi

# --- Prepare Reserve Partition and Create Image ---
log_step 14 "Preparing Reserve Partition and Creating Image"
# Ensure make_ext4fs is executable from current directory
chmod +x make_ext4fs
# Add the current directory to PATH so make_ext4fs can be found
export PATH="$(pwd):$PATH"
echo "make_ext4fs from repository root is ready."

OLD_RESERVE_SOURCE_DIR="${SYSTEM_NEW_MOUNT_POINT}/system/reserve" # Adjusted to new system.img
NEW_RESERVE_WORKSPACE_DIR="${ROM_ROOT}/reserve_new"
CUST_MOUNTPOINT_DIR="${SYSTEM_NEW_MOUNT_POINT}/cust" # Adjusted to new system.img
SYMLINK_TARGET_DIR="${SYSTEM_NEW_MOUNT_POINT}/system/reserve" # Adjusted to new system.img

echo "1. Copying contents from $OLD_RESERVE_SOURCE_DIR to $NEW_RESERVE_WORKSPACE_DIR..."
sudo mkdir -p "$NEW_RESERVE_WORKSPACE_DIR"
if [ -d "$OLD_RESERVE_SOURCE_DIR" ]; then
  sudo cp -r "$OLD_RESERVE_SOURCE_DIR"/* "$NEW_RESERVE_WORKSPACE_DIR/"
  echo "   Contents copied to $NEW_RESERVE_WORKSPACE_DIR."
else
  echo "   Warning: Original reserve directory ($OLD_RESERVE_SOURCE_DIR) not found. Proceeding assuming $NEW_RESERVE_WORKSPACE_DIR is already populated."
  echo "   Ensure your apps are copied to $NEW_RESERVE_WORKSPACE_DIR by an earlier step if needed."
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
  make_ext4fs -s -J -T 0 -L cust -l $IMAGE_SIZE_BYTES -a cust "$NEW_RESERVE_WORKSPACE_DIR.img" "$NEW_RESERVE_WORKSPACE_DIR"
  if [ $? -ne 0 ]; then 
    echo "   Error: Failed to create reserve_new.img using make_ext4fs. Please check the tool's output for details."
    unmount_image "$SYSTEM_NEW_MOUNT_POINT" "$SYSTEM_NEW_LOOP_DEV" # Clean up
    exit 1
  fi
  echo "   reserve_new.img created at $NEW_RESERVE_WORKSPACE_DIR.img"
else
  echo "   Error: 'make_ext4fs' command not found. This tool is essential for creating the image."
  echo "   Please add a preceding step in your workflow to install Android build tools (like \`apt-get install android-sdk-platform-tools-core\`). Aborting."
  unmount_image "$SYSTEM_NEW_MOUNT_POINT" "$SYSTEM_NEW_LOOP_DEV" # Clean up
  exit 1
fi

echo "4. Preparing $CUST_MOUNTPOINT_DIR (empty mount point) in system.img..."
sudo mkdir -p "$CUST_MOUNTPOINT_DIR"
sudo rm -rf "$CUST_MOUNTPOINT_DIR"/*
echo "   Mount point directory $CUST_MOUNTPOINT_DIR prepared as empty."

echo "5. Creating symlinks in $SYMLINK_TARGET_DIR pointing to $CUST_MOUNTPOINT_DIR..."
sudo mkdir -p "$SYMLINK_TARGET_DIR"
sudo rm -rf "$SYMLINK_TARGET_DIR"/*

find "$NEW_RESERVE_WORKSPACE_DIR" -maxdepth 1 -mindepth 1 -type d | while read -r app_folder_path; do
    dirname=$(basename "$app_folder_path")

    sudo ln -s "$CUST_MOUNTPOINT_DIR/$dirname" "$SYMLINK_TARGET_DIR/$dirname"
    if [ $? -ne 0 ]; then 
      echo "   Warning: Failed to create symlink for directory $dirname. This might cause issues if the app relies on it."
    fi
done
echo "   Folder symlinks created in $SYMLINK_TARGET_DIR."

echo "All reserve partition preparation and image creation steps complete."
echo ""

# --- Step: Rename Reserve Image ---
log_step 15 "Renaming Reserve Image"
OLD_IMG_PATH="${ROM_ROOT}/reserve_new.img"
NEW_IMG_PATH="${ROM_ROOT}/reserve.img"

echo "Renaming $OLD_IMG_PATH to $NEW_IMG_PATH..."
if [ -f "$OLD_IMG_PATH" ]; then
  sudo mv "$OLD_IMG_PATH" "$NEW_IMG_PATH"
  echo "Image successfully renamed."
else
  echo "Error: $OLD_IMG_PATH not found for renaming. Ensure the previous step created it correctly."
  unmount_image "$SYSTEM_NEW_MOUNT_POINT" "$SYSTEM_NEW_LOOP_DEV" # Clean up
  exit 1
fi
echo ""


# --- Proposed Step 9: Final sync and unmount system_new.img ---
log_step 16 "Final sync and unmount of system_new.img"

unmount_image "$SYSTEM_NEW_MOUNT_POINT" "$SYSTEM_NEW_LOOP_DEV"
echo "system_new.img unmounted and synced."
echo ""


# --- Step: Convert system.img to system.new.dat.br, system.transfer.list ---
log_step 17 "Converting system.img to system.new.dat.br, system.transfer.list"
echo "Cloning img2sdat tools..."
git clone https://github.com/IsHacker003/img2sdat.git --depth=1 img2sdat_tools
if [ ! -d "img2sdat_tools" ]; then echo "Failed to clone img2sdat tools."; exit 1; fi

mkdir -p test
echo "Converting system_new.img to system.new.dat, system.patch.dat and system.transfer.list..."
python3 img2sdat_tools/img2sdat.py "$SYSTEM_NEW_IMG_NAME" -o test -v 4 # Use system_new.img here
if [ $? -ne 0 ]; then echo "img2sdat.py failed."; exit 1; fi

echo "Compressing system.new.dat to system.new.dat.br..."
brotli -q 11 test/system.new.dat -o test/system.new.dat.br
if [ $? -ne 0 ]; then echo "Brotli compression failed."; exit 1; fi
rm test/system.new.dat

echo "Generated system.new.dat.br and system.transfer.list."
echo ""

# --- Step: Zip Final Files for Release ---
log_step 18 "Zipping Final Files for Release"
BUILD_DATE=$(date +%Y%m%d)
ROM_FILENAME="OnePlus-Port-ROM-$BUILD_DATE.zip"
RESERVE_IMG_PATH="${ROM_ROOT}/reserve.img"
ROM_ZIP_PATH="test/$ROM_FILENAME" 
echo "Zipping final files into $ROM_ZIP_PATH..."
zip -r "$ROM_ZIP_PATH" test/system.new.dat.br test/system.patch.dat test/system.transfer.list "$RESERVE_IMG_PATH"
if [ $? -ne 0 ]; then echo "Zipping failed."; exit 1; fi
echo "ROM_ZIP_PATH=$ROM_ZIP_PATH" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo "ROM_FILENAME=$ROM_FILENAME" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo "$ROM_ZIP_PATH created."
echo ""

# --- Step: Prepare Release Tag Name (for manual trigger) ---
log_step 19 "Preparing Release Tag Name"
ROM_BASE_NAME=$(basename "${ROM_FILENAME}" .zip)
RELEASE_TAG="release-${ROM_BASE_NAME}-$(date +%Y%m%d%H%M%S)-${GITHUB_RUN_NUMBER}"
echo "Generated tag for manual release: "$RELEASE_TAG"..."
echo "release_tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT" # For GitHub Actions to pick up
echo "RELEASE_TAG=$RELEASE_TAG" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo ""

# --- Final Cleanup ---
log_step 20 "Final Cleanup"
echo "Cleaning up workspace..."
sudo rm -rf firmware_images system_mount_point system_ext_mount_point product_mount_point system_original_mount_point system_ext_original_mount_point product_original_mount_point system_new_mount_point services_decompiled OPSystemUI_decompiled Settings_decompiled img2sdat_tools *.img *.dat *.br "$NEW_RESERVE_WORKSPACE_DIR"
echo "Cleanup complete."
echo ""

echo "Android ROM Porting script finished successfully!"
