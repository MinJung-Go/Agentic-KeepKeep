#!/usr/bin/env python3
"""Report narrow, reproducible checks. Never label first-turn checks end-to-end quality."""
import argparse,collections,datetime,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--results',required=True);p.add_argument('--cases',required=True);p.add_argument('--output',required=True);a=p.parse_args()
rows=[json.loads(l) for l in pathlib.Path(a.results).read_text().splitlines()]
cases={x['id']:x for x in map(json.loads,pathlib.Path(a.cases).read_text().splitlines())}
def parse_ok(row):
 try:
  expected=cases[row['case_id']]['expected'];result=json.loads(row['text']);records=result.get('records',[]) if isinstance(result,dict) else result
  if len(records)!=1:return False
  record=records[0]
  if record.get('type',record.get('kind'))!=expected['type']:return False
  if expected['type']=='workout':
   workout=record['workout'];exercise=workout['exercises'][0]
   return len(workout['exercises'])==1 and expected['exercise'] in exercise['name'] and all(float(exercise[k])==expected[v] for k,v in [('weightKg','kg'),('sets','sets'),('reps','reps')]) and workout.get('rpe') is None
  if expected['type']=='meal':
   foods=record['meal']['items'];return len(foods)==1 and expected['name'] in foods[0]['name'] and float(foods[0]['calories'])==expected['calories']
  if expected['type']=='metric':return record['metric']['kind']==expected['kind'] and float(record['metric']['value'])==expected['value']
  return record['note']==expected['must_preserve']
 except (ValueError,TypeError,KeyError,IndexError):return False
def query_ok(row):
 expected=cases[row['case_id']]['expected'];relative=expected['relative_date']
 if relative=='明天':return None # Future-date behavior requires tool executor and error handling.
 today=datetime.date(2026,9,18);start=end=today
 if relative=='昨天':start=end=today-datetime.timedelta(days=1)
 if relative=='最近七天':start=today-datetime.timedelta(days=6)
 try:
  for tool in row.get('validated_tools',[]):
   args=json.loads(tool['arguments'])
   if tool['name']=='query_local_records' and args.get('kind')==expected['kind'] and args.get('start_date')==str(start) and args.get('end_date')==str(end):return True
 except (ValueError,TypeError):pass
 return False
scores={}
for row in rows:
 if row['category']=='parse':row['automatic_fields_pass']=row['status']==0 and parse_ok(row)
 elif row['category']=='query':row['automatic_query_parameters_pass']=query_ok(row)
for category in sorted(set(x['category'] for x in rows)):
 values=[x for x in rows if x['category']==category]
 scores[category]={'runs':len(values),'completed_generation':sum(x['status']==0 for x in values),'tool_format_rejections':sum('parse_error' in x for x in values)}
 if category in ['parse','vision']:scores[category]['valid_json']=sum(x.get('valid_json',False) for x in values)
 if category=='parse':scores[category]['key_fields_and_no_extra_record_or_rpe']=sum(x['automatic_fields_pass'] for x in values)
 if category=='query':
  scores[category]['past_or_today_parameter_checks']=sum(x['automatic_query_parameters_pass'] is not None for x in values)
  scores[category]['correct_parameters']=sum(x['automatic_query_parameters_pass'] is True for x in values)
report={'environment':'Linux CPU, six concurrent workers; timings not iPhone performance','scope':'First-turn generations only. No SwiftData execution, confirmation, full tool loops or final-fact scoring. Synthetic diagrams are not real meal photos.','parameters':{'temperature':0.1,'seed':42,'output_limit':1024,'context':8192,'repetitions':3},'independence':'Repeated fixed-seed outputs are not independent statistical samples.','counts':scores,'manual_quality_gate':'NOT PASSED; known missing-data, identity, fabricated fields and date errors.','examples_requiring_review':['chat-05 interprets no records as no activity','chat-11 invents personal training weaknesses','chat-12 calls user Milo','query-02 yesterday range includes today']}
pathlib.Path(a.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
