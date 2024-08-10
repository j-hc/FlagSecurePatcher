#!/system/bin/sh

set -eu

LIBPATH="$MODPATH/util/lib/${ARCH}"
alias zip='LD_LIBRARY_PATH=$LIBPATH $MODPATH/util/bin/$ARCH/zip'
alias zipalign='LD_LIBRARY_PATH=$LIBPATH $MODPATH/util/bin/$ARCH/zipalign'
chmod -R 755 "$MODPATH/util/"
TMPPATH="$MODPATH/tmp"

BDATE_PROP=$(getprop ro.build.date.utc)

log() { ui_print "[+] $1"; }
loge() { ui_print "[-] $1"; }

baksmali() {
    ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/baksmali.jar" app_process "$MODPATH" \
        com.android.tools.smali.baksmali.Main "$@" || abort "baksmali err"
}

smali() {
    ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/smali.jar" app_process "$MODPATH" \
        com.android.tools.smali.smali.Main "$@" || abort "smali err"
}

get_class() {
    # $SIG -- $DEX $CLASS
    for DEX in "$TMPPATH/$TARGET_JAR_BASE"/classes*; do
        CLASS=$(baksmali l m "$DEX" -a "$API" | grep ";->$1" | grep -Fv '$') || continue
        [ "$(echo "$CLASS" | wc -l)" = 1 ] || abort "Multiple definitions (get_class): '${CLASS}'"
        CLASS="${CLASS#L}" CLASS="${CLASS%%;*}"
        return 0
    done
    return 1
}

patch() {
    signature=$1 code=$2 locals=$3

    get_class "$signature" || {
        loge "Method not found"
        return 1
    }
    DEXBASE="${DEX##*/}" DEXBASE="${DEXBASE%.*}"
    TARGET_SMALI="$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE/$CLASS.smali"
    [ -d "$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE" ] || {
        log "Disassembling $DEXBASE.dex"
        baksmali d "$DEX" -o "$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE" -l -a "$API"
    }
    METHOD=$(grep -nx "\.method .*$signature" "$TARGET_SMALI" 2>/dev/null) || {
        loge "Method not found in class"
        return 1
    }
    [ "$(echo "$METHOD" | wc -l)" = 1 ] || abort "Multiple definitions: '${METHOD}'"
    echo "$METHOD" | grep -Fvq abstract >/dev/null 2>/dev/null || abort "Abstract method: '${METHOD}'"

    METHOD_NR="${METHOD%:*}"
    SMALI_PATCHED="$TMPPATH/${TARGET_SMALI##*/}"

    CODE="$code" awk -v METHOD_NR="$METHOD_NR" -v LOCALS="$locals" '
NR == METHOD_NR {
    in_method = 1
    print
    print "    .locals " LOCALS
    next
    if (in_annotation) {
        print
        next
    }
    print
    next
}
/\.annotation/ { in_annotation = 1 }
in_annotation {
    print
    if ($0 ~ /\.end annotation/) in_annotation = 0
    next
}
/\.end method/ && in_method {
    print ENVIRON["CODE"]
    print
    in_method = 0
    next
}
{ if (!in_method) print }
' "$TARGET_SMALI" >"$SMALI_PATCHED"
    mv -f "$SMALI_PATCHED" "$TARGET_SMALI"
}

ISL_patched=0
NSL_patched=0
ACD_patched=1

