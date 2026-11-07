#!/bin/bash
# build-res-release.sh: release resource image = res98-cif3 (verified) with release-only DTB changes:
# - /chosen bootargs: added console=tty0 fbcon=font:SUN12x22; removed rkdump=, rkwdt_stop=0, rkwdt_loader=1, rkdeadline, rkwdt_sgrf; rkwdt=1 -> rkwdt=0.
# - reboot-mode (syscon-reboot-mode @0x94, power-management@ff730000): status disabled -> okay, so `reboot loader`/`reboot recovery` write the reboot-mode register.
# - i2c@ff650000: CW2015@62 (compatible cw201x, as on stock A6). The loader's off-mode charge path needs this fuel gauge / dc-detect node; without it a plugged charger boots Android.
# - uboot-charge node removed (its charge-off flags must not ship in release).
# DTB comes from the release kernel build dir (identical to the cif5 DTB; checked by cmp), logos from res98-cif3.img.
set -eu
A=/run/media/leohearts/Data/rk3288-a11
B=$A/release/build
DTC=$A/release/build/tools/dtc
RT=$A/release/build/tools/resource_tool
SRC_DTB=$A/kbuild-release/arch/arm/boot/dts/rk3288-ifive-mini4s.dtb
OLDRES=$A/work-cif5/res98-cif3.img
OUT=$B/resource-release.img
W=$(mktemp -d $B/res.XXXXXX); trap 'rm -rf "$W"' EXIT
# staleness guard: the release DTB must be the reviewed OPP-floor build (see Opp.md, commit 5a748be58)
DTB_SHA256=1b17c3158ac0292feeed5ec45403d2d683ae698f02d6bed6442d6394ef14f4ea
echo "$DTB_SHA256  $SRC_DTB" | sha256sum -c --quiet || { echo "STOP: release DTB sha mismatch"; exit 3; }
"$RT" --unpack --image="$OLDRES" "$W/old" >/dev/null 2>&1 || { echo "STOP: unpack old res"; exit 3; }
# round trip: dtb -> dts -> dtb, must be structurally identical to the source dtb
"$DTC" -I dtb -O dts -o "$W/src.dts" "$SRC_DTB" 2>/dev/null
python3 - "$W/src.dts" "$W/rel.dts" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
m=re.search(r'\n(\s*bootargs = ")([^"]*)(";)',s)
old=m.group(2)
drop=[r'rkdump=\S+',r'rkwdt_stop=0',r'rkwdt_loader=1',r'rkdeadline=\d+',r'rkwdt_sgrf=\S+']
new=old
for d in drop:
    new,n=re.subn(r'(?:^| )'+d+r'(?= |$)','',new)
    if n!=1: sys.exit("STOP: %s matched %d times"%(d,n))
new,n=re.subn(r'(?:^| )rkwdt=1(?= |$)',lambda m: m.group(0).replace('rkwdt=1','rkwdt=0'),new)
if n!=1: sys.exit('STOP: rkwdt=1 matched %d'%n)
new=re.sub(' +',' ',new).strip()
# fbcon on the panel (owner requirement: hangs must be debuggable on screen); same as the fb dev resources minus loglevel
new,n=re.subn(r'^console=ttyFIQ0(?= )','console=ttyFIQ0 console=tty0 fbcon=font:SUN12x22',new)
if n!=1: sys.exit('STOP: console=ttyFIQ0 not first')
print("OLD:",old); print("NEW:",new)
s=s[:m.start(2)]+new+s[m.end(2):]
def span(text,start,hdr):
    h=re.compile(hdr).search(text,start)
    if not h: sys.exit('STOP: missing node '+hdr)
    depth=0
    for j in range(text.index('{',h.start()),len(text)):
        if text[j]=='{': depth+=1
        elif text[j]=='}':
            depth-=1
            if depth==0:
                if text[j+1]!=';': sys.exit('STOP: no ; after '+hdr)
                return h.start(), j+2
    sys.exit('STOP: unbalanced '+hdr)
if s.count('uboot-charge {')!=1: sys.exit('STOP: uboot-charge count')
b,e=span(s,0,r'\n\t*uboot-charge \{')
s=s[:b]+s[e:]
g=re.search(r'gpio0@ff750000 \{[^{}]*?phandle = <(0x[0-9a-f]+)>;',s)
if not g: sys.exit('STOP: gpio0 phandle')
GP=g.group(1)
for pin in ('0x7','0x8','0x9'):
    if re.search(r'<%s %s[ >]'%(GP,pin),s): sys.exit('STOP: gpio0 pin %s in use'%pin)
