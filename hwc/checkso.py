#!/usr/bin/env python3
"""Check NEEDED subset + undefined symbol resolution of a built .so against vendor+GSI libs."""
import subprocess, sys, os, re
H='/run/media/leohearts/Data/rk3288-a11/hwc'
so=sys.argv[1] if len(sys.argv)>1 else H+'/out/hwcomposer.rk30board.so'
orig='/run/media/leohearts/Data/rk3288-a11/super2/work/tree5/vendor/lib/hw/hwcomposer.rk30board.so'
dirs=[ H+'/vendorlib', H+'/gsilib', '/home/leohearts/Android/Sdk/ndk/25.0.8775105/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/30']
def run(*a): return subprocess.check_output(a,text=True)
def needed(p): return re.findall(r'NEEDED.*\[(.*)\]', run('readelf','-d',p))
def undef(p):
    out=[]
    for l in run('readelf','--dyn-syms','-W',p).splitlines():
        f=l.split()
        if len(f)>=8 and f[6]=='UND' and f[7] not in ('',) and f[1]!='0000000000000000' or (len(f)>=8 and f[6]=='UND'):
            if f[7].strip(): out.append((f[7].split('@')[0], f[4]))
    return [s for s in out if s[0]]
def defined(p):
    s=set()
    for l in run('readelf','--dyn-syms','-W',p).splitlines():
        f=l.split()
        if len(f)>=8 and f[6]!='UND' and f[6]!='ABS' and f[4] in('GLOBAL','WEAK'): s.add(f[7].split('@')[0])
    return s
nd=needed(so); has_orig=os.path.exists(orig); no=needed(orig) if has_orig else []
print('NEEDED:', ' '.join(nd))
if has_orig: print('extra vs vendor:', [n for n in nd if n not in no], ' missing vs vendor:', [n for n in no if n not in nd])
else: print('vendor baseline missing; skipping NEEDED diff')
defs={}; 
for n in nd:
    for d in dirs:
        p=os.path.join(d,n)
        if os.path.exists(p):
            defs[n]=defined(p); break
    else: print('NOT FOUND', n)
unres=[]
for s,b in undef(so):
    if not any(s in v for v in defs.values()):
        if b=='WEAK': continue
        unres.append(s)
print('unresolved:',len(unres)); [print('  ',u) for u in unres]
# compare with vendor original's undefined
uo={s for s,b in undef(orig)} if has_orig else set(); un={s for s,b in undef(so)}
if has_orig:
    print('undef in ours not in vendor:', len(un-uo)); [print('  +',s) for s in sorted(un-uo)]
    print('undef in vendor not in ours:', len(uo-un)); [print('  -',s) for s in sorted(uo-un)]
