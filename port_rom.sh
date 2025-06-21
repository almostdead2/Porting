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
echo "Downloading firmware from: "$FIRMWARE_URL""
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

  echo "Running payload_dumper.py from "$PAYLOAD_DUMPER_DIR/payload_dumper.py..."
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
  if [ $? -ne 0 ]; then echo "Apktool framework installation failed! Check framework-res.apk path and file integrity."; exit 1; fi
  echo "Apktool framework installed successfully."
else
  echo "Error: framework-res.apk not found at "$FRAMEWORK_APK". Cannot install framework. Ensure your ROM files are correctly extracted."
  exit 1
fi
echo ""

# --- Step: Delete unwanted apps ---
log_step 13 "Deleting unwanted apps" # Renumbered from 12

if [[ ${#UNWANTED_APPS[@]} -eq 0 ]]; then
    echo "No apps specified in UNWANTED_APPS list. Skipping app removal."
else
    echo "Starting removal of unwanted applications..."

    APP_BASE_PATHS=(
        "${SYSTEM_MOUNT_POINT}/system/app"
        "${SYSTEM_MOUNT_POINT}/system/priv-app"
        "${SYSTEM_MOUNT_POINT}/product/app"
        "${SYSTEM_MOUNT_POINT}/product/priv-app"
        "${SYSTEM_MOUNT_POINT}/system_ext/app"
        "${SYSTEM_MOUNT_POINT}/system_ext/priv-app"
        "${SYSTEM_MOUNT_POINT}/vendor/app" # Keeping as common location
        "${SYSTEM_MOUNT_POINT}/vendor/priv-app" # Keeping as common location
        "${SYSTEM_MOUNT_POINT}/odm/app" # Keeping as common location
        "${SYSTEM_MOUNT_POINT}/odm/priv-app" # Keeping as common location
        "${SYSTEM_MOUNT_POINT}/system/reserve" # Added as requested by user
    )

    APPS_REMOVED=0
    for app_name in "${UNWANTED_APPS[@]}"; do
        FOUND_AND_REMOVED=false
        echo "  - Looking for app: "$app_name""
        for base_path in "${APP_BASE_PATHS[@]}"; do
            APP_PATH="${base_path}/${app_name}"
            if [ -d "$APP_PATH" ]; then
                echo "    -> Found at "$APP_PATH". Deleting..."
                sudo rm -rf "$APP_PATH"
                if [ $? -eq 0 ]; then
                    echo "    -> Successfully removed "$app_name"."
                    FOUND_AND_REMOVED=true
                    APPS_REMOVED=$((APPS_REMOVED + 1))
                else
                    echo "    -> Failed to remove "$app_name" from "$base_path"."
                fi
                # We assume an app folder name is unique, so once found and removed, move to next app
                break
            fi
        done
        if [ "$FOUND_REMOVED" = false ]; then
            echo "    -> Warning: App folder '"$app_name"' not found in any standard app location."
        fi
    done

    if [ "$APPS_REMOVED" -eq 0 ]; then
        echo "No unwanted apps were found or removed based on the defined list."
    else
        echo "Total "$APPS_REMOVED" unwanted app(s) removed."
    fi
fi
echo "Unwanted apps removal complete."
echo ""

# Fix permissions for build.prop (applied within mounted system.img)
echo "Fixing permissions for build.prop within mounted system.img..."
sudo chmod -R a+rwX "${SYSTEM_MOUNT_POINT}/system"
echo "Permissions set."

# Modify build.prop (within mounted system.img)
log_step 12.1 "Modifying build.prop within mounted system.img" # Renamed from 7.1
ODT_BUILD_PROP="${SYSTEM_MOUNT_POINT}/odm/etc/buildinfo/build.prop"
OPPRODUCT_BUILD_PROP="${SYSTEM_MOUNT_POINT}/opproduct/build.prop"
SYSTEM_BUILD_PROP="${SYSTEM_MOUNT_POINT}/system/build.prop"
SOURCE_BUILD_PROP=""

if [ -f "$ODT_BUILD_PROP" ]; then
  SOURCE_BUILD_PROP="$ODT_BUILD_PROP"
  echo "Found source build.prop at "$ODT_BUILD_PROP". Using it for modification."
elif [ -f "$OPPRODUCT_BUILD_PROP" ]; then
  SOURCE_BUILD_PROP="$OPPRODUCT_BUILD_PROP"
  echo "Warning: "$ODT_BUILD_PROP" not found. Using "$OPPRODUCT_BUILD_PROP" as source build.prop instead."
else
  echo "Warning: Neither "$ODT_BUILD_PROP" nor "$OPPRODUCT_BUILD_PROP" found. Skipping source build.prop modification."
fi

if [ ! -f "$SYSTEM_BUILD_PROP" ]; then
  echo "Error: "$SYSTEM_BUILD_PROP" not found. Cannot modify build.prop."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV" # Clean up before exiting
  exit 1
fi

if [ -n "$SOURCE_BUILD_PROP" ]; then
  echo "Extracting lines from "$SOURCE_BUILD_PROP"..."
  awk '/# autogenerated by oem_log_prop.sh/{flag=1} flag' "$SOURCE_BUILD_PROP" > tmp_lines.txt

  if [ ! -s tmp_lines.txt ]; then
    echo "Warning: No lines found to copy from "$SOURCE_BUILD_PROP" starting from '# autogenerated by oem_log_prop.sh'. Skipping build.prop append."
    rm -f tmp_lines.txt
  else
    echo "Appending lines to "$SYSTEM_BUILD_PROP"..."
    awk '/# end build properties/ && !x {print; system("cat tmp_lines.txt"); x=1; next} 1' "$SYSTEM_BUILD_PROP" > tmp_build.prop && sudo mv tmp_build.prop "$SYSTEM_BUILD_PROP"
    rm -f tmp_lines.txt
  fi
fi

echo "Adding 'ro.boot.cust=6' and a blank line to "$SYSTEM_BUILD_PROP"..."
PROPERTY_LINE="ro.boot.cust=6" 
BLANK_LINE="" 

echo "$PROPERTY_LINE" | sudo tee -a "$SYSTEM_BUILD_PROP" > /dev/null
echo "$BLANK_LINE" | sudo tee -a "$SYSTEM_BUILD_PROP" > /dev/null

echo "ro.boot.cust=6 and blank line successfully added."
echo "Verifying last 3 lines of "$SYSTEM_BUILD_PROP" to confirm format:"
sudo tail -n 3 "$SYSTEM_BUILD_PROP"

echo "build.prop modification complete."

# Create empty keylayout files (within mounted system.img)
log_step 12.2 "Creating empty keylayout files within mounted system.img" # Renamed from 7.2
KEYLAYOUT_DIR="${SYSTEM_MOUNT_POINT}/system/usr/keylayout"
sudo mkdir -p "$KEYLAYOUT_DIR"

echo "Creating empty uinput-fpc.kl and uinput-goodix.kl..."
sudo touch "$KEYLAYOUT_DIR/uinput-fpc.kl"
sudo touch "$KEYLAYOUT_DIR/uinput-goodix.kl"
echo "Keylayout files created."

# Replace init Binary (from repo) (within mounted system.img)
log_step 12.3 "Replacing init Binary within mounted system.img" # Renamed from 7.3
SOURCE_INIT_PATH="${MY_INIT_FILES_DIR}/init"
INIT_TARGET_PATH="${SYSTEM_MOUNT_POINT}/system/bin/init"

if [ ! -f "$SOURCE_INIT_PATH" ]; then
  echo "Warning: Custom init binary not found at "$SOURCE_INIT_PATH"."
  echo "Skipping init replacement. If you intended to replace init, please place your 'init' file in the 'my_init_files' directory in your repository root."
else
  echo "Custom init binary found at "$SOURCE_INIT_PATH"."
  if [ -f "$INIT_TARGET_PATH" ]; then
    echo "Deleting old init: "$INIT_TARGET_PATH""
    sudo rm "$INIT_TARGET_PATH"
  else
    echo "Old init not found at "$INIT_TARGET_PATH", will place new one."
  fi
  echo "Copying new init from "$SOURCE_INIT_PATH" to "$INIT_TARGET_PATH" and setting permissions."
  sudo cp "$SOURCE_INIT_PATH" "$INIT_TARGET_PATH"
  sudo chown 1000:1000 "$INIT_TARGET_PATH"
  sudo chmod 0755 "$INIT_TARGET_PATH"
  echo "Init binary replaced and permissions set."
fi

# Patch services.jar (Smali Modification) (within mounted system.img)
log_step 12.4 "Patching services.jar (Smali Modification) within mounted system.img" # Renamed from 7.4
SERVICES_JAR_PATH="${SYSTEM_MOUNT_POINT}/system/framework/services.jar"
SMALI_DIR="${ROM_ROOT}/services_decompiled" # Decompile to a temporary folder in ROM_ROOT

if [ ! -f "$SERVICES_JAR_PATH" ]; then
  echo "Error: services.jar not found at "$SERVICES_JAR_PATH"."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV" # Clean up before exiting
  exit 1
fi

echo "Decompiling services.jar..."
sudo apktool d -f -r "$SERVICES_JAR_PATH" -o "$SMALI_DIR"
if [ $? -ne 0 ]; then echo "Apktool decompilation failed."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi

SMALI_FILE="$SMALI_DIR/smali_classes2/com/android/server/wm/ActivityTaskManagerService\$LocalService.smali"
if [ ! -f "$SMALI_FILE" ]; then
  echo "Error: Smali file not found at "$SMALI_FILE". Decompilation might have failed or path is incorrect."
  unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"
  exit 1
fi

echo "Applying smali modifications to "$SMALI_FILE"..."
sudo sed -i '/invoke-static {}, Landroid\/os\/Build;->isBuildConsistent()Z/{ n; s/    move-result v1/    move-result v1\n\n    const\/4 v1, 0x1\n/ }' "$SMALI_FILE"
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

sudo sed -i 's/\(:try_start_47\)\n    monitor-exit v0\n:try_end_48/\:try_start_48\n    monitor-exit v0\n:try_end_49/g' "$SMALI_FILE"
if [ $? -ne 0 ]; then echo "Sixth sed replacement (try_start/end_4x) failed."; exit 1; fi
echo "Sixth modification (:try_start/end_4x) applied."

echo "Recompiling services.jar..."
sudo apktool b "$SMALI_DIR" -o "$SERVICES_JAR_PATH"
if [ $? -ne 0 ]; then echo "Apktool recompilation failed."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi
echo "services.jar recompiled successfully."
sudo rm -rf "$SMALI_DIR"
echo ""

# Replace OPWallpaperResources.apk (now in system_ext part of the merged system.img)
log_step 12.5 "Replacing OPWallpaperResources.apk in merged image" # Adjusted from 8
TARGET_APK_DIR="${SYSTEM_MOUNT_POINT}/system_ext/app/OPWallpaperResources"
TARGET_APK_PATH="$TARGET_APK_DIR/OPWallpaperResources.apk"
SOURCE_APK_PATH="${FOR_OPWALLPAPER_RESOURCES_DIR}/OPWallpaperResources.apk"

if [ ! -f "$SOURCE_APK_PATH" ]; then
  echo "Warning: "$SOURCE_APK_PATH" not found. Skipping OPWallpaperResources.apk replacement."
else
  echo "Replacing "$TARGET_APK_PATH"..."
  sudo rm -rf "$TARGET_APK_DIR" # Remove the entire directory to ensure clean replacement
  sudo mkdir -p "$TARGET_APK_DIR"
  sudo cp "$SOURCE_APK_PATH" "$TARGET_APK_PATH"
  echo "OPWallpaperResources.apk replaced."
fi
echo ""

# Modify OPSystemUI.apk (Smali Modification) (within mounted system.img)
log_step 12.6 "Modifying OPSystemUI.apk in merged image" # Renamed from 9
SYSTEMUI_APK_PATH="${SYSTEM_MOUNT_POINT}/system_ext/priv-app/OPSystemUI/OPSystemUI.apk"
SYSTEMUI_SMALI_DIR="${ROM_ROOT}/OPSystemUI_decompiled"

if [ ! -f "$SYSTEMUI_APK_PATH" ]; then
  echo "Error: OPSystemUI.apk not found at "$SYSTEMUI_APK_PATH"."
  echo "Skipping OPSystemUI.apk modification."
else
  echo "Decompiling OPSystemUI.apk..."
  sudo apktool d -f -r "$SYSTEMUI_APK_PATH" -o "$SYSTEMUI_SMALI_DIR"
  if [ $? -ne 0 ]; then echo "Apktool decompilation failed for OPSystemUI.apk."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi

  OP_VOLUME_DIALOG_IMPL_FILE="$SYSTEMUI_SMALI_DIR/smali_classes3/com/android/systemui/volume/OPVolumeDialogImpl.smali"
  DOZE_SENSORS_PICKUP_CHECK_FILE="$SYSTEMUI_SMALI_DIR/smali_classes2/com/android/systemui/doze/DozeSensors$PickupCheck.smali"
  DOZE_MACHINE_STATE_FILE="$SYSTEMUI_SMALI_DIR/smali_classes2/com/android/systemui/doze/DozeMachine$State.smali"

  echo "Applying smali modifications to OPSystemUI.apk..."

  if [ -f "$OP_VOLUME_DIALOG_IMPL_FILE" ]; then
    echo "Patching OPVolumeDialogImpl.smali..."
    sudo sed -i '/:cond_11/{n;s/    const\/4 p0, 0x0/    const\/4 p0, 0x1/}' "$OP_VOLUME_DIALOG_IMPL_FILE"
    sudo sed -i 's/const\/16 v4, 0x13/const\/16 v4, 0x15/g' "$OP_VOLUME_DIALOG_IMPL_FILE"
    echo "OPVolumeDialogImpl.smali patched."
  else
    echo "Warning: OPVolumeDialogImpl.smali not found. Skipping patch."
  fi

  if [ -f "$DOZE_SENSORS_PICKUP_CHECK_FILE" ]; then
    echo "Patching DozeSensors\$PickupCheck.smali..."
    sudo sed -i 's/0x1fa2652/0x1fa265c/g' "$DOZE_SENSORS_PICKUP_CHECK_FILE"
    echo "DozeSensors\$PickupCheck.smali patched."
  else
    echo "Warning: DozeSensors\$PickupCheck.smali not found. Skipping patch."
  fi

  if [ -f "$DOZE_MACHINE_STATE_FILE" ]; then
    echo "Patching DozeMachine\$State.smali..."
    sudo sed -i '/.method screenState/{n;s/    const\/4 v1, 0x3/    const\/4 v1, 0x2/}' "$DOZE_MACHINE_STATE_FILE"
    echo "DozeMachine\$State.smali patched."
  else
    echo "Warning: DozeMachine\$State.smali not found. Skipping patch."
  fi

  # Replace OpCustomizeSettingsG2.smali directly (file placement)
  OP_CUSTOMIZE_SETTINGS_G2_FILE_SRC="${MY_G2_FOR_SYSTEMUI_DIR}/OpCustomizeSettingsG2.smali"
  OP_CUSTOMIZE_SETTINGS_G2_FILE_DEST="$SYSTEMUI_SMALI_DIR/smali_classes3/com/oneplus/systemui/utils/OpCustomizeSettingsG2.smali"
  if [ -f "$OP_CUSTOMIZE_SETTINGS_G2_FILE_SRC" ]; then
    echo "Replacing OpCustomizeSettingsG2.smali..."
    sudo rm -f "$OP_CUSTOMIZE_SETTINGS_G2_FILE_DEST" # Remove old file if exists
    sudo cp "$OP_CUSTOMIZE_SETTINGS_G2_FILE_SRC" "$OP_CUSTOMIZE_SETTINGS_G2_FILE_DEST"
    echo "OpCustomizeSettingsG2.smali replaced."
  else
    echo "Warning: Custom OpCustomizeSettingsG2.smali not found at "$OP_CUSTOMIZE_SETTINGS_G2_FILE_SRC". Skipping direct replacement."
  fi

  # Copy plugin files (file placement)
  echo "Copying plugin files to OPSystemUI_decompiled/assets/plugins..."
  sudo rm -rf "$SYSTEMUI_SMALI_DIR/assets/plugins" # Remove existing plugins to avoid conflicts
  sudo mkdir -p "$SYSTEMUI_SMALI_DIR/assets"
  sudo cp -r "${PLUGIN_FILES_DIR}/." "$SYSTEMUI_SMALI_DIR/assets/plugins"
  if [ $? -ne 0 ]; then echo "Error: Failed to copy plugin files."; exit 1; fi
  echo "Plugin files copied."

  echo "Recompiling OPSystemUI.apk..."
  sudo apktool b "$SYSTEMUI_SMALI_DIR" -o "$SYSTEMUI_APK_PATH"
  if [ $? -ne 0 ]; then echo "Apktool recompilation failed for OPSystemUI.apk."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi
  echo "OPSystemUI.apk recompiled successfully."
  sudo rm -rf "$SYSTEMUI_SMALI_DIR"
fi
echo ""

# Modify Settings.apk (Smali Modification) (within mounted system.img)
log_step 12.7 "Modifying Settings.apk in merged image" # Renamed from 10
SETTINGS_APK_PATH="${SYSTEM_MOUNT_POINT}/system/priv-app/Settings/Settings.apk"
SETTINGS_SMALI_DIR="${ROM_ROOT}/Settings_decompiled"

if [ ! -f "$SETTINGS_APK_PATH" ]; then
  echo "Error: Settings.apk not found at "$SETTINGS_APK_PATH"."
  echo "Skipping Settings.apk modification."
else
  echo "Decompiling Settings.apk..."
  sudo apktool d -f -r "$SETTINGS_APK_PATH" -o "$SETTINGS_SMALI_DIR"
  if [ $? -ne 0 ]; then echo "Apktool decompilation failed for Settings.apk."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi

  OP_UTILS_FILE="$SETTINGS_SMALI_DIR/smali_classes2/com/oneplus/settings/utils/OPUtils.smali"

  echo "Applying smali modifications to Settings.apk..."

  if [ -f "$OP_UTILS_FILE" ]; then
    echo "Patching OPUtils.smali for fingerprint support..."
    sudo sed -i '/.method.*OP_FEATURE_SUPPORT_CUSTOM_FINGERPRINT/,/.end method/{
      /    const\/4 v0, 0x0/{
        s/    const\/4 v0, 0x0/    const\/4 v0, 0x1/
      }
    }' "$OP_UTILS_FILE"
    if [ $? -ne 0 ]; then echo "Sed patch failed for OPUtils.smali. Ensure the smali pattern exists."; exit 1; fi
    echo "OPUtils.smali patched."
  else
    echo "Warning: OPUtils.smali not found. Skipping patch."
  fi

  # Replace OpCustomizeSettingsG2.smali directly (file placement)
  OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_SRC="${MY_G2_FOR_SETTINGS_DIR}/OpCustomizeSettingsG2.smali"
  OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_DEST="$SETTINGS_SMALI_DIR/smali_classes2/com/oneplus/settings/utils/OpCustomizeSettingsG2.smali"

  if [ -f "$OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_SRC" ]; then
    echo "Replacing OpCustomizeSettingsG2.smali in Settings app..."
    sudo rm -f "$OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_DEST" # Remove old file if exists
    sudo cp "$OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_SRC" "$OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_DEST"
    echo "OpCustomizeSettingsG2.smali replaced in Settings app."
  else
    echo "Warning: Custom OpCustomizeSettingsG2.smali for Settings not found at "$OP_CUSTOMIZE_SETTINGS_G2_SETTINGS_FILE_SRC". Skipping direct replacement."
  fi

  echo "Recompiling Settings.apk..."
  sudo apktool b "$SETTINGS_SMALI_DIR" -o "$SETTINGS_APK_PATH"
  if [ $? -ne 0 ]; then echo "Apktool recompilation failed for Settings.apk."; unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"; exit 1; fi
  echo "Settings.apk recompiled successfully."
  sudo rm -rf "$SETTINGS_SMALI_DIR"
fi
echo ""

# Create symlinks in system/reserve from cust (within mounted system.img)
log_step 14 "Preparing Reserve Partition and Creating Image" # Renamed from 15

RESERVE_DIR_PATH="${SYSTEM_MOUNT_POINT}/system/reserve"
CUST_MOUNTPOINT_DIR="${SYSTEM_MOUNT_POINT}/cust"
SYMLINK_TARGET_DIR="${RESERVE_DIR_PATH}" # Symlinks will be created directly in system/reserve

echo "Creating "$RESERVE_DIR_PATH" if it doesn't exist..."
sudo mkdir -p "$RESERVE_DIR_PATH"

if [ ! -d "$CUST_MOUNTPOINT_DIR" ]; then
    echo "Warning: "$CUST_MOUNTPOINT_DIR" does not exist. Skipping symlink creation from cust/."
else
    echo "Creating symlinks for apps in "$CUST_MOUNTPOINT_DIR" to "$RESERVE_DIR_PATH"..."
    for item in $(sudo ls -A "$CUST_MOUNTPOINT_DIR"); do
        # Check if it's a directory (an app or priv-app folder)
        if [ -d "$CUST_MOUNTPOINT_DIR/$item" ]; then
            dirname=$(basename "$item")
            # Create a relative symlink from system/reserve to cust/
            sudo ln -s "../../cust/$dirname" "$SYMLINK_TARGET_DIR/$dirname"
            if [ $? -eq 0 ]; then
                echo "  -> Created symlink for "$dirname": "../../cust/$dirname" -> "$SYMLINK_TARGET_DIR/$dirname""
            else
                echo "  -> Failed to create symlink for "$dirname"."
            fi
        fi
    done
    echo "Symlink creation complete."
fi

# Prepare for Image Creation
NEW_RESERVE_IMG_NAME="reserve.img"
echo "Creating empty reserve.img (200MB) for new reserve content..."
dd if=/dev/zero of="$NEW_RESERVE_IMG_NAME" bs=1M count=200
if [ $? -ne 0 ]; then echo "Error: Failed to create empty file for reserve.img."; exit 1; fi

sudo mkfs.ext4 -L reserve "$NEW_RESERVE_IMG_NAME"
if [ $? -ne 0 ]; then echo "Error: Failed to format "$NEW_RESERVE_IMG_NAME" as ext4."; exit 1; fi

NEW_RESERVE_MOUNT_POINT="new_reserve_mount_point"
NEW_RESERVE_LOOP_DEV=$(mount_image "$NEW_RESERVE_IMG_NAME" "$NEW_RESERVE_MOUNT_POINT" "") # "" for read-write
if [ $? -ne 0 ]; then echo "Failed to mount "$NEW_RESERVE_IMG_NAME". Exiting."; exit 1; fi

echo "Copying contents from "$RESERVE_DIR_PATH" to "$NEW_RESERVE_MOUNT_POINT"..."
sudo cp -a "$RESERVE_DIR_PATH/." "$NEW_RESERVE_MOUNT_POINT/"
if [ $? -ne 0 ]; then echo "Error: Failed to copy contents to "$NEW_RESERVE_IMG_NAME"."; exit 1; fi
echo "Contents copied to "$NEW_RESERVE_IMG_NAME"."

unmount_image "$NEW_RESERVE_MOUNT_POINT" "$NEW_RESERVE_LOOP_DEV"
echo ""$NEW_RESERVE_IMG_NAME" unmounted."

RESERVE_IMG_PATH="firmware_images/$NEW_RESERVE_IMG_NAME"
sudo mv "$NEW_RESERVE_IMG_NAME" "$RESERVE_IMG_PATH"
echo "reserve.img created at "$RESERVE_IMG_PATH""
echo ""


# --- Unmount the final system.img after all modifications are done ---
log_step 15 "Syncing and Unmounting the modified system.img" # Renamed from 16
unmount_image "$SYSTEM_MOUNT_POINT" "$SYSTEM_LOOP_DEV"
echo "Modified system.img unmounted."
echo ""

# --- Step: Convert system.img to system.new.dat.br and system.transfer.list ---
log_step 16 "Converting system.img to sparse image and creating brotli files" # Renamed from 17
TARGET_SYSTEM_IMG_PATH="firmware_images/system.img"
OUTPUT_DIR="test" # All img2sdat output will go here
mkdir -p "$OUTPUT_DIR"

echo "Using img2sdat.py from vm03/img2sdat.git to convert "$TARGET_SYSTEM_IMG_PATH"..."
IMG2SDAT_DIR="img2sdat_tools"
git clone https://github.com/vm03/img2sdat.git "$IMG2SDAT_DIR"
if [ ! -d "$IMG2SDAT_DIR" ]; then
  echo "Error: Failed to clone vm03/img2sdat repository."
  exit 1
fi

if [ -f "$IMG2SDAT_DIR/requirements.txt" ]; then
  echo "Installing img2sdat requirements from "$IMG2SDAT_DIR"/requirements.txt..."
  python3 -m pip install -r "$IMG2SDAT_DIR/requirements.txt"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to install img2sdat requirements."
    rm -rf "$IMG2SDAT_DIR"
    exit 1
  fi
else
  echo "Warning: No requirements.txt found in "$IMG2SDAT_DIR". Skipping pip install for this repo."
fi

# Determine payload_input.bin (the system image to convert)
# It should be the system.img that was just unmounted and is ready
PAYLOAD_INPUT_BIN="$TARGET_SYSTEM_IMG_PATH"

python3 "$IMG2SDAT_DIR/img2sdat.py" "$PAYLOAD_INPUT_BIN" -o "$OUTPUT_DIR" -c # -c for brotli compression
if [ $? -ne 0 ]; then echo "img2sdat.py failed."; exit 1; fi

echo "Conversion complete. Output files are in "$OUTPUT_DIR"/."
rm -rf "$IMG2SDAT_DIR" # Clean up the img2sdat tools
echo ""

# --- Step: Prepare Final ROM Zip ---
log_step 17 "Preparing Final ROM Zip" # Renamed from 18

ROM_FILENAME="OnePlus_ROM_Port_$(date +%Y%m%d_%H%M%S).zip"
ROM_ZIP_PATH="${ROM_ROOT}/${ROM_FILENAME}"

echo "Creating final ROM zip: "$ROM_ZIP_PATH"..."

# Navigate to the directory where all components are
cd "$ROM_ROOT"

# Adjusting to use a single zip command based on the structure of the repo
# Assuming the 'firmware_images' contains the new reserve.img
# and 'test' contains system.new.dat.br, system.patch.dat, system.transfer.list
zip -r "$ROM_ZIP_PATH" test/system.new.dat.br test/system.patch.dat test/system.transfer.list "$RESERVE_IMG_PATH"
if [ $? -ne 0 ]; then echo "Zipping failed."; exit 1; fi

echo "ROM_ZIP_PATH="$ROM_ZIP_PATH"" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo "ROM_FILENAME="$ROM_FILENAME"" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo ""$ROM_ZIP_PATH" created."
echo ""

# --- Step: Prepare Release Tag Name (for manual trigger) ---
log_step 18 "Preparing Release Tag Name" # Renamed from 19
ROM_BASE_NAME=$(basename "${ROM_FILENAME}" .zip)
RELEASE_TAG="release-${ROM_BASE_NAME}-$(date +%Y%m%d%H%M%S)-${GITHUB_RUN_NUMBER}"
echo "Generated tag for manual release: "$RELEASE_TAG"..."
echo "release_tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT" # For GitHub Actions to pick up
echo "RELEASE_TAG=$RELEASE_TAG" >> "$GITHUB_ENV" # For GitHub Actions to pick up
echo ""

# --- Final Cleanup ---
log_step 19 "Final Cleanup" # Renamed from 20
echo "Cleaning up workspace..."
# Adjusted cleanup to match new flow and remove new temp dirs
sudo rm -rf firmware_images/original_system_mount_point firmware_images/original_system_ext_mount_point firmware_images/original_product_mount_point system_new_final_mount_point system_mount_point services_decompiled OPSystemUI_decompiled Settings_decompiled img2sdat_tools *.dat *.br "$NEW_RESERVE_IMG_NAME"
echo "Workspace cleaned up."
