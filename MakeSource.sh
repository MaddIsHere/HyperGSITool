#!/bin/bash

INPUT_DIR=$1
ROM_TYPE=$2
BASE_DIR="Temp/system"
product="$BASE_DIR/product"

# Older version of debloat list
#list_system_apps() {
#    echo "Installed apps: "
#    echo ""
#
#    for parent in "$BASE_DIR/system/app" "$BASE_DIR/system/priv-app" "$BASE_DIR/product/#app" "$BASE_DIR/product/priv-app"; do
#        if [ -d "$parent" ]; then
#            category=$(basename "$(dirname "$parent")")/$(basename "$parent")
#            echo "$category:"
#            find "$parent" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
#                echo "   - $(basename "$dir")"
#           done
#           echo ""
#        fi
#    done
#}

list_system_apps() {
    echo ""
    echo "Finding apks.."
    echo ""

    find "$BASE_DIR/system" "$BASE_DIR/product" -type f -name "*.apk" 2>/dev/null |
        while read -r apk; do
            dir=$(dirname "$apk")
            echo "$dir"
        done | sort -u | while read -r unique_dir; do
            rel_path="${unique_dir#$BASE_DIR/}"
            echo " - $rel_path"
        done

    echo ""
    echo "Found: $(find "$BASE_DIR/system" "$BASE_DIR/product" -type f -name "*.apk" | xargs -n1 dirname | sort -u | wc -l)"
}


usage() {
  echo "Usage: $0 [base_directory] HyperOS"
  echo ""
  echo "Parameters:"
  echo "  base_directory  - Path to the base ROM directory"
  echo "  HyperOS - needed, always add when using this command"
  echo ""
  echo "Example:"
  echo "  sudo bash $0 system HyperOS"
  echo ""
  echo "Please check github or HowToUse.txt to see building instructions(IMPORTANT)"
}

supported_roms() {
    declare -a versions=(14 15)
    for version in "${versions[@]}"; do
        rom_dir="ROMsPatches/$version"
        if [ -d "$rom_dir" ]; then
            names=$(find "$rom_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
            filtered=$(echo "$names" | grep -vxF -f <(printf '%s\n' "${versions[@]}"))
            if [ -n "$filtered" ]; then
                echo "Android $version:"
                echo "$filtered" | sed 's|^|  - |' | tr '\n' '\n'
                echo ""
            fi
        fi
    done
}

if [ -z "$2" ]; then
  usage
  supported_roms
  exit 0
fi

if [ ! -d "$INPUT_DIR" ]; then
  echo "Error: Directory $INPUT_DIR does not exist"
  exit 1
fi

rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
echo "Copying to temp directory"
cp -r "$INPUT_DIR/." "$BASE_DIR/"

SDK_VERSION=$(grep -m1 "ro.build.version.sdk" "$BASE_DIR/system/build.prop" | cut -d '=' -f2 | tr -dc '0-9')

if [ -z "$SDK_VERSION" ] || ! [[ "$SDK_VERSION" =~ ^[0-9]+$ ]]; then
  echo "Error: Unable to read SDK version from '$BASE_DIR/system/build.prop'."
  exit 1
fi

case "$SDK_VERSION" in
  34)
    android_version="14"
    ;;
  35)
    android_version="15"
    ;;
  *)
    echo "Error: Unsupported SDK version $SDK_VERSION"
    exit 1
    ;;
esac

echo "Android Version: $android_version (SDK $SDK_VERSION)"

if [ ! -d "Patches/$android_version" ]; then
  echo "Error: Android version $android_version unsupported"
  exit 1
fi

if [ ! -d "ROMsPatches/$android_version/$ROM_TYPE" ]; then
  echo "Error: ROM $ROM_TYPE for Android $android_version unsupported"
  supported_roms
  exit 1
fi

echo "Patching started..."
Patches/$android_version/make.sh "$BASE_DIR"
Patches/common/make.sh "$BASE_DIR"
ROMsPatches/$android_version/$ROM_TYPE/make.sh "$BASE_DIR"
tar -xf "Patches/apex/$android_version.tar.xz" -C "$BASE_DIR/system/apex"

if [ -n "$(ls -A "$BASE_DIR/vendor" 2>/dev/null)" ]; then
  Tools/vendoroverlay/addvo.sh "$BASE_DIR"
  rm -rf "$BASE_DIR/vendor/"*
fi

echo ""
read -r -p "Debloat apps? (Y/n): " debloat_choice
debloat_choice=${debloat_choice:-Y}

