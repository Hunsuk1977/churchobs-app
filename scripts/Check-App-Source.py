"""Portable packaging/lexical check; never reports a Mac compile as passed."""
from pathlib import Path
import re
import subprocess
import plistlib
ROOT=Path(__file__).resolve().parent.parent
for path in (ROOT/'app').rglob('*'):
    if path.suffix not in {'.c','.h','.mm','.inc'}: continue
    text=path.read_text(); state='code';quote='';line=1;i=0
    while i<len(text):
        ch=text[i]; pair=text[i:i+2]
        if state=='code':
            if pair=='//':state='line';i+=1
            elif pair=='/*':state='comment';i+=1
            elif ch in '\"\'':state='literal';quote=ch
        elif state=='line':
            if ch=='\n':state='code'
        elif state=='comment':
            if pair=='*/':state='code';i+=1
        elif state=='literal':
            if ch=='\\':i+=1
            elif ch==quote:state='code'
            elif ch=='\n':raise SystemExit(f'{path}:{line}: newline in C/Objective-C literal')
        if ch=='\n':line+=1
        i+=1
    if state not in {'code','line'}:raise SystemExit(f'{path}: unclosed literal/comment')
for path in ROOT.rglob('*.command'):
    if 'vendor' in path.relative_to(ROOT).parts:continue
    subprocess.run(['bash','-n',str(path)],check=True)
plistlib.loads((ROOT/'app/resources/Info.plist.in').read_bytes())
if (ROOT/'app/resources/face-reference.bgra').stat().st_size!=640*480*4:
    raise SystemExit('face reference frame has wrong size')
print('PASS source literals, shell syntax, plist and reference frame size (not a Mac app compile)')
