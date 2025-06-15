#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# FIRMWARE_URL is now expected to be passed as an environment variable from the .yml workflow.
# For local testing, you can uncomment and set it here, but it will be overridden by GitHub Actions.
# FIRMWARE_URL="YOUR_ONEPLUS_FIRMWARE_DOWNLOAD_URL_HERE_FOR_LOCAL_TESTING_ONLY"

FIRMWARE_DIR="firmware"
MOUNT_DIR="mount_points"
OUTPUT_DIR="output"
PAYLOAD_BIN="payload.bin"
SYSTEM_IMG="system.img"
SYSTEM_EXT_IMG="system_ext.img"
PRODUCT_IMG="product.img"
ODM_IMG="odm.img"
OPPRODUCT_IMG="opproduct.img" # This might not always exist

SYSTEM_NEW_IMG="system_new.img"
SYSTEM_NEW_IMG_SIZE="3221225472" # 3GB in bytes, often needs adjustment based on actual firmware size

# Path to your local OPWallpaperResources.apk, relative to where the script is executed.
# This assumes 'for_OPWallpaperResources' is a directory at the same level as this script.
LOCAL_OPWALLPAPER_APK_SOURCE="for_OPWallpaperResources/OPWallpaperResources.apk"

# Path to the payload_dumper script after cloning the repo.
# Assumes the 'payload_dumper' repository is cloned into a directory named 'payload_dumper'
PAYLOAD_DUMPER_SCRIPT="payload_dumper/payload_dumper.py"


UNWANTED_APPS=(
    "OnePlusCamera" "Drive" "Duo" "Gmail2" "Maps" "Music2" "Photos" "GooglePay"
    "GoogleTTS" "Videos" "YouTube" "HotwordEnrollmentOKGoogleWCD9340"
    "HotwordEnrollmentXGoogleWCD9340" "Velvet" "By_3rd_PlayAutoInstallConfigOverSeas"
    "OPBackup" "OPForum"
)

# --- Functions ---

log_step() {
    echo ""
    echo "==================================================================="
    echo "STEP $1: $2"
    echo "==================================================================="
    echo ""
}

cleanup_mounts() {
    echo "Cleaning up any remaining mounts..."
    # Using 'grep -q' to check if mounted before attempting to unmount
    sudo umount "${MOUNT_DIR}/system_new" 2>/dev/null || true
    sudo umount "${MOUNT_DIR}/system" 2>/dev/null || true
    sudo umount "${MOUNT_DIR}/system_ext" 2>/dev/null || true
    sudo umount "${MOUNT_DIR}/product" 2>/dev/null || true
    sudo umount "${MOUNT_DIR}/odm" 2>/dev/null || true # For optional odm.img
    sudo umount "${MOUNT_DIR}/opproduct" 2>/dev/null || true # For optional opproduct.img
}

# Ensure mount points are clean on script exit (even if errors occur)
trap cleanup_mounts EXIT

# --- Main Script ---

# Check if FIRMWARE_URL is provided (it should come from the .yml workflow input)
if [ -z "$FIRMWARE_URL" ]; then
    echo "Error: FIRMWARE_URL environment variable is not set. Please provide it via the workflow_dispatch input."
    exit 1
fi

# Create necessary directories
mkdir -p "$FIRMWARE_DIR" "$MOUNT_DIR" "$OUTPUT_DIR"

# 1. Download OnePlus Firmware
log_step "1" "Downloading OnePlus Firmware"
FIRMWARE_ZIP=$(basename "$FIRMWARE_URL")
if [[ ! -f "${FIRMWARE_DIR}/${FIRMWARE_ZIP}" ]]; then
    echo "Attempting to download firmware from: $FIRMWARE_URL"
    wget --show-progress -P "$FIRMWARE_DIR" "$FIRMWARE_URL"
else
    echo "Firmware already exists: ${FIRMWARE_DIR}/${FIRMWARE_ZIP}. Skipping download."
