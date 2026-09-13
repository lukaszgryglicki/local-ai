#!/usr/bin/env python3
# Replace the §2.4 scoreboard table in results-t1.md with the current scoreboard.py output for the given models.
import subprocess, sys, re
p='/data/local-ai/asgard/results-t1.md'; s=open(p).read()
models=sys.argv[1:] or ['qwen35b-q4']
tbl=subprocess.check_output(['python3','/data/local-ai/asgard/scoreboard.py']+models,text=True).strip()+'\n'
a=s.index('### 2.4 '); b=s.index('\n## 3. ',a)
sec=s[a:b]
lines=sec.split('\n')
i=[k for k,l in enumerate(lines) if l.startswith('| model | task |')][0]
j=i
while j<len(lines) and lines[j].startswith('|'): j+=1
new='\n'.join(lines[:i])+'\n'+tbl+'\n'.join(lines[j:])
s=s[:a]+new+s[b:]
open(p,'w').write(s); print('table replaced', i, j)
