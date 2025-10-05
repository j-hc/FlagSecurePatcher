set -eu

LIBPATH="$MODPATH/util/lib/${ARCH}"
alias zip='LD_LIBRARY_PATH=$LIBPATH $MODPATH/util/bin/$ARCH/zip'
alias zipalign='LD_LIBRARY_PATH=$LIBPATH $MODPATH/util/bin/$ARCH/zipalign'
alias paccer='LD_LIBRARY_PATH=$LIBPATH $MODPATH/util/bin/$ARCH/paccer'
chmod -R 755 "$MODPATH/util/"
TMPPATH="$MODPATH/tmp"

BDATE_PROP=$(getprop ro.build.date.utc)

log() { ui_print "[+] $1"; }
loge() { ui_print "[-] $1"; }

main() {
    TARGET_JAR=$1
    TARGET_JAR_NAME=${TARGET_JAR##*/}
    TARGET_JAR_BASE=${TARGET_JAR_NAME%.*}
    if [ "${TARGET_JAR:0:8}" = "/system/" ]; then
        TARGET_JAR_PATH=${MODPATH}${TARGET_JAR%/*}
    else
        TARGET_JAR_PATH=${MODPATH}/system${TARGET_JAR%/*}
    fi
    mkdir "$TMPPATH"

    cp "$(magisk --path 2>/dev/null)/.magisk/mirror${TARGET_JAR}" "$TMPPATH" 2>/dev/null ||
        cp "/data/adb/modules/flagsecurepatcher/${TARGET_JAR_NAME}.bak.${BDATE_PROP}" "$TMPPATH/$TARGET_JAR_NAME" 2>/dev/null ||
        if [ ! -d "/data/adb/modules/flagsecurepatcher/system/" ]; then
            cp "$TARGET_JAR" "$TMPPATH" || abort "not found: '$TARGET_JAR'"
        else abort "Stock jar was not found. Uninstall the module, reboot and reflash."; fi
    cp "$TMPPATH/$TARGET_JAR_NAME" "$MODPATH/${TARGET_JAR_NAME}.bak.${BDATE_PROP}"

    log "Extracting $TARGET_JAR_BASE"
    mkdir "$TMPPATH/$TARGET_JAR_BASE"
    unzip -q "$TMPPATH/$TARGET_JAR_NAME" -d "$TMPPATH/$TARGET_JAR_BASE"
    [ -f "$TMPPATH/$TARGET_JAR_BASE/classes.dex" ] || abort "ROM is not supported"

    log "Patching"
    PATCHED_OK=0
    for DEX in "$TMPPATH/$TARGET_JAR_BASE"/classes*; do
        if ! OP=$(paccer "$DEX" "$DEX" "$TARGET_JAR_NAME" 2>&1); then
            loge "ERROR: paccer failed (${DEX##*/}):"
            abort "$OP"
        fi
        if [ "$OP" ]; then
            PATCHED_OK=1
            printf "%s\n" "$OP" | while read -r l; do
                log "Patched: $l"
            done
        fi
    done
    if [ $PATCHED_OK = 0 ]; then
        loge "No patch was found for $TARGET_JAR_BASE"
        rm -r "$TMPPATH"
        return 0
    fi

    if [ "$ARCH" = x64 ]; then INS_SET=x86_64; else INS_SET=$ARCH; fi
    mkdir -p "${TARGET_JAR_PATH}/oat/$INS_SET"

    log "Zipaligning"
    cd "$TMPPATH/$TARGET_JAR_BASE/"
    zip -q0r "$TMPPATH/$TARGET_JAR_BASE-patched.zip" .
    cd "$MODPATH"

    PATCHED_JAR=${TARGET_JAR_PATH}/${TARGET_JAR_NAME}
    if ! OP=$(zipalign -p -z 4 "$TMPPATH/$TARGET_JAR_BASE-patched.zip" "$PATCHED_JAR" 2>&1); then
        abort "ERROR: zipalign failed '$OP'"
    fi
    set_perm "$PATCHED_JAR" 0 0 644 u:object_r:system_file:s0

    log "Optimizing"
    dex2oat --dex-file="$PATCHED_JAR" --android-root=/system \
        --instruction-set="$INS_SET" --oat-file="${TARGET_JAR_PATH}/oat/${INS_SET}/${TARGET_JAR_BASE}.odex" \
        --app-image-file="${TARGET_JAR_PATH}/oat/${INS_SET}/${TARGET_JAR_BASE}.art" --no-generate-debug-info \
        --generate-mini-debug-info || {
        D2O_LOG=$(logcat -d -s "dex2oat")
        ui_print "dex2oat failed."
        ui_print "$D2O_LOG"
        abort
    }
    for ext in odex vdex art; do
        set_perm "${TARGET_JAR_PATH}/oat/$INS_SET/${TARGET_JAR_BASE}.${ext}" 0 0 644 u:object_r:system_file:s0
    done

    rm -r "$TMPPATH"
    TARGET_OAT_NAME=${TARGET_JAR//\//@} TARGET_OAT_NAME=${TARGET_OAT_NAME:1}
    rm /data/dalvik-cache/"$INS_SET"/"$TARGET_OAT_NAME"@classes.* 2>/dev/null || :
    rm /data/misc/apexdata/com.android.art/dalvik-cache/"$INS_SET"/"$TARGET_OAT_NAME"@classes.* 2>/dev/null || :
}

main "/system/framework/services.jar" || abort

if [ -f "/system/framework/semwifi-service.jar" ]; then
    ui_print ""
    log "OneUI detected: semwifi-service.jar"
    main "/system/framework/semwifi-service.jar" || abort
elif [ -f "/system_ext/framework/miui-services.jar" ]; then
    ui_print ""
    log "HyperOS detected: miui-services.jar"
    main "/system_ext/framework/miui-services.jar" || abort
fi

if [ ! -d "$MODPATH/system/" ] && [ ! -d "$MODPATH/system_ext/" ]; then
    abort "  All patches failed!"
fi

rm -r "$MODPATH/util"

ui_print ""
ui_print "  by github.com/j-hc"

set +eu