ib,ie=span(s,0,r'\n\t*i2c@ff650000 \{')
body=s[ib:ie]
pm=re.search(r'\n(\t*)pmic@32 \{',body)
if not pm: sys.exit('STOP: pmic@32 not in i2c@ff650000')
ind=pm.group(1); p=ind+'\t'
pb,pe=span(body,pm.start(),r'\n\t*pmic@32 \{')
cw=('\n'+ind+'CW2015@62 {\n'
    +p+'compatible = "cw201x";\n'
    +p+'reg = <0x62>;\n'
    +p+'dc_det_gpio = <%s 0x8 0x1>;\n'%GP
    +p+'bat_low_gpio = <%s 0x7 0x1>;\n'%GP
    +p+'chg_ok_gpio = <%s 0x9 0x0>;\n'%GP
    +p+'bat_config_info = <0x15 0x42 0x60 0x59 0x52 0x58 0x4d 0x48 0x48 0x44 0x44 0x46 0x49 0x48 0x32 0x24 0x20 0x17 0x13 0xf 0x19 0x3e 0x51 0x45 0x8 0x76 0xb 0x85 0xe 0x1c 0x2e 0x3e 0x4d 0x52 0x52 0x57 0x3d 0x1b 0x6a 0x2d 0x25 0x43 0x52 0x87 0x8f 0x91 0x94 0x52 0x82 0x8c 0x92 0x96 0xff 0x7b 0xbb 0xcb 0x2f 0x7d 0x72 0xa5 0xb5 0xc1 0x46 0xae>;\n'
    +p+'is_dc_charge = <0x1>;\n'
    +p+'is_usb_charge = <0x0>;\n'
    +ind+'};')
s=s[:ib]+body[:pe]+cw+body[pe:]+s[ie:]
print("CW2015@62 added under i2c@ff650000; gpio0 phandle",GP,"; uboot-charge removed")
rb=re.findall(r'\n\t*reboot-mode \{',s)
if len(rb)!=1: sys.exit('STOP: reboot-mode count %d'%len(rb))
rbb,rbe=span(s,0,r'\n\t*reboot-mode \{')
rblk,n=re.subn(r'status = "disabled";','status = "okay";',s[rbb:rbe])
if n!=1: sys.exit('STOP: reboot-mode status count %d'%n)
s=s[:rbb]+rblk+s[rbe:]
print("reboot-mode status: disabled -> okay")
open(sys.argv[2],'w').write(s)
PY
# i2c@ff160000 (touch) at 400 kHz: intended touch-rate change (TouchRate.md). Applies to A11 and GSI resources.
python3 - "$W/rel.dts" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
i=s.index('\ti2c@ff160000 {\n'); e=s.index('\n\t};\n',i)
node=s[i:e]
if 'clock-frequency' in node:
    assert re.search(r'clock-frequency = <(0x61a80|400000)>;', node), 'i2c@ff160000 clock-frequency not 400 kHz'
    open(p,'w').write(s); print('i2c@ff160000 clock-frequency already 400 kHz (from source)'); sys.exit(0)
