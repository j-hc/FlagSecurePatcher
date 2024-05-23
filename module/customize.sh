#!/system/bin/sh

set -e

LIBPATH="$MODPATH/util/lib/${ARCH}"
export PATH="${PATH}:$MODPATH/util/bin/${ARCH}"
chmod -R 755 "$MODPATH/util/"

TMPPATH="$MODPATH/tmp"
mkdir "$TMPPATH"

cp "$(magisk --path)/.magisk/mirror/system/framework/services.jar" "$TMPPATH" \
    || cp /system/framework/services.jar "$TMPPATH"

ui_print "* Extracting services"
unzip -q "$TMPPATH/services.jar" -d "$TMPPATH/services"
for C in "$TMPPATH"/services/classes*; do
    if [ "$C" = "$TMPPATH/services/classes*" ]; then
        ui_print "classes glob fail"
        abort "ROM is not supported"
    fi
    O="${C##*/}"
    O="${O%.*}"
    ui_print "* Disassembling $O"
    ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/baksmali.jar" app_process "$MODPATH" \
        com.android.tools.smali.baksmali.Main d "$C" -o "$TMPPATH/services-da/$O"
done

patch() {
    signature="$1"
    code="$2"
    TARGET=$(grep -rn -x "$signature" "$TMPPATH/services-da") || abort "Method not found"
    TARGET_NR="${TARGET%:*}"
    TARGET_NR="${TARGET_NR##*:}"
    TARGET_SMALI="${TARGET%%:*}"
    TARGET_CLASS="${TARGET_SMALI#"$TMPPATH/services-da/"}"
    TARGET_CLASS="${TARGET_CLASS%%/*}"
    TMP_TARGET_CLASS="$TMPPATH/${TARGET_SMALI##*/}"

    awk -v TARGET_NR="$TARGET_NR" -v CODE="$code" '
NR == TARGET_NR {
    in_method = 1
    print
    print CODE
    next
}
/\.end method/ && in_method {
    print
    in_method = 0
    next
}
{ if (!in_method) print }
' "$TARGET_SMALI" >"$TMP_TARGET_CLASS"
    mv -f "$TMP_TARGET_CLASS" "$TARGET_SMALI"
}

ui_print "* Patching isSecureLocked"
isSecureLockedCode='
.registers 1
const/4 v0, 0x0
return v0'
patch '\.method .*isSecureLocked(.*)Z' "$isSecureLockedCode"

if [ "$API" -ge 34 ]; then
    ui_print "* Patching notifyScreenshotListeners (SDK level >= 34)"
    notifyScreenshotListenersCode='
.registers 2
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
ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/smali.jar" app_process "$MODPATH" \
    com.android.tools.smali.smali.Main a -a "$API" "$TMPPATH/services-da/$TARGET_CLASS" \
    -o "$TMPPATH/services/$TARGET_CLASS.dex"

ui_print "* Zipping"
cd "$TMPPATH/services/" || abort "unreachable1"
LD_LIBRARY_PATH=$LIBPATH zip -q -0 -r "$TMPPATH/services-patched.zip" ./
cd "$MODPATH" || abort "unreachable2"

ui_print "* Zip aligning"
LD_LIBRARY_PATH=$LIBPATH zipalign -p -z 4 "$TMPPATH/services-patched.zip" "$MODPATH/system/framework/services.jar"
set_perm "$MODPATH/system/framework/services.jar" 0 0 644 u:object_r:system_file:s0

ui_print "* Cleanup"
rm -r "$TMPPATH" "$MODPATH/util"
if [ "$ARCH" = x64 ]; then INS_SET=x86_64; else INS_SET=$ARCH; fi
rm "/data/dalvik-cache/$INS_SET/system@framework@services.jar@classes.dex" || :
rm "/data/dalvik-cache/$INS_SET/system@framework@services.jar@classes.vdex" || :

ui_print "* Optimizing"
mkdir "$MODPATH/system/framework/oat/$INS_SET"
dex2oat --dex-file="$MODPATH/system/framework/services.jar" --instruction-set="$INS_SET" --compiler-filter=everything \
    --profile-file="/system/framework/services.jar.prof" --oat-file="$MODPATH/system/framework/oat/$INS_SET/services.odex" \
    --app-image-file="$MODPATH/system/framework/oat/$INS_SET/services.art" || {
    logcat -d -s "dex2oat" >/data/local/tmp/FlagSecurePatcher-dex2oat.log
    abort "* Optimization step failed. Logs are saved to /data/local/tmp/FlagSecurePatcher-dex2oat.log"
}
for ext in odex vdex art; do
    set_perm "$MODPATH/system/framework/oat/$INS_SET/services.${ext}" 0 0 644 u:object_r:system_file:s0
done

ui_print ""
ui_print "  by github.com/j-hc"

set +e
