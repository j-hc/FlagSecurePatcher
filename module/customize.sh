#!/system/bin/sh

LIBPATH="$MODPATH/util/lib/${ARCH}"
export PATH="${PATH}:$MODPATH/util/bin/${ARCH}"
TMPPATH="$MODPATH/tmp"

chmod -R 755 "$MODPATH/util/bin/${ARCH}" "$LIBPATH"
mkdir "$TMPPATH"
cp /system/framework/services.jar "$TMPPATH"

ui_print "* Extracting services"
unzip -q "$TMPPATH/services.jar" -d "$TMPPATH/services"
for C in "$TMPPATH"/services/classes*; do
    O="${C##*/}"
    O="${O%.*}"
    ui_print "* Disassembling $O"
    ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/baksmali.jar" app_process "$MODPATH" \
        com.android.tools.smali.baksmali.Main d "$C" -o "$TMPPATH/services-da/$O"
done

TARGET=$(grep -rn -Fx '.method isSecureLocked()Z' "$TMPPATH/services-da")
[ -z "$TARGET" ] && abort "Method not found"
TARGET_SMALI="${TARGET%%:*}"
TARGET_CLASS="${TARGET_SMALI#"$TMPPATH/services-da/"}"
TARGET_CLASS="${TARGET_CLASS%%/*}"

ui_print "* Patching"
awk '
BEGIN {
    in_method = 0
}
/\.method isSecureLocked\(\)Z/ {
    in_method = 1
    print
    print "    .registers 1"
    print "    const/4 v0, 0x0"
    print "    return v0"
    next
}
/\.end method/ && in_method {
    in_method = 0
    print
    next
}
{
    if (!in_method) print
}
' "$TARGET_SMALI" >"$TMPPATH/WindowState.smali"
mv -f "$TMPPATH/WindowState.smali" "$TARGET_SMALI"

ui_print "* Re-assembling"
A=$(getprop ro.build.version.sdk)
ANDROID_DATA="$TMPPATH" CLASSPATH="$MODPATH/util/smali.jar" app_process "$MODPATH" \
    com.android.tools.smali.smali.Main a -a "$A" "$TMPPATH/services-da/$TARGET_CLASS" \
    -o "$TMPPATH/services/$TARGET_CLASS.dex"

ui_print "* Zipping"
cd "$TMPPATH/services/" || abort ""
LD_LIBRARY_PATH=$LIBPATH zip -q -0 -r "$TMPPATH/services-patched.zip" ./
cd "$MODPATH" || abort ""

ui_print "* Zip aligning"
LD_LIBRARY_PATH=$LIBPATH zipalign -p -z 4 "$TMPPATH/services-patched.zip" "$TMPPATH/services-patched.jar"
mv "$TMPPATH/services-patched.jar" "$MODPATH/system/framework/services.jar"

ui_print "* Cleanup"
rm -r "$TMPPATH" "$MODPATH/util"

ui_print ""
ui_print "  by github.com/j-hc"