fi
FIRMWARE_ZIP_PATH="${FIRMWARE_DIR}/${FIRMWARE_ZIP}"
if [[ ! -f "$FIRMWARE_ZIP_PATH" ]]; then
    echo "Error: Firmware download failed or file not found at $FIRMWARE_ZIP_PATH."
    exit 1
fi

# 2. Extract that Downloaded Zip
log_step "2" "Extracting Downloaded Zip"
echo "Extracting $FIRMWARE_ZIP_PATH to $FIRMWARE_DIR"
unzip -o "$FIRMWARE_ZIP_PATH" -d "$FIRMWARE_DIR"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to extract firmware zip."
    exit 1
fi

# 3. Take payload.bin
log_step "3" "Locating payload.bin"
if [[ ! -f "${FIRMWARE_DIR}/${PAYLOAD_BIN}" ]]; then
    echo "Error: payload.bin not found in ${FIRMWARE_DIR} after extraction."
    exit 1
fi
echo "Found ${FIRMWARE_DIR}/${PAYLOAD_BIN}"

# 4. Extract payload.bin
log_step "4" "Extracting payload.bin using payload_dumper" # Updated log message
echo "Extracting $FIRMWARE_DIR/$PAYLOAD_BIN to $OUTPUT_DIR"
# Ensure payload_dumper script exists
if [[ ! -f "$PAYLOAD_DUMPER_SCRIPT" ]]; then
    echo "Error: payload_dumper.py script not found at '$PAYLOAD_DUMPER_SCRIPT'. Make sure the repository is cloned correctly."
    exit 1
fi

# Execute payload_dumper.py directly
python3 "$PAYLOAD_DUMPER_SCRIPT" "$FIRMWARE_DIR/$PAYLOAD_BIN" --output "$OUTPUT_DIR"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to extract payload.bin using payload_dumper. Make sure Python dependencies are met."
    exit 1
fi

# 5. Keep only these system.img, system_ext.img, product.img odm.img opproduct.img(if this found) and delete rest .img
log_step "5" "Filtering image files and deleting others"
ALL_EXTRACTED_IMGS=$(find "$OUTPUT_DIR" -maxdepth 1 -name "*.img")
REQUIRED_IMGS=("$SYSTEM_IMG" "$SYSTEM_EXT_IMG" "$PRODUCT_IMG" "$ODM_IMG")
OPTIONAL_IMGS=("$OPPRODUCT_IMG") # Add opproduct.img to optional list

for img in $ALL_EXTRACTED_IMGS; do
    IMG_BASENAME=$(basename "$img")
    KEEP=false
    for required in "${REQUIRED_IMGS[@]}"; do
        if [[ "$IMG_BASENAME" == "$required" ]]; then
            KEEP=true
            break
        fi
    done
    if ! $KEEP; then
        for optional in "${OPTIONAL_IMGS[@]}"; do
            if [[ "$IMG_BASENAME" == "$optional" ]]; then
                KEEP=true
                break
            fi
        done
    fi

    if ! $KEEP; then
        echo "Deleting unwanted image: $img"
        rm "$img"
    else
        echo "Keeping image: $img"
    fi
done

# Check if required images exist
for img in "${REQUIRED_IMGS[@]}"; do
    if [[ ! -f "${OUTPUT_DIR}/${img}" ]]; then
        echo "Error: Required image ${img} not found after extraction/filtering."
        exit 1
    fi
done

# 6. Now delete that payload.bin and downloaded zip for save some space
log_step "6" "Deleting payload.bin and firmware zip"
rm -f "$FIRMWARE_DIR/$PAYLOAD_BIN"
rm -f "$FIRMWARE_ZIP_PATH"
echo "Deleted ${FIRMWARE_DIR}/${PAYLOAD_BIN} and ${FIRMWARE_ZIP_PATH}"

# Create mount points
mkdir -p "${MOUNT_DIR}/system" "${MOUNT_DIR}/system_ext" "${MOUNT_DIR}/product" "${MOUNT_DIR}/system_new"
mkdir -p "${MOUNT_DIR}/odm" "${MOUNT_DIR}/opproduct" # Ensure optional mount points exist