main() {
    TARGET_JAR=$1
    TARGET_JAR_NAME=${TARGET_JAR##*/}
    TARGET_JAR_BASE=${TARGET_JAR_NAME%.*}
    TARGET_JAR_PATH=${MODPATH}${TARGET_JAR%/*}

    mkdir -p "${TARGET_JAR_PATH}/oat"
    mkdir "$TMPPATH"

    cp "$(magisk --path 2>/dev/null)/.magisk/mirror${TARGET_JAR}" "$TMPPATH" 2>/dev/null ||
        cp "/data/adb/modules/flagsecurepatcher/${TARGET_JAR_NAME}.bak.${BDATE_PROP}" "$TMPPATH/$TARGET_JAR_NAME" 2>/dev/null ||
        if [ ! -d "/data/adb/modules/flagsecurepatcher" ]; then
            cp "$TARGET_JAR" "$TMPPATH"
        else abort "No backup jar was found. Disable the module, reboot and reflash."; fi
    cp "$TMPPATH/$TARGET_JAR_NAME" "$MODPATH/${TARGET_JAR_NAME}.bak.${BDATE_PROP}"

    log "Extracting $TARGET_JAR_BASE"
    mkdir "$TMPPATH/$TARGET_JAR_BASE"
    unzip -q "$TMPPATH/$TARGET_JAR_NAME" -d "$TMPPATH/$TARGET_JAR_BASE"
    [ -f "$TMPPATH/$TARGET_JAR_BASE/classes.dex" ] || abort "ROM is not supported"

    if [ $ACD_patched = 1 ] && [ $ISL_patched = 0 ]; then
        log "Patching isSecureLocked"
        isSecureLockedCode='
    const/4 v0, 0x0
    return v0'
        if patch 'isSecureLocked(.*)Z' "$isSecureLockedCode" 1; then
            log "Patched successfully "
            ISL_patched=1
        else loge "isSecureLocked patch failed"; fi
    fi

    if [ $ACD_patched = 1 ] && [ "$API" -ge 34 ] && [ $NSL_patched = 0 ]; then
        log "Patching notifyScreenshotListeners (API >= 34)"
        notifyScreenshotListenersCode='
    invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;
    move-result-object p1
    return-object p1'
        if patch 'notifyScreenshotListeners(I)Ljava/util/List;' "$notifyScreenshotListenersCode" 1; then
            log "Patched successfully "
            NSL_patched=1
        else loge "notifyScreenshotListeners patch failed"; fi
    fi

    if [ $ACD_patched = 0 ]; then
        log "Patching notAllowCaptureDisplay"
        if patch 'notAllowCaptureDisplay(.*)Z' "$isSecureLockedCode" 1; then
            log "Patched successfully "
            ACD_patched=1
        else loge "notAllowCaptureDisplay patch failed"; fi
    fi

    for CL in "$TMPPATH/$TARGET_JAR_BASE-da"/classes*; do
        CLBASE="${CL##*/}"
        log "Re-assembling $CLBASE.dex"
        smali a -a "$API" "$CL" -o "$TMPPATH/$TARGET_JAR_BASE/$CLBASE.dex" || abort
    done

    log "Zipaligning"
    cd "$TMPPATH/$TARGET_JAR_BASE/"
    zip -q0r "$TMPPATH/$TARGET_JAR_BASE-patched.zip" .
    cd "$MODPATH"

    PATCHED="${MODPATH}${TARGET_JAR}"
    zipalign -p -z 4 "$TMPPATH/$TARGET_JAR_BASE-patched.zip" "$PATCHED"
    set_perm "$PATCHED" 0 0 644 u:object_r:system_file:s0

    log "Optimizing"
    if [ "$ARCH" = x64 ]; then INS_SET=x86_64; else INS_SET=$ARCH; fi
    mkdir -p "${TARGET_JAR_PATH}/oat/$INS_SET"
    dex2oat --dex-file="$PATCHED" --android-root=/system \
        --instruction-set="$INS_SET" --oat-file="${TARGET_JAR_PATH}/oat/$INS_SET/$TARGET_JAR_BASE.odex" \
        --app-image-file="${TARGET_JAR_PATH}/oat/$INS_SET/$TARGET_JAR_BASE.art" --no-generate-debug-info \
        --generate-mini-debug-info || {
        D2O_LOG=$(logcat -d -s "dex2oat")
        ui_print "$D2O_LOG"
        abort "dex2oat failed."
    }
    for ext in odex vdex art; do
        set_perm "${TARGET_JAR_PATH}/oat/$INS_SET/$TARGET_JAR_BASE.${ext}" 0 0 644 u:object_r:system_file:s0
    done

    rm -r "$TMPPATH"
    TARGET_OAT_NAME=${TARGET_JAR//\//@} TARGET_OAT_NAME=${TARGET_OAT_NAME:1}
    rm /data/dalvik-cache/"$INS_SET"/"$TARGET_OAT_NAME"@classes.* 2>/dev/null || :
    rm /data/misc/apexdata/com.android.art/dalvik-cache/"$INS_SET"/"$TARGET_OAT_NAME"@classes.* 2>/dev/null || :
}

main "/system/framework/services.jar" || abort

if [ -f "/system/framework/semwifi-service.jar" ]; then
    ui_print ""
    log "OneUI detected: Patching semwifi-service.jar"
    main "/system/framework/semwifi-service.jar" || abort
elif [ -f "/system_ext/framework/miui-services.jar" ]; then
    ui_print ""
    log "HyperOS detected: Patching miui-services.jar"
    ACD_patched=0
    main "/system_ext/framework/miui-services.jar" || abort
fi
if [ $NSL_patched = 0 ] && [ $ISL_patched = 0 ] && [ $ACD_patched = 0 ]; then abort "All patches failed"; fi

rm -r "$MODPATH/util"

ui_print ""
ui_print "  by github.com/j-hc"

set +eu
