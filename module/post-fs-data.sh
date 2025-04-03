MODDIR=${0%/*}
BDATE_PROP=$(getprop ro.build.date.utc)

if [ -z "$(find "$MODDIR" -name "*.bak.${BDATE_PROP}" -maxdepth 1 -print -quit)" ]; then
	touch "$MODDIR"/disable
	sed -i "s/^des.*/description=⚠️ Needs reflash: Patch was applied on an older OS/g" "$MODDIR/module.prop"
fi