# 7. now mount system.img to system folder then delete unwanted apps then sync and then umount for now!
log_step "7" "Mounting system.img and deleting unwanted apps"
echo "Mounting ${OUTPUT_DIR}/${SYSTEM_IMG} to ${MOUNT_DIR}/system"
sudo mount -o loop "${OUTPUT_DIR}/${SYSTEM_IMG}" "${MOUNT_DIR}/system"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount system.img."; exit 1; fi

for app in "${UNWANTED_APPS[@]}"; do
    echo "Searching and deleting app '$app' in system partition..."
    find "${MOUNT_DIR}/system" -depth -type d \( -name "$app" -o -name "$app.apk" \) -exec sudo rm -rf {} + 2>/dev/null || true
done
sudo sync
sudo umount "${MOUNT_DIR}/system"
echo "Unmounted system.img"

# 8. now mount system_ext.img to system_ext folder then delete unwanted apps and then Replace OPWallpaperResources.apk (system_ext/app/OPWallpaperResources/OPWallpaperResources.apk) and take from my GitHub repo for_OPWallpaperResources/OPWallpaperResources.apk then sync and then umount for now!
log_step "8" "Mounting system_ext.img, deleting unwanted apps, and replacing OPWallpaperResources.apk"
echo "Mounting ${OUTPUT_DIR}/${SYSTEM_EXT_IMG} to ${MOUNT_DIR}/system_ext"
sudo mount -o loop "${OUTPUT_DIR}/${SYSTEM_EXT_IMG}" "${MOUNT_DIR}/system_ext"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount system_ext.img."; exit 1; fi

for app in "${UNWANTED_APPS[@]}"; do
    echo "Searching and deleting app '$app' in system_ext partition..."
    find "${MOUNT_DIR}/system_ext" -depth -type d \( -name "$app" -o -name "$app.apk" \) -exec sudo rm -rf {} + 2>/dev/null || true
done

OPWALLPAPER_DEST_PATH="${MOUNT_DIR}/system_ext/app/OPWallpaperResources/OPWallpaperResources.apk"

if [[ -f "$LOCAL_OPWALLPAPER_APK_SOURCE" ]]; then
    echo "Copying local OPWallpaperResources.apk from $LOCAL_OPWALLPAPER_APK_SOURCE to $OPWALLPAPER_DEST_PATH..."
    # Ensure destination directory exists before copying
    sudo mkdir -p "$(dirname "$OPWALLPAPER_DEST_PATH")"
    sudo cp "$LOCAL_OPWALLPAPER_APK_SOURCE" "$OPWALLPAPER_DEST_PATH"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to copy OPWallpaperResources.apk locally."
        exit 1
    else
        echo "Successfully copied OPWallpaperResources.apk."
    fi
else
    echo "Error: Local OPWallpaperResources.apk not found at '$LOCAL_OPWALLPAPER_APK_SOURCE'. Cannot replace."
    exit 1 # Exit if the source file is not found
fi

sudo sync
sudo umount "${MOUNT_DIR}/system_ext"
echo "Unmounted system_ext.img"

# 9. now mount product.img to product folder then delete unwanted apps then sync and then umount for now!
log_step "9" "Mounting product.img and deleting unwanted apps"
echo "Mounting ${OUTPUT_DIR}/${PRODUCT_IMG} to ${MOUNT_DIR}/product"
sudo mount -o loop "${OUTPUT_DIR}/${PRODUCT_IMG}" "${MOUNT_DIR}/product"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount product.img."; exit 1; fi

for app in "${UNWANTED_APPS[@]}"; do
    echo "Searching and deleting app '$app' in product partition..."
    find "${MOUNT_DIR}/product" -depth -type d \( -name "$app" -o -name "$app.apk" \) -exec sudo rm -rf {} + 2>/dev/null || true
done

sudo sync
sudo umount "${MOUNT_DIR}/product"
echo "Unmounted product.img"