m=re.search(r'\n\t\tstatus = "okay";\n',node); assert m, 'no status in i2c@ff160000'
node=node[:m.end()]+'\t\tclock-frequency = <0x61a80>;\n'+node[m.end():]
open(p,'w').write(s[:i]+node+s[e:])
print('i2c@ff160000 clock-frequency = 400 kHz added')
PY
"$DTC" -I dts -O dtb -o "$W/rk-kernel.dtb" "$W/rel.dts" 2>/dev/null
# control: unmodified dts -> dtb -> dts must reproduce the source dts exactly (round trip is lossless)
"$DTC" -I dts -O dtb -o "$W/ctl.dtb" "$W/src.dts" 2>/dev/null
"$DTC" -I dtb -O dts -o "$W/ctl.dts" "$W/ctl.dtb" 2>/dev/null
cmp "$W/src.dts" "$W/ctl.dts" || { echo "STOP: dts round trip not lossless"; exit 3; }
"$DTC" -I dts -O dts -o "$W/rel-norm.dts" "$W/rel.dts" 2>/dev/null
"$DTC" -I dtb -O dts -o "$W/check.dts" "$W/rk-kernel.dtb" 2>/dev/null
cmp -s "$W/rel-norm.dts" "$W/check.dts" || { echo "STOP: rebuilt DTB does not match rel.dts"; exit 3; }
cp "$W/old/logo.bmp" "$W/old/logo_kernel.bmp" "$W/"
( cd "$W" && "$RT" --pack --image="$W/resource.img" rk-kernel.dtb logo.bmp logo_kernel.bmp >/dev/null 2>&1 ) || { echo "STOP: pack failed"; exit 3; }
truncate -s 16777216 "$W/resource.img"
V=$W/verify; mkdir -p $V; "$RT" --unpack --image="$W/resource.img" "$V" >/dev/null 2>&1 || { echo "STOP: verify unpack"; exit 3; }
cmp "$W/rk-kernel.dtb" "$V/rk-kernel.dtb" && cmp "$W/old/logo.bmp" "$V/logo.bmp" && cmp "$W/old/logo_kernel.bmp" "$V/logo_kernel.bmp" || { echo "STOP: verify content"; exit 3; }
[ "$(xxd -p -l 4 "$W/resource.img")" = 52534345 ] || { echo "STOP: no RSCE magic"; exit 3; }
cp "$W/resource.img" "$OUT"; cp "$W/rel.dts" "$B/resource-release.dts"
( cd $B && sha256sum resource-release.img > resource-release.img.sha256 && cat resource-release.img.sha256 )
# GSI variant (resource-release-gsi.img): identical to the A11 release resource above except the blkdevparts token,
# which is taken from work-rl5/res-gsi-release.img (GSI layout: system 3072M, metadata 3368M, userdata 3448M).
# Logos are taken from that same GSI image (identical to the A11 logos; checked below).
GSIRES=$A/work-rl5/res-gsi-release.img
GSIOUT=$B/resource-release-gsi.img
G=$W/gsi; mkdir -p $G/old $G/pack $G/v
"$RT" --unpack --image="$GSIRES" "$G/old" >/dev/null 2>&1 || { echo "STOP: unpack gsi res"; exit 3; }
"$DTC" -I dtb -O dts -o "$G/old.dts" "$G/old/rk-kernel.dtb" 2>/dev/null
python3 - "$G/old.dts" "$W/rel.dts" "$G/rel.dts" <<'PY'
import sys,re
gold=open(sys.argv[1]).read(); a11=open(sys.argv[2]).read()
gb=re.findall(r'blkdevparts=\S+',gold); ab=re.findall(r'blkdevparts=\S+',a11)
if len(gb)!=1 or len(ab)!=1: sys.exit('STOP: blkdevparts count')
out=a11.replace(ab[0],gb[0],1)
if out.count('blkdevparts=')!=1: sys.exit('STOP: blkdevparts replace')
open(sys.argv[3],'w').write(out)
print("GSI blkdevparts:",gb[0])
PY
"$DTC" -I dts -O dtb -o "$G/rk-kernel.dtb" "$G/rel.dts" 2>/dev/null
"$DTC" -I dts -O dts -o "$G/rel-norm.dts" "$G/rel.dts" 2>/dev/null
"$DTC" -I dtb -O dts -o "$G/check.dts" "$G/rk-kernel.dtb" 2>/dev/null
cmp -s "$G/rel-norm.dts" "$G/check.dts" || { echo "STOP: GSI DTB does not match rel.dts"; exit 3; }
# dts diffs: A11 vs GSI new = blkdevparts only; GSI new vs res-gsi-release = DTB release changes only (bootargs identical)
python3 - "$W/rel.dts" "$G/rel.dts" "$G/old.dts" <<'PY' || { echo "STOP: GSI dts diff check"; exit 3; }
import sys,re
a=open(sys.argv[1]).read(); g=open(sys.argv[2]).read(); o=open(sys.argv[3]).read()
strip=lambda t: re.sub(r'blkdevparts=\S+','',t)
assert strip(a)==strip(g), 'A11 vs GSI differ outside blkdevparts'
ba=re.search(r'bootargs = "[^"]*"',g).group(0); bo=re.search(r'bootargs = "[^"]*"',o).group(0)
assert ba.replace(' console=tty0 fbcon=font:SUN12x22','')==bo, 'GSI bootargs differ from res-gsi-release (beyond fbcon)'
print('dts check ok: A11/GSI differ only in blkdevparts; GSI bootargs == res-gsi-release bootargs')
PY
cp "$G/old/logo.bmp" "$G/old/logo_kernel.bmp" "$G/pack/"
cp "$G/rk-kernel.dtb" "$G/pack/"
( cd "$G/pack" && "$RT" --pack --image="$G/resource.img" rk-kernel.dtb logo.bmp logo_kernel.bmp >/dev/null 2>&1 ) || { echo "STOP: gsi pack failed"; exit 3; }
truncate -s 16777216 "$G/resource.img"
"$RT" --unpack --image="$G/resource.img" "$G/v" >/dev/null 2>&1 || { echo "STOP: gsi verify unpack"; exit 3; }
cmp "$G/rk-kernel.dtb" "$G/v/rk-kernel.dtb" && cmp "$G/old/logo.bmp" "$G/v/logo.bmp" && cmp "$G/old/logo_kernel.bmp" "$G/v/logo_kernel.bmp" || { echo "STOP: gsi verify content"; exit 3; }
[ "$(xxd -p -l 4 "$G/resource.img")" = 52534345 ] || { echo "STOP: gsi no RSCE magic"; exit 3; }
cmp -s "$G/old/logo.bmp" "$W/old/logo.bmp" && cmp -s "$G/old/logo_kernel.bmp" "$W/old/logo_kernel.bmp" || { echo "STOP: logos differ from A11 resource"; exit 3; }
cp "$G/resource.img" "$GSIOUT"; cp "$G/rel.dts" "$B/resource-release-gsi.dts"
( cd $B && sha256sum resource-release-gsi.img > resource-release-gsi.img.sha256 && cat resource-release-gsi.img.sha256 )
