import subprocess,sys,re
img=sys.argv[1]; root=sys.argv[2] if len(sys.argv)>2 else '/'
rx=re.compile(r'^\s*(\d+)\s+(\d+)\s+\((\d+)\)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+-\w+-(\d+))\s+(\d+:\d+)\s+(.+)$')
stack=[root]
while stack:
    d=stack.pop()
    out=subprocess.run(['debugfs','-R','ls -l %s'%d,img],capture_output=True,text=True).stdout
    for l in out.splitlines():
        m=rx.match(l)
        if not m: continue
        name=m.group(10); mode=m.group(2); year=m.group(8)
        if name in('.','..'): continue
        p=d.rstrip('/')+'/'+name
        if mode.startswith('4'): stack.append(p)
        if year=='2026': print(m.group(7),m.group(9),mode,p)
