#!/usr/bin/env python3
"""Run every fixed case three times against real weights; raw first-turn evidence only.
Does not simulate SwiftData writes, certify tool execution, or assign subjective quality scores.
"""
import argparse,ctypes as c,concurrent.futures,json,pathlib,time,os,hashlib

def run_shard(args, shard):
 lib=c.CDLL(args.library);P=c.c_void_p
 lib.milo_cancel_create.restype=P
 lib.milo_cancel_free.argtypes=[P];lib.milo_engine_free.argtypes=[P]
 lib.milo_engine_create.argtypes=[c.c_char_p,c.c_char_p,P];lib.milo_engine_create.restype=P
 callback=c.CFUNCTYPE(None,P,c.c_size_t,P)
 lib.milo_generate.argtypes=[P,c.c_char_p,P,c.c_size_t,c.c_int,c.c_float,P,callback,P,c.POINTER(c.c_int),c.POINTER(c.c_int)]
 flag=lib.milo_cancel_create();model=pathlib.Path(args.models)
 engine=lib.milo_engine_create(str(model/'Qwen3.5-2B-Q4_K_M.gguf').encode(),str(model/'mmproj-F16.gguf').encode(),flag)
 assert engine
 path=pathlib.Path(args.output)/f'shard-{shard}.jsonl'
 try:
  cases=[json.loads(line) for line in pathlib.Path(args.prompts).read_text().splitlines()]
  with path.open('w') as out:
   for index,case in enumerate(cases):
    if index%args.workers!=shard:continue
    raw=pathlib.Path(args.fixtures,case['image']).read_bytes() if case.get('image') else b''
    buf=c.create_string_buffer(raw) if raw else None
    for iteration in range(3):
     chunks=[];first=[];start=time.monotonic()
     @callback
     def receive(data,size,context):
      if not first:first.append(time.monotonic()-start)
      chunks.append(c.string_at(data,size))
     inputs=c.c_int();outputs=c.c_int()
     status=lib.milo_generate(engine,case['prompt'].encode(),buf,len(raw),1024,0.1,flag,receive,None,c.byref(inputs),c.byref(outputs))
     text=b''.join(chunks).decode('utf-8',errors='replace')
     item=dict(case_id=case['id'],category=case['category'],run=iteration+1,status=status,input_tokens=inputs.value,output_tokens=outputs.value,first_piece_seconds=first[0] if first else None,total_seconds=time.monotonic()-start,text=text,template_sha256=hashlib.sha256(case['prompt'].encode()).hexdigest(),manual_pass=None,scope='first turn only; no database/tool execution')
     if case['category'] in ['parse','vision']:
      try:json.loads(text);item['valid_json']=True
      except ValueError:item['valid_json']=False
     out.write(json.dumps(item,ensure_ascii=False)+'\n');out.flush()
     print(case['id'],iteration+1,status,flush=True)
 finally:lib.milo_engine_free(engine);lib.milo_cancel_free(flag)
 return str(path)
if __name__=='__main__':
 p=argparse.ArgumentParser()
 for name in ['library','models','prompts','fixtures','output']:p.add_argument('--'+name,required=True)
 p.add_argument('--workers',type=int,default=1);a=p.parse_args();pathlib.Path(a.output).mkdir(parents=True,exist_ok=True)
 with concurrent.futures.ProcessPoolExecutor(max_workers=a.workers) as pool:
  paths=list(pool.map(run_shard,[a]*a.workers,range(a.workers)))
 rows=[json.loads(line) for path in paths for line in pathlib.Path(path).read_text().splitlines()]
 rows.sort(key=lambda x:(x['case_id'],x['run']))
 pathlib.Path(a.output,'results.jsonl').write_text(''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in rows))
 print('Completed',len(rows),'real first-turn generations. Manual quality and full tool chains remain separate.')
