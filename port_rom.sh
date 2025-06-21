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

# --- List of Unwanted Apps ---
# Add the folder names of the applications you wish to remove.
# These are typically found under /system/app, /system/priv-app, /system_ext/app, etc.
# IMPORTANT: Be extremely careful! Removing essential system apps can break your ROM.
UNWANTED_APPS=(
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

# --- Helper function for mounting and unmounting ---
# This function now accepts an optional 'read_only' parameter ("ro" for read-only, empty for read-write)
# IMPORTANT: All informational echoes are now redirected to stderr (>&2)
# so that only the loop device path is returned to stdout for variable assignment.
mount_image() {
  local img_path="$1"
  local mount_point="$2"
  local read_only_flag="$3" # "ro" for read-only, "" for read-write

  sudo mkdir -p "$mount_point" >&2
  LOOP_DEV=$(sudo losetup -f --show "$img_path")
  if [ -z "$LOOP_DEV" ]; then echo "Error: Failed to assign loop device for $img_path." >&2; return 1; fi
  echo "Loop device assigned: $LOOP_DEV" >&2

  MOUNT_CMD="sudo mount -t ext4" # Explicitly specifying ext4 for reliability
  if [ -n "$read_only_flag" ]; then
    MOUNT_CMD+=" -o $read_only_flag"
  fi
  MOUNT_CMD+=" \"$LOOP_DEV\" \"$mount_point\""

  eval "$MOUNT_CMD"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to mount $img_path. Unmounting loop device." >&2
    sudo losetup -d "$LOOP_DEV" >&2 # Ensure detach even on mount failure
    return 1
  fi
  echo "$img_path mounted to $mount_point." >&2
  if [ -n "$read_only_flag" ]; then
    echo "  (Mounted Read-Only as requested)" >&2
  fi
  echo "$LOOP_DEV" # Only this line should go to stdout to be captured by the calling script
}

unmount_image() {
  local mount_point="$1"
  local loop_dev="$2"
  sudo sync
  echo "Syncing $mount_point..." >&2 # Redirect to stderr
  sudo umount "$mount_point"
  if [ $? -ne 0 ]; then echo "Error: Failed to unmount $mount_point." >&2; return 1; fi # Redirect to stderr
  echo "Unmounted $mount_point." >&2 # Redirect to stderr
  sudo losetup -d "$loop_dev"
  if [ $? -ne 0 ]; then echo "Error: Failed to detach loop device $loop_dev." >&2; return 1; fi # Redirect to stderr
  echo "Detached loop device $loop_dev." >&2 # Redirect to stderr
  sudo rmdir "$mount_point" 2>/dev/null || true # Remove if empty, suppress error if not
  echo "Cleaned up $mount_point directory." >&2 # Redirect to stderr
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
echo "Downloaded firmware: "$FIRMWARE_FILENAME""
echo ""

# --- Step: Extract Firmware ---
log_step 3 "Extracting Firmware Archive"
mkdir -p firmware_extracted
echo "Extracting "$FIRMWARE_FILENAME"..."
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

  echo "Cloning https://github.com/vm03/payload_dumper.git into "$PAYLOAD_DUMPER_DIR"..."
  git clone https://github.com/vm03/payload_dumper.git "$PAYLOAD_DUMPER_DIR"
  if [ ! -d "$PAYLOAD_DUMPER_DIR" ]; then
    echo "Error: Failed to clone vm03/payload_dumper repository."
    exit 1
  fi

  if [ -f "$PAYLOAD_DUMPER_DIR/requirements.txt" ]; then
    echo "Installing payload_dumper requirements from "$PAYLOAD_DUMPER_DIR"/requirements.txt..."
    python3 -m pip install -r "$PAYLOAD_DUMPER_DIR/requirements.txt"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to install payload_dumper requirements."
      rm -rf "$PAYLOAD_DUMPER_DIR"
      exit 1
    fi
  else
    echo "Warning: No requirements.txt found in "$PAYLOAD_DUMPER_DIR". Skipping pip install for this repo."
  fi

  echo "Running payload_dumper.py from "$PAYLOAD_DUMPER_DIR"/payload_dumper.py..."
  python3 "$PAYLOAD_DUMPER_DIR/payload_dumper.py" firmware_extracted/payload.bin
  
  if [ $? -ne 0 ]; then
      echo "Error: payload_dumper.py failed to extract images."
      rm -rf "$PAYLOAD_DUMPER_DIR"
      exit 1
  fi
  
  echo "Images extracted from payload.bin to output/"
  
  # --- Consolidate and Select Required Images ---
  log_step 5 "Consolidating and Selecting Required Images"
  REQUIRED_IMAGES=("system.img" "product.img" "system_ext.img" "odm.img" "vendor.img" "boot.img")
  OPTIONAL_IMAGES=("opproduct.img")
  ALL_IMAGES_FOUND=true
  TARGET_IMG_DIR="firmware_images" # Use a consistent directory for all image files
  mkdir -p "$TARGET_IMG_DIR"

  for img in "${REQUIRED_IMAGES[@]}"; do
    if [ -f "output/$img" ]; then
      echo "Found "$img""
      mv "output/$img" "$TARGET_IMG_DIR/"
    else
      echo "Warning: Required image "$img" not found in output/."
      ALL_IMAGES_FOUND=false
    fi
  done

  for img in "${OPTIONAL_IMAGES[@]}"; do
    if [ -f "output/$img" ]; then
      echo "Found optional image "$img""
      mv "output/$img" "$TARGET_IMG_DIR/"
    else
      echo "Optional image "$img" not found in output/."
    fi
  done
  
  if ! $ALL_IMAGES_FOUND; then
    echo "Error: One or more required images were not found after payload.bin extraction. Exiting."
    exit 1
  fi
  echo "Required and optional images moved to "$TARGET_IMG_DIR"/."
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
      echo "Found direct image file: "$(basename "$img_file")""
      mv "$img_file" "$TARGET_IMG_DIR/"
    fi
  done
  echo "Image files moved to "$TARGET_IMG_DIR"/."
fi
echo ""

log_step 6 "Cleaning up initial downloaded files"
sudo rm -f "$FIRMWARE_FILENAME" # This is the downloaded zip/archive
sudo rm -rf firmware_extracted # Remove the extraction dir completely
echo "Deleted downloaded firmware archive and firmware_extracted directory."
echo ""

# --- NEW Proposed Step Flow: Create, Copy, Merge, then Modify ---

# --- Create empty system_new.img ---
log_step 7 "Creating empty system_new.img (5.22 GB)" # Renamed from 10
TARGET_SYSTEM_IMG_SIZE_BYTES=5072 # 5.22 GB as requested
SYSTEM_NEW_IMG_NAME="system_new.img"

echo "Creating an empty EXT4 image file: "$SYSTEM_NEW_IMG_NAME" with size ${TARGET_SYSTEM_IMG_SIZE_BYTES} bytes."
# Create an empty file first, then format it.
dd if=/dev/zero of="$SYSTEM_NEW_IMG_NAME" bs=1M count="$TARGET_SYSTEM_IMG_SIZE_BYTES"
if [ $? -ne 0 ]; then echo "Error: Failed to create empty file for system_new.img."; exit 1; fi

sudo mkfs.ext4 -L system "$SYSTEM_NEW_IMG_NAME"
if [ $? -ne 0 ]; then echo "Error: Failed to format "$SYSTEM_NEW_IMG_NAME" as ext4."; exit 1; fi

sudo tune2fs -c0 -i0 "$SYSTEM_NEW_IMG_NAME"
if [ $? -ne 0 ]; then echo "Error: Failed to disable automatic filesystem checks for system_new.img."; exit 1; fi

echo ""$SYSTEM_NEW_IMG_NAME" created."
echo ""

# --- Mount system_new.img and original images, then copy contents ---
log_step 8 "Mounting images and copying contents to system_new.img" # Renamed from 11/12/13

SYSTEM_NEW_IMG_PATH="$SYSTEM_NEW_IMG_NAME"
SYSTEM_NEW_MOUNT_POINT="system_new_final_mount_point" # This will become the main mount point for modifications later

# Mount system_new.img (read-write as destination)
SYSTEM_NEW_LOOP_DEV=$(mount_image "$SYSTEM_NEW_IMG_PATH" "$SYSTEM_NEW_MOUNT_POINT" "") # "" for read-write
if [ $? -ne 0 ]; then echo "Failed to mount "$SYSTEM_NEW_IMG_PATH". Exiting."; exit 1; fi
echo ""$SYSTEM_NEW_IMG_PATH" mounted to "$SYSTEM_NEW_MOUNT_POINT"."

# Copy from original system.img
ORIGINAL_SYSTEM_IMG_PATH="firmware_images/system.img"
ORIGINAL_SYSTEM_MOUNT_POINT="original_system_mount_point"
if [ -f "$ORIGINAL_SYSTEM_IMG_PATH" ]; then
    echo "Mounting "$ORIGINAL_SYSTEM_IMG_PATH" for copying (Read-Only as requested)..."
    ORIGINAL_SYSTEM_LOOP_DEV=$(mount_image "$ORIGINAL_SYSTEM_IMG_PATH" "$ORIGINAL_SYSTEM_MOUNT_POINT" "ro") # "ro" for read-only
    if [ $? -ne 0 ]; then echo "Failed to mount "$ORIGINAL_SYSTEM_IMG_PATH". Skipping copy from it."; else
        echo "Copying contents from "$ORIGINAL_SYSTEM_MOUNT_POINT" to "$SYSTEM_NEW_MOUNT_POINT"/..."
        sudo cp -a "$ORIGINAL_SYSTEM_MOUNT_POINT/." "$SYSTEM_NEW_MOUNT_POINT/"
        if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from "$ORIGINAL_SYSTEM_IMG_PATH"."; exit 1; fi
        echo "Contents copied successfully from "$ORIGINAL_SYSTEM_IMG_PATH"."
        unmount_image "$ORIGINAL_SYSTEM_MOUNT_POINT" "$ORIGINAL_SYSTEM_LOOP_DEV"
        echo ""$ORIGINAL_SYSTEM_IMG_PATH" unmounted."
    fi
else
    echo "Warning: "$ORIGINAL_SYSTEM_IMG_PATH" not found. Skipping copy from it."
fi

# Copy from original system_ext.img
ORIGINAL_SYSTEM_EXT_IMG_PATH="firmware_images/system_ext.img"
ORIGINAL_SYSTEM_EXT_MOUNT_POINT="original_system_ext_mount_point"
if [ -f "$ORIGINAL_SYSTEM_EXT_IMG_PATH" ]; then
    echo "Mounting "$ORIGINAL_SYSTEM_EXT_IMG_PATH" for copying (Read-Only as requested)..."
    ORIGINAL_SYSTEM_EXT_LOOP_DEV=$(mount_image "$ORIGINAL_SYSTEM_EXT_IMG_PATH" "$ORIGINAL_SYSTEM_EXT_MOUNT_POINT" "ro") # "ro" for read-only
    if [ $? -ne 0 ]; then echo "Failed to mount "$ORIGINAL_SYSTEM_EXT_IMG_PATH". Skipping copy from it."; else
        echo "Copying contents from "$ORIGINAL_SYSTEM_EXT_MOUNT_POINT" to "$SYSTEM_NEW_MOUNT_POINT"/system_ext/..."
        sudo mkdir -p "${SYSTEM_NEW_MOUNT_POINT}/system_ext" # Ensure destination exists
        sudo cp -a "$ORIGINAL_SYSTEM_EXT_MOUNT_POINT/." "${SYSTEM_NEW_MOUNT_POINT}/system_ext/"
        if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from "$ORIGINAL_SYSTEM_EXT_IMG_PATH"."; exit 1; fi
        echo "Contents copied successfully from "$ORIGINAL_SYSTEM_EXT_IMG_PATH"."
        unmount_image "$ORIGINAL_SYSTEM_EXT_MOUNT_POINT" "$ORIGINAL_SYSTEM_EXT_LOOP_DEV"
        echo ""$ORIGINAL_SYSTEM_EXT_IMG_PATH" unmounted."
    fi
else
    echo "Warning: "$ORIGINAL_SYSTEM_EXT_IMG_PATH" not found. Skipping copy from it."
fi

# Copy from original product.img
ORIGINAL_PRODUCT_IMG_PATH="firmware_images/product.img"
ORIGINAL_PRODUCT_MOUNT_POINT="original_product_mount_point"
if [ -f "$ORIGINAL_PRODUCT_IMG_PATH" ]; then
    echo "Mounting "$ORIGINAL_PRODUCT_IMG_PATH" for copying (Read-Only as requested)..."
    ORIGINAL_PRODUCT_LOOP_DEV=$(mount_image "$ORIGINAL_PRODUCT_IMG_PATH" "$ORIGINAL_PRODUCT_MOUNT_POINT" "ro") # "ro" for read-only
    if [ $? -ne 0 ]; then echo "Failed to mount "$ORIGINAL_PRODUCT_IMG_PATH". Skipping copy from it."; else
        echo "Copying contents from "$ORIGINAL_PRODUCT_MOUNT_POINT" to "$SYSTEM_NEW_MOUNT_POINT"/product/..."
        sudo mkdir -p "${SYSTEM_NEW_MOUNT_POINT}/product" # Ensure destination exists
        sudo cp -a "$ORIGINAL_PRODUCT_MOUNT_POINT/." "${SYSTEM_NEW_MOUNT_POINT}/product/"
        if [ $? -ne 0 ]; then echo "Error: Failed to copy contents from "$ORIGINAL_PRODUCT_IMG_PATH"."; exit 1; fi
        echo "Contents copied successfully from "$ORIGINAL_PRODUCT_IMG_PATH"."
        unmount_image "$ORIGINAL_PRODUCT_MOUNT_POINT" "$ORIGINAL_PRODUCT_LOOP_DEV"
        echo ""$ORIGINAL_PRODUCT_IMG_PATH" unmounted."
    fi
else
    echo "Warning: "$ORIGINAL_PRODUCT_IMG_PATH" not found. Skipping copy from it."
fi

echo "All specified images copied to "$SYSTEM_NEW_MOUNT_POINT"."

# --- Unmount the final system_new.img now that copying is done ---
log_step 9 "Syncing and Unmounting the newly created system_new.img" # Renamed from 16
unmount_image "$SYSTEM_NEW_MOUNT_POINT" "$SYSTEM_NEW_LOOP_DEV"
echo ""$SYSTEM_NEW_IMG_NAME" unmounted."
echo ""

# --- Clean up original images and rename the new one ---
log_step 10 "Cleaning up original images and renaming system_new.img to system.img" # New step

echo "Deleting original system.img, system_ext.img, product.img from firmware_images/..."
sudo rm -f firmware_images/system.img
sudo rm -f firmware_images/system_ext.img
sudo rm -f firmware_images/product.img
echo "Original images deleted."
echo "Renaming "$SYSTEM_NEW_IMG_NAME" to system.img..."
sudo mv "$SYSTEM_NEW_IMG_NAME" "firmware_images/system.img" # Move to firmware_images dir for consistency
SYSTEM_IMG_PATH="firmware_images/system.img" # Update path to point to the new, renamed image
echo "system_new.img renamed to system.img."
echo ""

# --- Mount the new system.img (which was system_new.img) for modifications ---
log_step 11 "Mounting the new system.img for modifications" # New step
SYSTEM_MOUNT_POINT="system_mount_point" # Re-use this mount point for the main image
SYSTEM_LOOP_DEV=$(mount_image "$SYSTEM_IMG_PATH" "$SYSTEM_MOUNT_POINT" "") # "" for read-write
if [ $? -ne 0 ]; then echo "Failed to mount the new system.img for modifications. Exiting."; exit 1; fi
echo "New system.img mounted to "$SYSTEM_MOUNT_POINT" for modifications."
echo ""

# --- NEW: Apktool Framework Setup ---
log_step 12 "Apktool Framework Setup" # New step, renumbering subsequent
echo "Emptying Apktool framework directory to ensure a clean slate..."
sudo apktool empty-framework-dir
if [ $? -eq 0 ]; then
  echo "Apktool framework directory cleared successfully."
else
  echo "Warning: apktool empty-framework-dir command completed with a non-zero exit code. This might indicate nothing was there to clean, or a minor issue. Proceeding."
fi
echo "Installing Apktool frameworks..."
FRAMEWORK_APK="${SYSTEM_MOUNT_POINT}/system/framework/framework-res.apk" # Correct path
if [ -f "$FRAMEWORK_APK" ]; then
  sudo apktool if "$FRAMEWORK_APK"
  if [ $? -ne 0 ]; then
    echo "Apktool framework installation failed! Check framework-res.apk path and file integrity."; exit 1;
  fi
  echo "Apktool framework installed successfully from "$FRAMEWORK_APK"."
else
  echo "Error: framework-res.apk not found at "$FRAMEWORK_APK". Apktool framework cannot be installed. Exiting."; exit 1;
fi
echo ""

# --- Step: Mount other images (product, system_ext, vendor, odm) ---
log_step 13 "Mounting other images for read-only access" # Renamed from 14

PRODUCT_IMG_PATH="firmware_images/product.img"
PRODUCT_MOUNT_POINT="product_mount_point"
if [ -f "$PRODUCT_IMG_PATH" ]; then
    PRODUCT_LOOP_DEV=$(mount_image "$PRODUCT_IMG_PATH" "$PRODUCT_MOUNT_POINT" "ro")
    if [ $? -ne 0 ]; then echo "Failed to mount "$PRODUCT_IMG_PATH"."; fi
else
    echo "Warning: "$PRODUCT_IMG_PATH" not found."
fi

SYSTEM_EXT_IMG_PATH="firmware_images/system_ext.img"
SYSTEM_EXT_MOUNT_POINT="system_ext_mount_point"
if [ -f "$SYSTEM_EXT_IMG_PATH" ]; then
    SYSTEM_EXT_LOOP_DEV=$(mount_image "$SYSTEM_EXT_IMG_PATH" "$SYSTEM_EXT_MOUNT_POINT" "ro")
    if [ $? -ne 0 ]; then echo "Failed to mount "$SYSTEM_EXT_IMG_PATH"."; fi
else
    echo "Warning: "$SYSTEM_EXT_IMG_PATH" not found."
fi

VENDOR_IMG_PATH="firmware_images/vendor.img"
VENDOR_MOUNT_POINT="vendor_mount_point"
if [ -f "$VENDOR_IMG_PATH" ]; then
    VENDOR_LOOP_DEV=$(mount_image "$VENDOR_IMG_PATH" "$VENDOR_MOUNT_POINT" "ro")
    if [ $? -ne 0 ]; then echo "Failed to mount "$VENDOR_IMG_PATH"."; fi
else
    echo "Warning: "$VENDOR_IMG_PATH" not found."
fi

ODM_IMG_PATH="firmware_images/odm.img"
ODM_MOUNT_POINT="odm_mount_point"
if [ -f "$ODM_IMG_PATH" ]; then
    ODM_LOOP_DEV=$(mount_image "$ODM_IMG_PATH" "$ODM_MOUNT_POINT" "ro")
    if [ $? -ne 0 ]; then echo "Failed to mount "$ODM_IMG_PATH"."; fi
else
    echo "Warning: "$ODM_IMG_PATH" not found."
fi

echo "Other images mounted."
echo ""

# --- Step: Remove Unwanted Apps ---
log_step 14 "Removing Unwanted Apps" # Renamed from 7

UNWANTED_APP_COUNT=0
# Loop through the UNWANTED_APPS array and remove them
for app_folder in "${UNWANTED_APPS[@]}"; do
    FOUND_APP=false
    # Search in common app locations within the mounted system
    for app_path in \
        "${SYSTEM_MOUNT_POINT}/system/app/${app_folder}" \
        "${SYSTEM_MOUNT_POINT}/system/priv-app/${app_folder}" \
        "${SYSTEM_MOUNT_POINT}/system_ext/app/${app_folder}" \
        "${SYSTEM_MOUNT_POINT}/system_ext/priv-app/${app_folder}" \
        "${SYSTEM_MOUNT_POINT}/product/app/${app_folder}" \
        "${SYSTEM_MOUNT_POINT}/product/priv-app/${app_folder}"; do

        if [ -d "$app_path" ]; then
            echo "Removing "$app_path"..."
            sudo rm -rf "$app_path"
            if [ $? -ne 0 ]; then
                echo "Warning: Failed to remove "$app_path"."
            else
                echo "Removed "$app_path"."
                UNWANTED_APP_COUNT=$((UNWANTED_APP_COUNT + 1))
                FOUND_APP=true
            fi
            # Once found and (attempted to be) removed, no need to check other paths for this app
            break
        fi
    done
    if ! $FOUND_APP; then
        echo "App folder "$app_folder" not found in common locations. Skipping."
    fi
done

if [ $UNWANTED_APP_COUNT -eq 0 ]; then
    echo "No unwanted apps were removed."
else
    echo "Total "$UNWANTED_APP_COUNT" unwanted apps removed."
fi
echo ""

# --- Step: Patch services.jar for Play Integrity ---
log_step 15 "Patching services.jar for Play Integrity" # Renamed from 16

SERVICES_JAR_PATH="${SYSTEM_MOUNT_POINT}/system_ext/framework/services.jar"
SERVICES_SMALI_DIR="services_decompiled"

if [ -f "$SERVICES_JAR_PATH" ]; then
  echo "Decompiling services.jar..."
  sudo apktool d -f -r "$SERVICES_JAR_PATH" -o "$SERVICES_SMALI_DIR"
  if [ $? -ne 0 ]; then echo "Error: Failed to decompile services.jar. Exiting."; exit 1; fi
  echo "services.jar decompiled to "$SERVICES_SMALI_DIR"/."

  # --- Apply patches for services.jar ---
  echo "Applying patches to services.jar smali..."
  # Path to the specific smali file
  SMALI_FILE="${SERVICES_SMALI_DIR}/smali_classes2/com/android/server/am/ActivityManagerService.smali"
  if [ -f "$SMALI_FILE" ]; then
    # Patch 1: Bypass isBuildConsistent check (for Play Integrity)
    sudo sed -i '/invoke-static {}, Landroid\/os\/Build;->isBuildConsistent()Z/{ n; s/    move-result v1/    move-result v1\n\n    const\/4 v1, 0x1\n/ }' "$SMALI_FILE"
    # Patch 2: Adjust if-nez and :cond labels (example based on common pattern)
    sudo sed -i 's/if-nez v1, :cond_42/if-nez v1, :cond_43/g' "$SMALI_FILE"
    sudo sed -i 's/:cond_42/:cond_43/g' "$SMALI_FILE"
    sudo sed -i 's/\(:try_end_43\)\n    .catchall {:try_start_29 .. :try_end_43} :catchall_26/\:try_end_44\n    .catchall {:try_start_29 .. :try_end_44} :catchall_26/g' "$SMALI_FILE"
    sudo sed -i 's/:goto_47/:goto_48/g' "$SMALI_FILE"
    sudo sed -i 's/\(:try_start_47\)\n    monitor-exit v0\n:try_end_48/\:try_start_48\n    monitor-exit v0\n:try_end_49/g' "$SMALI_FILE"
    echo "Patches applied to "$SMALI_FILE"."
  else
    echo "Warning: Smali file "$SMALI_FILE" not found. Skipping services.jar patching."
  fi

  echo "Rebuilding services.jar..."
  sudo apktool b "$SERVICES_SMALI_DIR" -o "$SERVICES_JAR_PATH"
  if [ $? -ne 0 ]; then echo "Error: Failed to rebuild services.jar. Exiting."; exit 1; fi
  echo "services.jar rebuilt."
  sudo rm -rf "$SERVICES_SMALI_DIR"
else
  echo "Warning: services.jar not found at "$SERVICES_JAR_PATH". Skipping services.jar patching."
fi
echo ""

# --- Step: Patch OPSystemUI.apk for G2 Features ---
log_step 16 "Patching OPSystemUI.apk for G2 Features" # Renamed from 17

OPSYSTEMUI_APK_PATH="${SYSTEM_MOUNT_POINT}/system_ext/priv-app/SystemUI/SystemUI.apk"
OPSYSTEMUI_SMALI_DIR="OPSystemUI_decompiled"
OP_VOLUME_DIALOG_IMPL_FILE="${OPSYSTEMUI_SMALI_DIR}/smali_classes2/com/oneplus/volume/OpVolumeDialogImpl.smali"
DOZE_SENSORS_PICKUP_CHECK_FILE="${OPSYSTEMUI_SMALI_DIR}/smali_classes2/com/android/systemui/doze/DozeSensors.smali"
DOZE_MACHINE_STATE_FILE="${OPSYSTEMUI_SMALI_DIR}/smali_classes2/com/android/systemui/doze/DozeMachine$State.smali"

if [ -f "$OPSYSTEMUI_APK_PATH" ]; then
  echo "Decompiling OPSystemUI.apk..."
  sudo apktool d -f -r "$OPSYSTEMUI_APK_PATH" -o "$OPSYSTEMUI_SMALI_DIR"
  if [ $? -ne 0 ]; then echo "Error: Failed to decompile OPSystemUI.apk. Exiting."; exit 1; fi
  echo "OPSystemUI.apk decompiled to "$OPSYSTEMUI_SMALI_DIR"/."

  # --- Apply smali patches for OPSystemUI.apk ---
  echo "Applying smali patches to OPSystemUI.apk..."

  # Patch OpVolumeDialogImpl for volume panel toggle
  if [ -f "$OP_VOLUME_DIALOG_IMPL_FILE" ]; then
    sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_VOLUME_DIALOG_IMPL_FILE"
    sudo sed -i 's/const\/16 v4, 0x13/const\/16 v4, 0x15/g' "$OP_VOLUME_DIALOG_IMPL_FILE"
    echo "Patched "$OP_VOLUME_DIALOG_IMPL_FILE"."
  else
    echo "Warning: "$OP_VOLUME_DIALOG_IMPL_FILE" not found. Skipping OpVolumeDialogImpl patch."
  fi

  # Patch DozeSensors for pickup check (Always On Display related)
  if [ -f "$DOZE_SENSORS_PICKUP_CHECK_FILE" ]; then
    sudo sed -i 's/0x1fa2652/0x1fa265c/g' "$DOZE_SENSORS_PICKUP_CHECK_FILE"
    echo "Patched "$DOZE_SENSORS_PICKUP_CHECK_FILE"."
  else
    echo "Warning: "$DOZE_SENSORS_PICKUP_CHECK_FILE" not found. Skipping DozeSensors patch."
  fi
  
  # Patch DozeMachine$State for screen state (Always On Display related)
  if [ -f "$DOZE_MACHINE_STATE_FILE" ]; then
    sudo sed -i '/.method screenState/{n;s/    const\/4 v1, 0x3/    const\/4 v1, 0x2/}' "$DOZE_MACHINE_STATE_FILE"
    echo "Patched "$DOZE_MACHINE_STATE_FILE"."
  else
    echo "Warning: "$DOZE_MACHINE_STATE_FILE" not found. Skipping DozeMachine$State patch."
  fi

  # --- Copy pre-compiled G2 smali files for SystemUI ---
  echo "Copying G2 feature files for SystemUI..."
  if [ -d "$MY_G2_FOR_SYSTEMUI_DIR" ]; then
    # Ensure target directory exists for OpCustomizeSettingsG2.smali
    sudo mkdir -p "${OPSYSTEMUI_SMALI_DIR}/smali_classes2/com/oneplus/android/settings/better/display"
    # Copy OpCustomizeSettingsG2.smali
    if [ -f "${MY_G2_FOR_SYSTEMUI_DIR}/OpCustomizeSettingsG2.smali" ]; then
      sudo cp "${MY_G2_FOR_SYSTEMUI_DIR}/OpCustomizeSettingsG2.smali" "${OPSYSTEMUI_SMALI_DIR}/smali_classes2/com/oneplus/android/settings/better/display/"
      echo "Copied OpCustomizeSettingsG2.smali to SystemUI."
    else
      echo "Warning: OpCustomizeSettingsG2.smali not found in "$MY_G2_FOR_SYSTEMUI_DIR". Skipping."
    fi
    # Copy plugin_files (if any)
    if [ -d "${MY_G2_FOR_SYSTEMUI_DIR}/plugin_files" ]; then
      sudo cp -a "${MY_G2_FOR_SYSTEMUI_DIR}/plugin_files/." "${OPSYSTEMUI_SMALI_DIR}/"
      echo "Copied plugin_files to SystemUI."
    else
      echo "Warning: plugin_files directory not found in "$MY_G2_FOR_SYSTEMUI_DIR". Skipping."
    fi
  else
    echo "Warning: "$MY_G2_FOR_SYSTEMUI_DIR" not found. Skipping G2 feature file copying for SystemUI."
  fi

  echo "Rebuilding OPSystemUI.apk..."
  sudo apktool b "$OPSYSTEMUI_SMALI_DIR" -o "$OPSYSTEMUI_APK_PATH"
  if [ $? -ne 0 ]; then echo "Error: Failed to rebuild OPSystemUI.apk. Exiting."; exit 1; fi
  echo "OPSystemUI.apk rebuilt."
  sudo rm -rf "$OPSYSTEMUI_SMALI_DIR"
else
  echo "Warning: OPSystemUI.apk not found at "$OPSYSTEMUI_APK_PATH". Skipping OPSystemUI.apk patching."
fi
echo ""

# --- Step: Patch Settings.apk for G2 Features ---
log_step 17 "Patching Settings.apk for G2 Features" # Renamed from 18

SETTINGS_APK_PATH="${SYSTEM_MOUNT_POINT}/system/priv-app/Settings/Settings.apk"
SETTINGS_SMALI_DIR="Settings_decompiled"
OP_UTILS_FILE="${SETTINGS_SMALI_DIR}/smali_classes2/com/oneplus/utils/OpUtils.smali"

if [ -f "$SETTINGS_APK_PATH" ]; then
  echo "Decompiling Settings.apk..."
  sudo apktool d -f -r "$SETTINGS_APK_PATH" -o "$SETTINGS_SMALI_DIR"
  if [ $? -ne 0 ]; then echo "Error: Failed to decompile Settings.apk. Exiting."; exit 1; fi
  echo "Settings.apk decompiled to "$SETTINGS_SMALI_DIR"/."

  # --- Apply smali patches for Settings.apk ---
  echo "Applying smali patches to Settings.apk..."

  # Patch OpUtils for custom fingerprint
  if [ -f "$OP_UTILS_FILE" ]; then
    sudo sed -i '/.method.*OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT/,/.end method/{ /    const\/4 v0, 0x0/{ s/    const\/4 v0, 0x0/    const\/4 v0, 0x1/ } }' "$OP_UTILS_FILE"
    echo "Patched "$OP_UTILS_FILE"."
  else
    echo "Warning: "$OP_UTILS_FILE" not found. Skipping OpUtils patch."
  fi

  # --- Copy pre-compiled G2 smali files for Settings ---
  echo "Copying G2 feature files for Settings..."
  if [ -d "$MY_G2_FOR_SETTINGS_DIR" ]; then
    # Ensure target directory exists for OpCustomizeSettingsG2.smali
    sudo mkdir -p "${SETTINGS_SMALI_DIR}/smali_classes2/com/oneplus/android/settings/better/display"
    # Copy OpCustomizeSettingsG2.smali
    if [ -f "${MY_G2_FOR_SETTINGS_DIR}/OpCustomizeSettingsG2.smali" ]; then
      sudo cp "${MY_G2_FOR_SETTINGS_DIR}/OpCustomizeSettingsG2.smali" "${SETTINGS_SMALI_DIR}/smali_classes2/com/oneplus/android/settings/better/display/"
      echo "Copied OpCustomizeSettingsG2.smali to Settings."
    else
      echo "Warning: OpCustomizeSettingsG2.smali not found in "$MY_G2_FOR_SETTINGS_DIR". Skipping."
    fi
  else
    echo "Warning: "$MY_G2_FOR_SETTINGS_DIR" not found. Skipping G2 feature file copying for Settings."
  fi

  echo "Rebuilding Settings.apk..."
  sudo apktool b "$SETTINGS_SMALI_DIR" -o "$SETTINGS_APK_PATH"
  if [ $? -ne 0 ]; then echo "Error: Failed to rebuild Settings.apk. Exiting."; exit 1; fi
  echo "Settings.apk rebuilt."
  sudo rm -rf "$SETTINGS_SMALI_DIR"
else
  echo "Warning: Settings.apk not found at "$SETTINGS_APK_PATH". Skipping Settings.apk patching."
fi
echo ""

# --- Step: Handle OnePlus Wallpaper Resources ---
log_step 18 "Handling OnePlus Wallpaper Resources" # Renamed from 15

OPWALLPAPER_RESOURCES_APK_PATH="${SYSTEM_MOUNT_POINT}/product/overlay/OPWallpaperResources.apk"

if [ -f "$OPWALLPAPER_RESOURCES_APK_PATH" ]; then
  if [ -d "$FOR_OPWALLPAPER_RESOURCES_DIR" ]; then
    echo "Copying contents from "$FOR_OPWALLPAPER_RESOURCES_DIR" to "$OPWALLPAPER_RESOURCES_APK_PATH"."
    # Replace the existing APK directly
    sudo cp -f "$FOR_OPWALLPAPER_RESOURCES_DIR/OPWallpaperResources.apk" "$OPWALLPAPER_RESOURCES_APK_PATH"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to copy OPWallpaperResources.apk."
      exit 1
    fi
    echo "OPWallpaperResources.apk replaced successfully."
  else
    echo "Warning: "$FOR_OPWALLPAPER_RESOURCES_DIR" not found. Skipping OPWallpaperResources handling."
  fi
else
  echo "Warning: OPWallpaperResources.apk not found at "$OPWALLPAPER_RESOURCES_APK_PATH". Skipping OPWallpaperResources handling."
fi
echo ""

# --- Step: Remove Unwanted Libraries ---
log_step 19 "Removing Unwanted Libraries" # Renamed from 8

UNWANTED_LIBS_COUNT=0
UNWANTED_LIBS=(
    "libhotword_arm64.so"
    "libhotword_jni_arm64.so"
    "libhotword_xgoogle_arm64.so"
    "libhotword_xgoogle_jni_arm64.so"
    "libmarmota.so"
    "libopus.so"
    "libpffft.so"
    "libvcdecoder.so"
    "libvpx.so"
)

for lib_name in "${UNWANTED_LIBS[@]}"; do
    FOUND_LIB=false
    # Search in common lib locations within the mounted system
    for lib_path in \
        "${SYSTEM_MOUNT_POINT}/system/lib/${lib_name}" \
        "${SYSTEM_MOUNT_POINT}/system/lib64/${lib_name}" \
        "${SYSTEM_MOUNT_POINT}/system_ext/lib/${lib_name}" \
        "${SYSTEM_MOUNT_POINT}/system_ext/lib64/${lib_name}" \
        "${SYSTEM_MOUNT_POINT}/product/lib/${lib_name}" \
        "${SYSTEM_MOUNT_POINT}/product/lib64/${lib_name}"; do

        if [ -f "$lib_path" ]; then
            echo "Removing "$lib_path"..."
            sudo rm -f "$lib_path"
            if [ $? -ne 0 ]; then
                echo "Warning: Failed to remove "$lib_path"."
            else
                echo "Removed "$lib_path"."
                UNWANTED_LIBS_COUNT=$((UNWANTED_LIBS_COUNT + 1))
                FOUND_LIB=true
            fi
            # Once found and (attempted to be) removed, no need to check other paths for this lib
            break
        fi
    done
    if ! $FOUND_LIB; then
        echo "Library "$lib_name" not found in common locations. Skipping."
    fi
done

if [ $UNWANTED_LIBS_COUNT -eq 0 ]; then
    echo "No unwanted libraries were removed."
else
    echo "Total "$UNWANTED_LIBS_COUNT" unwanted libraries removed."
fi
echo ""

# --- Step: Overwrite build.prop properties ---
log_step 20 "Overwriting build.prop properties" # Renamed from 9
BUILD_PROP_PATH="${SYSTEM_MOUNT_POINT}/system/build.prop"

if [ -f "$BUILD_PROP_PATH" ]; then
  echo "Modifying build.prop..."
  # Add or overwrite properties
  sudo sed -i '/^ro.build.tags=/c\ro.build.tags=release-keys' "$BUILD_PROP_PATH"
  sudo sed -i '/^ro.build.type=/c\ro.build.type=user' "$BUILD_PROP_PATH"
  sudo sed -i '/^ro.boot.flash.locked=/c\ro.boot.flash.locked=1' "$BUILD_PROP_PATH"
  sudo sed -i '/^ro.boot.verifiedbootstate=/c\ro.boot.verifiedbootstate=green' "$BUILD_PROP_PATH"
  sudo sed -i '/^ro.boot.vbmeta.device_state=/c\ro.boot.vbmeta.device_state=locked' "$BUILD_PROP_PATH"
  sudo sed -i '/^ro.build.fingerprint=/d' "$BUILD_PROP_PATH" # Delete existing fingerprint
  # Add a generic fingerprint. You may want to replace this with a real one for better compatibility.
  echo "ro.build.fingerprint=google/raven/raven:13/TQ1A.230105.002/9290072_B2.0_M001:user/release-keys" | sudo tee -a "$BUILD_PROP_PATH" > /dev/null
  echo "build.prop modified."
else
  echo "Warning: build.prop not found at "$BUILD_PROP_PATH". Skipping build.prop modifications."
fi
echo ""

# --- Step: Clean up unused files/directories from initial system mount ---
log_step 21 "Cleaning up unused system files/directories" # Renamed from 19

# Remove dm-verity and forceencrypt scripts
echo "Removing dm-verity and forceencrypt scripts..."
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/bin/install-recovery.sh"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/install-recovery.sh"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/bin/dmveritygen"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/fstab.qcom" # This might be risky, use with caution

# Remove some firmware update related directories/files
echo "Removing firmware update related files..."
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/firmware"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/vendor/firmware" # Be careful with this, can break hardware
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/fs_config_dirs"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/fs_config_files"
sudo rm -rf "${SYSTEM_MOUNT_POINT}/system/etc/preloaded-classes" # This can also be risky, may affect boot time

echo "Unused system files/directories cleaned."
echo ""

# --- Step: Copy init.rc and other init files ---
log_step 22 "Copying init.rc and other init files" # Renamed from 20

INIT_RC_PATH="${SYSTEM_MOUNT_POINT}/system/etc/init/hw/init.rc"
if [ -d "$MY_INIT_FILES_DIR" ]; then
    echo "Copying init files from "$MY_INIT_FILES_DIR"..."
    # Ensure target directory exists for init.rc
    sudo mkdir -p "${SYSTEM_MOUNT_POINT}/system/etc/init/hw"
    # Copy init.rc (replace if exists)
    if [ -f "${MY_INIT_FILES_DIR}/init.rc" ]; then
      sudo cp -f "${MY_INIT_FILES_DIR}/init.rc" "$INIT_RC_PATH"
      echo "Copied init.rc."
    else
      echo "Warning: init.rc not found in "$MY_INIT_FILES_DIR". Skipping."
    fi

    # Copy any other init.*.rc files from my_init_files
    for init_file in "${MY_INIT_FILES_DIR}"/init.*.rc; do
      if [ -f "$init_file" ]; then
        sudo cp -f "$init_file" "${SYSTEM_MOUNT_POINT}/system/etc/init/"
        echo "Copied "$(basename "$init_file")"."
      fi
    done
else
    echo "Warning: "$MY_INIT_FILES_DIR" not found. Skipping init file copying."
fi
echo ""

# --- Step: Copy plugin files (if applicable) ---
log_step 23 "Copying plugin files" # Renamed from 21

if [ -d "$PLUGIN_FILES_DIR" ]; then
    echo "Copying plugin files from "$PLUGIN_FILES_DIR" to system root (read-write mount)..."
    # Copy contents of PLUGIN_FILES_DIR into the root of the mounted system
    sudo cp -a "${PLUGIN_FILES_DIR}/." "${SYSTEM_MOUNT_POINT}/"
    if [ $? -ne 0 ]; then
      echo "Error: Failed to copy plugin files."
      exit 1
    fi
    echo "Plugin files copied to "$SYSTEM_MOUNT_POINT"/."
else
    echo "Warning: "$PLUGIN_FILES_DIR" not found. Skipping plugin file copying."
fi
echo ""

# --- Step: Create symlinks in /system/reserve ---
log_step 24 "Creating symlinks in /system/reserve" # Renamed from 22

RESERVE_DIR="${SYSTEM_MOUNT_POINT}/system/reserve"
RESERVE_CUST_DIR="${SYSTEM_MOUNT_POINT}/cust" # This is the target for the symlinks
SYMLINK_TARGET_DIR="${SYSTEM_MOUNT_POINT}/system/reserve" # The location where symlinks will be created

sudo mkdir -p "$RESERVE_DIR"

if [ -d "$RESERVE_CUST_DIR" ]; then
  echo "Creating symlinks for directories in "$RESERVE_CUST_DIR"..."
  for dir in "$RESERVE_CUST_DIR"/*; do
    if [ -d "$dir" ]; then
      dirname=$(basename "$dir")
      SYMLINK_PATH="${SYMLINK_TARGET_DIR}/${dirname}"
      if [ -L "$SYMLINK_PATH" ]; then
        echo "Symlink for "$dirname" already exists. Skipping."
      elif [ -e "$SYMLINK_PATH" ]; then
        echo "Warning: A file/directory named "$dirname" already exists at "$SYMLINK_TARGET_DIR". Cannot create symlink. Skipping."
      else
        # Create a relative symlink.
        # "../../cust/$dirname" correctly points from system_mount_point/system/reserve to system_mount_point/cust/$dirname
        sudo ln -s "../../cust/$dirname" "$SYMLINK_TARGET_DIR/$dirname"
        if [ $? -ne 0 ]; then
          echo "Warning: Failed to create symlink for "$dirname"."
        else
          echo "Created symlink for "$dirname"."
        fi
      fi
    fi
  done
else
  echo "Warning: "$RESERVE_CUST_DIR" not found. Skipping symlink creation."
fi
echo ""

# --- Step: Finalize and Unmount System Image ---
log_step 25 "Finalizing and Unmounting System Image" # Renamed from 23

echo "Syncing changes to "$SYSTEM_MOUNT_POINT"..."
sudo sync
echo "Unmounting "$SYSTEM_MOUNT_POINT"..."
unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"
echo "System image unmounted."
echo ""

# --- Step: Convert system.img to sparse image and generate payload ---
log_step 26 "Converting system.img to sparse image and generating payload" # Renamed from 24

echo "Converting system.img to sparse image..."
img2simg "firmware_images/system.img" "firmware_images/system_sparse.img"
if [ $? -ne 0 ]; then echo "Error: Failed to convert system.img to sparse image."; exit 1; fi
echo "system.img converted to system_sparse.img."

# Use simg2img on the original system_ext.img to make it a standard sparse image
if [ -f "$SYSTEM_EXT_IMG_PATH" ]; then
  echo "Converting original system_ext.img to sparse image (if not already sparse)..."
  simg2img "$SYSTEM_EXT_IMG_PATH" "firmware_images/system_ext_sparse.img"
  if [ $? -ne 0 ]; then echo "Error: Failed to convert system_ext.img to sparse image."; fi
  SYSTEM_EXT_IMG_PATH="firmware_images/system_ext_sparse.img" # Update path to sparse version
  echo "system_ext.img converted to system_ext_sparse.img."
fi

# Use simg2img on the original product.img to make it a standard sparse image
if [ -f "$PRODUCT_IMG_PATH" ]; then
  echo "Converting original product.img to sparse image (if not already sparse)..."
  simg2img "$PRODUCT_IMG_PATH" "firmware_images/product_sparse.img"
  if [ $? -ne 0 ]; then echo "Error: Failed to convert product.img to sparse image."; fi
  PRODUCT_IMG_PATH="firmware_images/product_sparse.img" # Update path to sparse version
  echo "product.img converted to product_sparse.img."
fi

# Generate transfer list and patch for system_sparse.img
echo "Generating transfer list and patch for system_sparse.img..."
# This assumes you have the 'img2sdat_tools' directory containing 'img2sdat.py' and 'gen_patch.py'
if [ -d "img2sdat_tools" ]; then
    python3 img2sdat_tools/img2sdat.py "firmware_images/system_sparse.img" -o "test" -v 4
    if [ $? -ne 0 ]; then echo "Error: Failed to generate system transfer list/dat."; exit 1; fi
    
    # Generate system.patch.dat (empty if no changes, or real patch if system_new.img was truly new)
    # This might require comparing original system_sparse.img with the new one.
    # For simplicity, we assume img2sdat.py handles creating a new.dat.br and transfer.list
    # The user might manually create system.patch.dat if they want to apply diffs.
    # We will proceed assuming system.new.dat.br and system.transfer.list are created.
    echo "Generated system.new.dat.br and system.transfer.list."
else
    echo "Error: img2sdat_tools directory not found. Cannot generate system.new.dat.br/transfer.list. Exiting."
    exit 1
fi
echo ""

# --- Step: Combine into a flashable ZIP ---
log_step 27 "Combining into a flashable ZIP" # Renamed from 25

ROM_FILENAME="Flashable_ROM_$(date +%Y%m%d%H%M%S).zip"
ROM_ZIP_PATH="${ROM_ROOT}/${ROM_FILENAME}"

echo "Creating flashable ROM zip: "$ROM_ZIP_PATH"..."

# Ensure the 'test' directory and 'firmware_images/reserve.img' exist
if [ ! -d "test" ] || [ ! -f "test/system.new.dat.br" ] || [ ! -f "test/system.transfer.list" ]; then
    echo "Error: Required 'test' directory contents (system.new.dat.br, system.transfer.list) are missing."
    exit 1
fi

RESERVE_IMG_PATH="firmware_images/reserve.img"
# For now, create a dummy reserve.img if it doesn't exist to allow zipping to proceed.
# In a real scenario, this would be generated or sourced properly.
if [ ! -f "$RESERVE_IMG_PATH" ]; then
    echo "Warning: reserve.img not found. Creating a dummy empty one for zip creation."
    touch "$RESERVE_IMG_PATH" # Create an empty file
fi

# Zip everything. Make sure the 'firmware_images' contains the new reserve.img
# and 'test' contains system.new.dat.br, system.patch.dat, system.transfer.list
zip -r "$ROM_ZIP_PATH" test/system.new.dat.br test/system.patch.dat test/system.transfer.list "$RESERVE_IMG_PATH"
if [ $? -ne 0 ]; then echo "Zipping failed."; exit 1; fi

echo "ROM_ZIP_PATH="$ROM_ZIP_PATH"" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo "ROM_FILENAME="$ROM_FILENAME"" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo ""$ROM_ZIP_PATH" created."
echo ""

# --- Step: Prepare Release Tag Name (for manual trigger) ---
log_step 28 "Preparing Release Tag Name" # Renamed from 19
ROM_BASE_NAME=$(basename "${ROM_FILENAME}" .zip)
RELEASE_TAG="release-${ROM_BASE_NAME}-$(date +%Y%m%d%H%M%S)-${GITHUB_RUN_NUMBER}"
echo "Generated tag for manual release: "$RELEASE_TAG"..."
echo "release_tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT" # For GitHub Actions to pick up
echo "RELEASE_TAG=$RELEASE_TAG" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo ""

# --- Final Cleanup ---
log_step 29 "Final Cleanup" # Renamed from 20
echo "Cleaning up workspace..."
# Adjusted cleanup to match new flow and remove new temp dirs
sudo rm -rf firmware_images/original_system_mount_point firmware_images/original_system_ext_mount_point firmware_images/original_product_mount_point system_new_final_mount_point system_mount_point services_decompiled OPSystemUI_decompiled Settings_decompiled img2sdat_tools *.dat *.br "$NEW_RESERVE_IMG_PATH" firmware_images/*.img payload_dumper "$FIRMWARE_FILENAME" firmware_extracted output "$ROM_FILENAME"

echo "Workspace cleaned up."
echo "Script finished."