# Optional: Mount and process odm.img if it exists
if [[ -f "${OUTPUT_DIR}/${ODM_IMG}" ]]; then
    log_step "9.1" "Mounting odm.img (if present) and deleting unwanted apps"
    echo "Mounting ${OUTPUT_DIR}/${ODM_IMG} to ${MOUNT_DIR}/odm"
    sudo mount -o loop "${OUTPUT_DIR}/${ODM_IMG}" "${MOUNT_DIR}/odm"
    if [[ $? -ne 0 ]]; then echo "Warning: Failed to mount odm.img. Continuing without processing."; else
        for app in "${UNWANTED_APPS[@]}"; do
            echo "Searching and deleting app '$app' in odm partition..."
            find "${MOUNT_DIR}/odm" -depth -type d \( -name "$app" -o -name "$app.apk" \) -exec sudo rm -rf {} + 2>/dev/null || true
        done
        sudo sync
        sudo umount "${MOUNT_DIR}/odm"
        echo "Unmounted odm.img"
    fi
fi

# Optional: Mount and process opproduct.img if it exists
if [[ -f "${OUTPUT_DIR}/${OPPRODUCT_IMG}" ]]; then
    log_step "9.2" "Mounting opproduct.img (if present) and copying contents to system_new.img" # This was opproduct.img, not opproeduct.img. Corrected the log step too
    echo "Mounting ${OUTPUT_DIR}/${OPPRODUCT_IMG} to ${MOUNT_DIR}/opproduct"
    sudo mount -o loop "${OUTPUT_DIR}/${OPPRODUCT_IMG}" "${MOUNT_DIR}/opproduct"
    if [[ $? -ne 0 ]]; then echo "Warning: Failed to mount opproduct.img. Continuing without processing."; else
        for app in "${UNWANTED_APPS[@]}"; do
            echo "Searching and deleting app '$app' in opproduct partition..."
            find "${MOUNT_DIR}/opproduct" -depth -type d \( -name "$app" -o -name "$app.apk" \) -exec sudo rm -rf {} + 2>/dev/null || true
        done
        sudo sync
        sudo umount "${MOUNT_DIR}/opproduct"
        echo "Unmounted opproduct.img"
    fi
fi

# 10. now make system_new.img (ext4 and size: 3221225472)
log_step "10" "Creating system_new.img"
echo "Creating empty ext4 image ${OUTPUT_DIR}/${SYSTEM_NEW_IMG} with size ${SYSTEM_NEW_IMG_SIZE} bytes."
sudo make_ext4fs -s -l "$SYSTEM_NEW_IMG_SIZE" "${OUTPUT_DIR}/${SYSTEM_NEW_IMG}"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create system_new.img. Make sure 'e2fsprogs' is installed."
    exit 1
fi

# 11. now mount system_new.img to system_new and also mount system.img to system folder then copy everything to system_new then sync and then just umount system.img only! (system_new.img still mounted)
log_step "11" "Mounting system_new.img and copying system.img contents"
echo "Mounting ${OUTPUT_DIR}/${SYSTEM_NEW_IMG} to ${MOUNT_DIR}/system_new"
sudo mount -o loop "${OUTPUT_DIR}/${SYSTEM_NEW_IMG}" "${MOUNT_DIR}/system_new"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount system_new.img."; exit 1; fi

echo "Mounting ${OUTPUT_DIR}/${SYSTEM_IMG} to ${MOUNT_DIR}/system for copy"
sudo mount -o loop "${OUTPUT_DIR}/${SYSTEM_IMG}" "${MOUNT_DIR}/system"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount system.img for copy."; exit 1; fi

echo "Copying contents from ${MOUNT_DIR}/system/ to ${MOUNT_DIR}/system_new/"
sudo rsync -a "${MOUNT_DIR}/system/" "${MOUNT_DIR}/system_new/"
sudo sync
sudo umount "${MOUNT_DIR}/system"
echo "Finished copying system.img contents. system.img unmounted."

