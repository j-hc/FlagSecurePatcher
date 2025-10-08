---
name: Bug report
about: Create a report
title: ''
labels: ''
assignees: ''

---
Obtain everything listed below for a bug report:
* Android version and ROM
* Get the fw.zip with these commands in termux then upload and link it here  
`zip --version || pkg install zip; rm /sdcard/fw.zip; su -c $(command -v zip) -r9 /sdcard/fw.zip /system/framework/ -x '*/oat/*' && su -c $(command -v zip) -r9 /sdcard/fw.zip /system_ext/framework/ -x '*/oat/*'`  

* Module flash logs
* Logcat of the boot if you are getting a bootloop or random side-effects
