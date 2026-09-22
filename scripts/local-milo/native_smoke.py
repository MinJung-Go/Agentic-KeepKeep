#!/usr/bin/env python3
"""Exercise the actual app C bridge with real weights. Linux CPU evidence, not iPhone evidence."""
import argparse, ctypes as c, json, pathlib, time
p=argparse.ArgumentParser();p.add_argument('--library',required=True);p.add_argument('--models',required=True);p.add_argument('--image');p.add_argument('--prompt');p.add_argument('--output',required=True);a=p.parse_args()
lib=c.CDLL(a.library);pointer=c.c_void_p
lib.milo_cancel_create.restype=pointer
lib.milo_cancel_free.argtypes=[pointer]
lib.milo_engine_create.argtypes=[c.c_char_p,c.c_char_p,pointer];lib.milo_engine_create.restype=pointer
lib.milo_engine_free.argtypes=[pointer]
callback=c.CFUNCTYPE(None,pointer,c.c_size_t,pointer)
lib.milo_generate.argtypes=[pointer,c.c_char_p,pointer,c.c_size_t,c.c_int,c.c_float,pointer,callback,pointer,c.POINTER(c.c_int),c.POINTER(c.c_int)]
flag=lib.milo_cancel_create();started=time.monotonic();models=pathlib.Path(a.models)
engine=lib.milo_engine_create(str(models/'Qwen3.5-2B-Q4_K_M.gguf').encode(),str(models/'mmproj-F16.gguf').encode(),flag)
assert engine, 'model/vision initialization failed'
results={'environment':'Linux CPU; not iPhone or Metal','load_seconds':time.monotonic()-started,'cases':[]}
try:
 cases=[('identity','你叫 Milo，是 Moveliq 的运动伙伴。用户姓名未知。中文简短回答。','你叫什么名字？',None),('json','只输出JSON。把训练解析为 exercise、kg、sets、reps。','深蹲 100kg，5组，每组5次',None)]
 if a.prompt: cases.extend([('app-tools', '', '', None), ('app-followup', '', '', None)])
 if a.image: cases.append(('vision','读取图片，用中文简短回答。','<__media__>图片上写了什么？',pathlib.Path(a.image).read_bytes()))
 for name,system,user,image in cases:
  prompt=f'<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'
  if name == 'app-tools': prompt=pathlib.Path(a.prompt).read_text()
  if name == 'app-followup':
   previous=next(x['text'] for x in results['cases'] if x['name']=='app-tools')
   prompt=pathlib.Path(a.prompt).read_text()+previous+'<|im_end|>\n<|im_start|>user\n<tool_response>\n本机隔离测试数据：今天步数 4321，已同步；其他指标未授权，无数据不代表零。\n</tool_response><|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n'

  chunks=[]; first=[];begin=time.monotonic()
  @callback
  def receive(data,size,context):
   if not first:first.append(time.monotonic()-begin)
   chunks.append(c.string_at(data,size))
  inputs=c.c_int();outputs=c.c_int();buf=c.create_string_buffer(image) if image else None
  status=lib.milo_generate(engine,prompt.encode(),buf,len(image or b''),128,0,flag,receive,None,c.byref(inputs),c.byref(outputs))
  entry={'name':name,'status':status,'input_tokens':inputs.value,'output_tokens':outputs.value,'first_piece_seconds':first[0] if first else None,'elapsed_seconds':time.monotonic()-begin,'text':b''.join(chunks).decode()}
  results['cases'].append(entry);print(json.dumps(entry,ensure_ascii=False),flush=True)
  assert status==0,entry
  if name=='identity': assert 'Milo' in entry['text']
  if name=='json': assert json.loads(entry['text'])=={'exercise':'深蹲','kg':100,'sets':5,'reps':5}
  if name=='app-tools': assert '<function=query_local_records>' in entry['text'] and 'health' in entry['text']
  if name=='app-followup': assert '4321' in entry['text'] or '4,321' in entry['text']
  if name=='vision': assert '250' in entry['text'] and '12' in entry['text']
  entry['smoke_assertions_passed']=True
finally:
 lib.milo_engine_free(engine);lib.milo_cancel_free(flag)
 pathlib.Path(a.output).write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
