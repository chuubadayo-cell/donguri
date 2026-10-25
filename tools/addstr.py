import json,sys
cat_path,new_path=sys.argv[1],sys.argv[2]
cat=json.load(open(cat_path,encoding='utf-8')); st=cat['strings']
new=json.load(open(new_path,encoding='utf-8'))
n=0
for k,v in new.items():
    if k in st and st[k].get('localizations'): continue
    st[k]={"localizations":{"en":{"stringUnit":{"state":"translated","value":v}},"ja":{"stringUnit":{"state":"translated","value":k}}}}
    n+=1
cat['strings']=dict(sorted(st.items()))
with open(cat_path,'w',encoding='utf-8') as f:
    json.dump(cat,f,ensure_ascii=False,indent=2,separators=(",", " : ")); f.write("\n")
print("added",n)
