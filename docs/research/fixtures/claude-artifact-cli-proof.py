from pathlib import Path
import argparse, subprocess, json, re, datetime, time
parser=argparse.ArgumentParser(description="Measure an isolated macOS CLI's Claude artifact writes")
parser.add_argument('--binary',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True,help='New directory for synthetic fixtures and evidence')
args=parser.parse_args()
root=args.output.resolve()
root.mkdir(parents=True,exist_ok=False)
binary=args.binary.resolve()
subprocess.run(['/usr/bin/clang','-dynamiclib','-O2',str(Path(__file__).with_name('claude-artifact-write-observer.c')),'-o',str(root/'cli-write-observer.dylib')],check=True)
results=[]
base=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).replace(hour=8,minute=0,second=0,microsecond=0)
def event(i):
 return json.dumps({'type':'assistant','timestamp':(base+datetime.timedelta(seconds=i)).isoformat().replace('+00:00','Z'),'requestId':f'request-{i}','message':{'id':f'message-{i}','model':'claude-sonnet-4-20250514','usage':{'input_tokens':10,'output_tokens':5}}},separators=(',',':'))+'\n'
def normalize(report):
 return [{k:v for k,v in p.items() if k!='updatedAt'} for p in report]
for full in (True,False):
 label='full' if full else 'clone'
 home=root/'cli-proof'/('full-home' if full else 'cow--home')
 projects=home/'.claude/projects';projects.mkdir(parents=True)
 source=projects/'fixture.jsonl';source.write_text(''.join(event(i) for i in range(24000)))
 (home/'config.json').write_text('{"version":1,"providers":[]}')
 env={'PATH':'/usr/bin:/bin','HOME':str(home),'CFFIXED_USER_HOME':str(home),'CLAUDE_CONFIG_DIR':str(home/'.claude'),'CODEXBAR_CONFIG':str(home/'config.json'),'CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS':'1','CODEXBAR_TEST_SESSION_FILE_ISOLATION':'1','CODEXBAR_TEST_CODEX_FILE_ISOLATION':'1','DYLD_INSERT_LIBRARIES':str(root/'cli-write-observer.dylib'),'TZ':'UTC'}
 if full: env['PROOF_FORCE_FULL_WRITES']='1'
 def run(cycle):
  r=subprocess.run([str(binary),'cost','--provider','claude','--format','json'],env=env,capture_output=True,text=True,timeout=90)
  if r.returncode: raise RuntimeError(f'{label} {cycle} exit {r.returncode}: {r.stderr}')
  report=json.loads(r.stdout);m=re.search(r'CLI_WRITE_PROOF submitted=(\d+) clones=(\d+)',r.stderr)
  assert m, r.stderr
  (home/f'output-{cycle}.json').write_text(r.stdout)
  (home/f'output-{cycle}.log').write_text(r.stderr)
  return normalize(report),int(m[1]),int(m[2])
 initial,_,_=run(0)
 assert initial[0]['totals']['totalTokens']==360000
 assert (home/'Library/Caches/CodexBar/cost-usage/claude-v6.json').exists()
 reports=[];submitted=clones=0;start=time.monotonic()
 for cycle in range(1,13):
  with source.open('a') as f: f.write(event(24000+cycle))
  report,writes,cloned=run(cycle)
  assert report[0]['totals']['totalTokens']==360000+15*cycle
  reports.append(report);submitted+=writes;clones+=cloned
  print(f'CLI_APPEND mode={label} cycle={cycle} submitted={writes} clones={cloned} tokens={360000+15*cycle}',flush=True)
 cold,coldbytes,coldclones=run(13)
 assert cold==reports[-1]
 print(f'CLI_SUMMARY mode={label} rows=24000 appends=12 submitted={submitted} clones={clones} coldSubmitted={coldbytes} coldMatches=true seconds={time.monotonic()-start:.2f}',flush=True)
 results.append({'mode':label,'submitted':submitted,'clones':clones,'coldSubmitted':coldbytes,'reports':reports})
assert results[0]['reports']==results[1]['reports']
assert results[1]['clones']>0
assert results[1]['submitted']*2<results[0]['submitted']
print(f'CLI_RESULT reportsMatch=true reductionPercent={100*(1-results[1]["submitted"]/results[0]["submitted"]):.2f}',flush=True)
(root/'cli-proof/results.json').write_text(json.dumps(results,indent=2))
