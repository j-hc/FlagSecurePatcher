---
name: Bug report
about: Create a report
title: ''
labels: ''
assignees: ''

---
Obtain everything listed below for a bug report:
* Android version
* Get the fw.zip and fw-ext.zip in termux with these commands then upload and link it here  
`pkg install zip && cd /system/framework/ && su -c $(command -v zip) -r9 /sdcard/fw.zip .`  
`pkg install zip && cd /system_ext/framework/ && su -c $(command -v zip) -r9 /sdcard/fw-ext.zip .`  

* Flash logs
* Logcat if you are getting a bootloop