# 12. now mount system_ext.img to system_ext folder then copy everything to system_new then sync and then just umount system_ext.img only! (system_new.img still mounted)
log_step "12" "Mounting system_ext.img and copying contents to system_new.img"
echo "Mounting ${OUTPUT_DIR}/${SYSTEM_EXT_IMG} to ${MOUNT_DIR}/system_ext"
sudo mount -o loop "${OUTPUT_DIR}/${SYSTEM_EXT_IMG}" "${MOUNT_DIR}/system_ext"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount system_ext.img."; exit 1; fi

echo "Copying contents from ${MOUNT_DIR}/system_ext/ to ${MOUNT_DIR}/system_new/"
sudo rsync -a "${MOUNT_DIR}/system_ext/" "${MOUNT_DIR}/system_new/"
sudo sync
sudo umount "${MOUNT_DIR}/system_ext"
echo "Finished copying system_ext.img contents. system_ext.img unmounted."

# 13. now mount product.img to product folder then copy everything to system_new then sync and then just umount product.img only! (system_new.img still mounted)
log_step "13" "Mounting product.img and copying contents to system_new.img"
echo "Mounting ${OUTPUT_DIR}/${PRODUCT_IMG} to ${MOUNT_DIR}/product"
sudo mount -o loop "${OUTPUT_DIR}/${PRODUCT_IMG}" "${MOUNT_DIR}/product"
if [[ $? -ne 0 ]]; then echo "Error: Failed to mount product.img."; exit 1; fi

echo "Copying contents from ${MOUNT_DIR}/product/ to ${MOUNT_DIR}/system_new/"
sudo rsync -a "${MOUNT_DIR}/product/" "${MOUNT_DIR}/system_new/"
sudo sync
sudo umount "${MOUNT_DIR}/product"
echo "Finished copying product.img contents. product.img unmounted."

# Optional: Copy odm.img if it exists
if [[ -f "${OUTPUT_DIR}/${ODM_IMG}" ]]; then
    log_step "13.1" "Mounting odm.img (if present) and copying contents to system_new.img"
    echo "Mounting ${OUTPUT_DIR}/${ODM_IMG} to ${MOUNT_DIR}/odm"
    sudo mount -o loop "${OUTPUT_DIR}/${ODM_IMG}" "${MOUNT_DIR}/odm"
    if [[ $? -ne 0 ]]; then echo "Warning: Failed to mount odm.img for copy. Skipping."; else
        echo "Copying contents from ${MOUNT_DIR}/odm/ to ${MOUNT_DIR}/system_new/"
        sudo rsync -a "${MOUNT_DIR}/odm/" "${MOUNT_DIR}/system_new/"
        sudo sync
        sudo umount "${MOUNT_DIR}/odm"
        echo "Finished copying odm.img contents. odm.img unmounted."
    fi
fi

# Optional: Copy opproduct.img if it exists
if [[ -f "${OUTPUT_DIR}/${OPPRODUCT_IMG}" ]]; then
    log_step "13.2" "Mounting opproduct.img (if present) and copying contents to system_new.img"
    echo "Mounting ${OUTPUT_DIR}/${OPPRODUCT_IMG} to ${MOUNT_DIR}/opproduct"
    sudo mount -o loop "${OUTPUT_DIR}/${OPPRODUCT_IMG}" "${MOUNT_DIR}/opproduct"
    if [[ $? -ne 0 ]]; then echo "Warning: Failed to mount opproduct.img. Continuing without processing."; else
        echo "Copying contents from ${MOUNT_DIR}/opproduct/ to ${MOUNT_DIR}/system_new/"
        sudo rsync -a "${MOUNT_DIR}/opproduct/" "${MOUNT_DIR}/system_new/"
        sudo sync
        sudo umount "${MOUNT_DIR}/opproduct"
        echo "Finished copying opproduct.img contents. opproduct.img unmounted."
    fi
fi

# 14. now sync and umount system_new.img
log_step "14" "Syncing and unmounting system_new.img"
sudo sync
sudo umount "${MOUNT_DIR}/system_new"
echo "Successfully unmounted system_new.img."

echo ""
echo "Script finished successfully! The modified system_new.img is located at ${OUTPUT_DIR}/${SYSTEM_NEW_IMG}"
