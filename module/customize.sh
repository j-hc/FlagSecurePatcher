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
        com.android.tools.smali.baksmali.Main "$@" || abort "baksmali err: $SERR"
}

smali() {
    ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/smali.jar" app_process "$MODPATH" \
        com.android.tools.smali.smali.Main "$@" || abort "smali err: $SERR"
}

get_class() {
    # $SIG - $DEX $CLASS
    for DEX in "$TMPPATH/$TARGET_JAR_BASE"/classes*; do
        CLASS=$(baksmali l m "$DEX" -a "$API" | grep ";->$1" | grep -Fv '$') || continue
        CLASS="${CLASS#L}" CLASS="${CLASS%%;*}"
        return 0
    done
    return 1
}

patch() {
    signature="$1" code="$2"

    get_class "$signature" || {
        loge "Method not found"
        return 1
    }
    DEXBASE="${DEX##*/}" DEXBASE="${DEXBASE%.*}"
    TARGET_SMALI="$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE/$CLASS.smali"
    [ -d "$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE" ] || {
        log "Disassembling $DEXBASE.dex"
        baksmali d "$DEX" -o "$TMPPATH/$TARGET_JAR_BASE-da/$DEXBASE" --di False -a "$API"
    }
    METHOD=$(grep -nx "\.method .*$signature" "$TARGET_SMALI") || {
        loge "Method not found in class"
        return 1
    }
    [ "$(echo "$METHOD" | wc -l)" = 1 ] || abort "Multiple definitions: ${METHOD}"
    METHOD_NR="${METHOD%:*}"
    SMALI_PATCHED="$TMPPATH/${TARGET_SMALI##*/}"

    CODE="$code" awk -v METHOD_NR="$METHOD_NR" '
NR == METHOD_NR {
    in_method = 1
    print
    print ENVIRON["CODE"]
    next
}
/\.end method/ && in_method {
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

main() {
    TARGET_JAR="$1"
    TARGET_JAR_BASE="${TARGET_JAR%.*}"

    mkdir "$TMPPATH"
    cp "$(magisk --path 2>/dev/null)/.magisk/mirror/system/framework/$TARGET_JAR" "$TMPPATH" 2>/dev/null \
        || cp "$NVBASE/modules/flagsecurepatcher/${TARGET_JAR}.bak.${BDATE_PROP}" "$TMPPATH/$TARGET_JAR" 2>/dev/null \
        || cp "/system/framework/$TARGET_JAR" "$TMPPATH"
    cp "$TMPPATH/$TARGET_JAR" "$MODPATH/${TARGET_JAR}.bak.${BDATE_PROP}"

    log "Extracting $TARGET_JAR_BASE"
    mkdir "$TMPPATH/$TARGET_JAR_BASE"
    unzip -q "$TMPPATH/$TARGET_JAR" -d "$TMPPATH/$TARGET_JAR_BASE"
    [ -f "$TMPPATH/$TARGET_JAR_BASE/classes.dex" ] || abort "ROM is not supported"

    if [ $ISL_patched = 0 ]; then
        log "Patching isSecureLocked"
        isSecureLockedCode='
    .locals 1
    const/4 v0, 0x0
    return v0'
        if patch 'isSecureLocked(.*)Z' "$isSecureLockedCode"; then
            log "Patched successfully "
            ISL_patched=1
        else loge "isSecureLocked patch failed"; fi
    fi

    if [ "$API" -ge 34 ] && [ $NSL_patched = 0 ]; then
        log "Patching notifyScreenshotListeners (API >= 34)"
        notifyScreenshotListenersCode='
    .locals 1
    .annotation system Ldalvik/annotation/Signature;
        value = {
            "(I)",
            "Ljava/util/List<",
            "Landroid/content/ComponentName;",
            ">;"
        }
    .end annotation
    invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;
    move-result-object p1
    return-object p1'
        if patch 'notifyScreenshotListeners(I)Ljava/util/List;' "$notifyScreenshotListenersCode"; then
            log "Patched successfully "
            NSL_patched=1
        else loge "notifyScreenshotListeners patch failed"; fi
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

    PATCHED="$MODPATH/system/framework/$TARGET_JAR"
    zipalign -p -z 4 "$TMPPATH/$TARGET_JAR_BASE-patched.zip" "$PATCHED"
    set_perm "$PATCHED" 0 0 644 u:object_r:system_file:s0

    log "Optimizing"
    if [ "$ARCH" = x64 ]; then INS_SET=x86_64; else INS_SET=$ARCH; fi
    mkdir -p "$MODPATH/system/framework/oat/$INS_SET"
    dex2oat --dex-file="$PATCHED" --android-root=/system \
        --instruction-set="$INS_SET" --oat-file="$MODPATH/system/framework/oat/$INS_SET/$TARGET_JAR_BASE.odex" \
        --app-image-file="$MODPATH/system/framework/oat/$INS_SET/$TARGET_JAR_BASE.art" --no-generate-debug-info \
        --generate-mini-debug-info || {
        D2O_LOG=$(logcat -d -s "dex2oat")
        ui_print "$D2O_LOG"
        abort "dex2oat failed."
    }
    for ext in odex vdex art; do
        set_perm "$MODPATH/system/framework/oat/$INS_SET/$TARGET_JAR_BASE.${ext}" 0 0 644 u:object_r:system_file:s0
    done

    rm -r "$TMPPATH"
    rm /data/dalvik-cache/"$INS_SET"/system@framework@"$TARGET_JAR"@classes.* 2>/dev/null || :
    rm /data/misc/apexdata/com.android.art/dalvik-cache/"$INS_SET"/system@framework@"$TARGET_JAR"@classes.* 2>/dev/null || :
}

main "services.jar" || abort

if { { [ $NSL_patched = 0 ] && [ "$API" -ge 34 ]; } || [ $ISL_patched = 0 ]; } \
    && [ -f "/system/framework/semwifi-service.jar" ]; then
    ui_print ""
    log "OneUI detected. Patching semwifi-service.jar"
    main "semwifi-service.jar" || abort
fi
if [ $NSL_patched = 0 ] && [ $ISL_patched = 0 ]; then abort "All patches failed"; fi

rm -r "$MODPATH/util"

ui_print ""
ui_print "  by github.com/j-hc"

set +eu