if [[ "$debloat_choice" =~ ^[Yy]$ ]]; then
    list_system_apps
    echo "Enter folders name to remove, then press Enter: "
    read -e -a bloat_targets

    for folder in "${bloat_targets[@]}"; do
        target_paths=(
            "$BASE_DIR/product/app/$folder"
            "$BASE_DIR/product/priv-app/$folder"
            "$BASE_DIR/system/app/$folder"
            "$BASE_DIR/system/priv-app/$folder"
        )

        deleted=false
        for path in "${target_paths[@]}"; do
            if [[ -d "$path" ]]; then
                rm -rf "$path"
                echo "Removed $path"
                deleted=true
            fi
        done

        if ! $deleted; then
            echo "Could not find: $folder in known paths"
        fi
    done
else
    echo "Skipping.."
fi

echo ""
read -r -p "Do you want to preload any apks? (Y/n): " preload_choice
preload_choice=${preload_choice:-Y}

if [[ "$preload_choice" =~ ^[Yy]$ ]]; then
	echo ""
    echo "Add your apks path here(add a space in between to install multiple):"
    read -e -a apk_paths
	
	for apk in "${apk_paths[@]}"; do
        if [[ ! -f "$apk" ]]; then
            echo "Path doesn't exists: $apk"
            echo "Example path: /home/user/Downloads/somethingidk.apk"
            continue
        fi

        apk_name=$(basename "$apk" .apk)
        apk_type_dir="$product/app/$apk_name"

        echo "Place '$apk_name' in app or priv-app? (a/p): "
        read -r app_type
        if [[ "$app_type" =~ ^[pP]$ ]]; then
            apk_type_dir="$product/priv-app/$apk_name"
        else
        	apk_type_dir="$product/app/$apk_name"
        fi

        mkdir -p "$apk_type_dir"
        cp "$apk" "$apk_type_dir/$apk_name.apk"
        echo "Placed $apk_name.apk in $apk_type_dir"
    done
    else
    echo "Skipping.."
fi
current_date=$(date +"%Y-%m-%d")

echo "Creating $ROM_TYPE-$android_version-$current_date.img"
rm -rf "Output"
mkdir -p "Output"
Tools/mkimage/mkimage.sh "$BASE_DIR" "Output/$ROM_TYPE-$android_version-$current_date.img"

echo ""
read -r -p "Convert to .dat.br? (Y/n): " compress_choice
compress_choice=${compress_choice:-Y}

if [[ "$compress_choice" =~ ^[Yy]$ ]]; then
    echo "Converting to .dat.br"

    OUTPUT_IMG="Output/$ROM_TYPE-$android_version-$current_date.img"
    IMG_TYPE=$(file "$OUTPUT_IMG")

    RAW_IMG="Output/system.raw.img"
    MOUNT_DIR="Output/mounted"
    TEMP_DIR="Output/temp_system"
    DAT_DIR="Output/datted"

    mkdir -p "$MOUNT_DIR" "$TEMP_DIR" "$DAT_DIR"

    if echo "$IMG_TYPE" | grep -q "sparse"; then
        echo "Converting to raw.."
        simg2img "$OUTPUT_IMG" "$RAW_IMG"
    else
        echo "Raw img detected.."
        cp "$OUTPUT_IMG" "$RAW_IMG"
    fi

    sudo mount -o loop "$RAW_IMG" "$MOUNT_DIR"
    sudo cp -a "$MOUNT_DIR"/. "$TEMP_DIR/"
    echo "Copying to Temp.."
    sudo umount "$MOUNT_DIR"

    SIZE=$(du -sb "$TEMP_DIR" | cut -f1)
    PADDED_SIZE=$((SIZE + 52428800))  # thanks microsoft copilot for this padding sizre th9igny
    RAW_OUTPUT_IMG="$DAT_DIR/system.img"

    dd if=/dev/zero of="$RAW_OUTPUT_IMG" bs=1 count=0 seek="$PADDED_SIZE"
    mkfs.ext4 -F -L system "$RAW_OUTPUT_IMG"

    sudo mount -o loop "$RAW_OUTPUT_IMG" "$MOUNT_DIR"
    sudo cp -a "$TEMP_DIR"/. "$MOUNT_DIR/"
    sudo umount "$MOUNT_DIR"

    img2simg "$RAW_OUTPUT_IMG" "$DAT_DIR/system.new.dat"
    echo "Converting to .new.dat using img2simg.."

    brotli -f "$DAT_DIR/system.new.dat" -o "$DAT_DIR/system.new.dat.br"
    echo "Converting to .net.dat.br using brotli.."

    echo -e "1\n0\n0\n0\n0" > "$DAT_DIR/system.transfer.list"
    touch "$DAT_DIR/system.patch.dat"
    echo "Creating dummy patch.dat file.."

    rm -rf "$TEMP_DIR" "$RAW_IMG" "$RAW_OUTPUT_IMG"
    echo "Cleaning up.."

    echo ""
    echo "Converted to $DAT_DIR:"
    echo "   - system.new.dat.br"
    echo "   - system.transfer.list"
    echo "   - system.patch.dat"
else
    echo "MakeSource done!"
fi

