#!/system/bin/sh

set -eu

LIBPATH="$MODPATH/util/lib/${ARCH}"
alias zip='$MODPATH/util/bin/$ARCH/zip'
alias zipalign='$MODPATH/util/bin/$ARCH/zipalign'
chmod -R 755 "$MODPATH/util/"

TMPPATH="$MODPATH/tmp"
mkdir "$TMPPATH"

cp "$(magisk --path 2>/dev/null)/.magisk/mirror/system/framework/services.jar" "$TMPPATH" 2>/dev/null \
    || cp "$NVBASE/modules/flagsecurepatcher/services.jar.bak" "$TMPPATH" 2>/dev/null \
    || cp /system/framework/services.jar "$TMPPATH"
cp "$TMPPATH/services.jar" "$MODPATH/services.jar.bak"

ui_print "* Extracting services"
mkdir "$TMPPATH/services"
unzip -q "$TMPPATH/services.jar" -d "$TMPPATH/services"
for C in "$TMPPATH"/services/classes*; do
    if [ "$C" = "$TMPPATH/services/classes*" ]; then
        ui_print "classes glob fail"
        abort "ROM is not supported"
    fi
    O="${C##*/}"
    O="${O%.*}"
    ui_print "* Disassembling $O"
    SERR=$(ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/baksmali.jar" app_process "$MODPATH" \
        com.android.tools.smali.baksmali.Main d "$C" -o "$TMPPATH/services-da/$O" 2>&1)
    if [ "$SERR" ]; then abort "ERROR: $SERR"; fi
done

patch() {
    signature="$1"
    code="$2"
    TARGET=$(grep -rn -x "$signature" "$TMPPATH/services-da" | grep -v 'abstract') || abort "Method not found"
    TARGET_NR="${TARGET%:*}"
    TARGET_NR="${TARGET_NR##*:}"
    TARGET_SMALI="${TARGET%%:*}"
    TARGET_CLASS="${TARGET_SMALI#"$TMPPATH/services-da/"}"
    TARGET_CLASS="${TARGET_CLASS%%/*}"
    TARGET_SMALI_PATCHED="$TMPPATH/${TARGET_SMALI##*/}"

    CODE="$code" awk -v TARGET_NR="$TARGET_NR" '
NR == TARGET_NR {
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
' "$TARGET_SMALI" >"$TARGET_SMALI_PATCHED"
    mv -f "$TARGET_SMALI_PATCHED" "$TARGET_SMALI"
}

ui_print "* Patching isSecureLocked"
isSecureLockedCode='
.locals 1
const/4 v0, 0x0
return v0'
patch '\.method .*isSecureLocked(.*)Z' "$isSecureLockedCode"

if [ "$API" -ge 34 ]; then
    ui_print "* Patching notifyScreenshotListeners (API >= 34)"
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
    patch '\.method .*notifyScreenshotListeners(I)Ljava/util/List;' "$notifyScreenshotListenersCode"
fi

ui_print "* Re-assembling"
SERR=$(ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/smali.jar" app_process "$MODPATH" \
    com.android.tools.smali.smali.Main a -a "$API" "$TMPPATH/services-da/$TARGET_CLASS" \
    -o "$TMPPATH/services/$TARGET_CLASS.dex" 2>&1)
if [ "$SERR" ]; then abort "ERROR: $SERR"; fi

ui_print "* Zipping"
cd "$TMPPATH/services/" || abort "unreachable1"
LD_LIBRARY_PATH=$LIBPATH zip -q -0 -r "$TMPPATH/services-patched.zip" ./
cd "$MODPATH" || abort "unreachable2"

ui_print "* Zip aligning"
LD_LIBRARY_PATH=$LIBPATH zipalign -p -z 4 "$TMPPATH/services-patched.zip" "$MODPATH/system/framework/services.jar"
set_perm "$MODPATH/system/framework/services.jar" 0 0 644 u:object_r:system_file:s0

ui_print "* Optimizing"
if [ "$ARCH" = x64 ]; then INS_SET=x86_64; else INS_SET=$ARCH; fi
mkdir "$MODPATH/system/framework/oat/$INS_SET"
dex2oat --dex-file="$MODPATH/system/framework/services.jar" --profile-file="/system/framework/services.jar.prof" \
    --instruction-set="$INS_SET" --oat-file="$MODPATH/system/framework/oat/$INS_SET/services.odex" \
    --app-image-file="$MODPATH/system/framework/oat/$INS_SET/services.art" --no-generate-debug-info \
    --generate-mini-debug-info --android-root=/system || {
    D2O_LOG=$(logcat -d -s "dex2oat")
    ui_print "$D2O_LOG"
    abort "* dex2oat failed."
}
for ext in odex vdex art; do
    set_perm "$MODPATH/system/framework/oat/$INS_SET/services.${ext}" 0 0 644 u:object_r:system_file:s0
done

ui_print "* Cleanup"
rm -r "$TMPPATH" "$MODPATH/util"
rm "/data/dalvik-cache/$INS_SET/system@framework@services.jar@classes.dex" 2>/dev/null || :
rm "/data/dalvik-cache/$INS_SET/system@framework@services.jar@classes.vdex" 2>/dev/null || :

ui_print ""
ui_print "  by github.com/j-hc"

set +eu
