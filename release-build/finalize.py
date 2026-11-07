import os,re,subprocess,hashlib,datetime,shutil,sys
A='/run/media/leohearts/Data/rk3288-a11'; R=A+'/release'; B=R+'/build'; S=R+'/stage'
DATE=os.environ.get('RELEASE_DATE') or datetime.date.today().isoformat()
NAME='ifive-mini4s-android11-'+DATE
K='/tmp/rk3288-port/src/rk-kernel'
khead=open(B+'/kernel-head.txt').read().strip()
ksubj=subprocess.check_output(['git','-C',K,'log','-1','--format=%s',khead],text=True).strip()
unc=[l[3:] for l in open(B+'/kernel-uncommitted.txt').read().splitlines() if l.strip()]
bootargs=re.search(r'bootargs = "([^"]*)"',open(B+'/resource-release.dts').read()).group(1)
changes='''
* **Timed reset removed.** The developer builds hard-reset the tablet into download mode 900 s after every boot (`rkdeadline=900`, plus `rkwdt=1 rkwdt_stop=0 rkwdt_loader=1 rkwdt_sgrf=0x00420000`, `rkdump=...` in the DTB bootargs; `arch/arm/boot/dts/rk3288-ifive-mini4s.dts:37`). The release bootargs carry `rkwdt=0` and none of the other `rk*` options, so no watchdog is armed and no deadline thread exists. The `rk_wdt_backstop` driver is still compiled in, but only for its root-only `reset_loader` sysfs trigger (the way back into download mode, see above).
* **Kernel config** (developer `.config` -> `kernel-release.config`, diff = `kernel-release.fragment`): `RK_PANIC_TO_LOADER` off (it held the CPU 12 s on panic and 24 s on `reboot loader` with IRQs off, then reset to download mode), `RK_PROBE_POINTS` off, `RK_LOGDUMP` off (periodic kpanic log writer), `DEBUG_INFO` off, soft/hard lock-up detectors off (+ their panic options), hung-task panic off and timeout 10 s -> 120 s, `PANIC_ON_OOPS` off, `PANIC_TIMEOUT` 1 -> 5 s (a panic now reboots into Android, not into download mode), `SCHED_STACK_END_CHECK` off, `BUG_ON_DATA_CORRUPTION` off.
* **Kernel source**: built from the committed tree only. The developer kernel was built from a working tree that also carried uncommitted bring-up code, which is NOT in the release: `TRACE:`+`dump_stack()` prints in `kernel_power_off()`/`machine_power_off()`, a PMIC register read on every PMIC interrupt (`rn5t618_irq_log`), and camera bring-up knobs/dumps (`gc2145`, `isp1`; defaults were no-ops).
* **Userspace** (`images/super.img` = the verified developer super18, unchanged): audited, nothing added by this project that logs or polls. Present but unused: `/system/bin/rkdebug.sh` (not referenced by any init script).
* **Deliberately kept** (needed or no measurable cost): `userdebug` build with root adb and `ro.adb.secure=0`; SELinux permissive; `DEBUG_LIST=y` (the Wi-Fi module `bcmdhd.ko` imports `__list_add_valid`); `DETECT_HUNG_TASK=y` and `SCHEDSTATS=y` (they change `struct task_struct`, and with it the exported-symbol CRCs that `bcmdhd.ko` was built against; panic action removed, schedstats stay disabled at run time); `console=ttyFIQ0 loglevel=4 log_buf_len=1M printk.devkmsg=on`, ftrace/tracefs infrastructure (tracing is off), pstore/ramoops.
'''
rd=open(B+'/README.md.tmpl').read()
vals={'DATE':DATE,'CHANGES':changes.strip(),'KHEAD':khead,'KSUBJ':ksubj,'UNCOMMITTED':', '.join('`%s`'%u for u in unc)}
for k,v in vals.items(): rd=rd.replace('{{%s}}'%k,v)
assert '{{' not in rd
open(S+'/README.md','w').write(rd)
# BUILD-INFO
base=open(B+'/release.fragment').read()
info=f'''iFive mini 4S Android 11 release {DATE}
Assembled {datetime.datetime.now().isoformat(timespec="seconds")} on the build host (no tablet attached).

Kernel   : 4.19.232, tree TinkerBoard-Android/rockchip-android-kernel local branch ifive-mini4s-a11
           commit {khead}
           "{ksubj}"
           built from `git archive {khead}` (ksrc-release), O=kbuild-release, ARCH=arm, CROSS_COMPILE=arm-linux-gnueabi- (Fedora 44 gcc-arm-linux-gnu 16.2.1)
           make O=kbuild-release olddefconfig; merge_config.sh -m <developer .config> kernel-release.fragment; olddefconfig; make zImage rk3288-ifive-mini4s.dtb
           developer .config = kbuild-cif5/.config (the config of the last verified developer kernel, work-cif5/cif5.krnl sha256 9509a62a...)
Uncommitted files in the kernel tree at build time (not used): {', '.join(unc)}
Resource : DTB from the same commit; /chosen/bootargs edited:
           {bootargs}
           logos from the verified developer resource image (res98-cif3)
Ramdisk  : developer mk-ramdisk.krnl unchanged (only init + fstab.rk30board)
Super    : developer super18.img unchanged (system/system_ext/vendor/product/odm)
Loader   : tablet stock RK3288UbootLoader_V2.30.10.bin (BOOT format), from the tablet's own firmware package

Verification done on the build host
 - module ABI: every exported-symbol CRC shared with the developer kernel is identical (Module.symvers diff vs kbuild-cif5: only touch_softlockup_watchdog is gone);
   module_layout 0x8befa47d == developer kernel; no vendor .ko imports the missing symbol.
 - sha256sum -c SHA256SUMS; unzip -t.
NOT verified here: booting this exact image set on a tablet (the previous developer set - cif5.krnl + res98-cif3 + super18 + mk-ramdisk - was boot-tested; the release differs by kernel config/commit and the bootargs).

Kernel config fragment applied:
{base}
'''
open(S+'/BUILD-INFO.txt','w').write(info)
# SHA256SUMS over everything except itself
files=[]
for root,_,fs in os.walk(S):
    for f in fs:
        p=os.path.relpath(os.path.join(root,f),S)
        if p in('SHA256SUMS','README.md.tmpl'): continue
        files.append(p)
files.sort()
with open(S+'/SHA256SUMS','w') as o:
    for p in files:
        h=hashlib.sha256()
        with open(S+'/'+p,'rb') as f:
            for ch in iter(lambda:f.read(1<<20),b''): h.update(ch)
        o.write('%s  %s\n'%(h.hexdigest(),p))
print(open(S+'/SHA256SUMS').read())
