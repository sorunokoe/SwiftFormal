import re,sys
def funcs(p):
    d={};cur=None;buf=[]
    for l in open(p,encoding='utf-8'):
        if cur is None:
            if l.startswith('sil ') and l.rstrip().endswith('{'):
                cur=re.search(r' @(\S+) : ',l).group(1);buf=[]
        else:
            if l.startswith('}'): d[cur]=buf;cur=None
            else:
                l=re.sub(r', loc .*?(?=( //|$))','',l.rstrip()); l=re.sub(r', scope \d+','',l); l=re.sub(r'\s*//.*$','',l)
                buf.append(l)
    return d
p=sys.argv[1]
a=funcs(p+'-Debug.sil'); b=funcs(p+'-Release.sil'); c=funcs(p+'-DisableReplacement.sil')
diff=[s for s in a if s in b and a[s]!=b[s]]
withbi=[s for s in c if any('assert_configuration' in l for l in c[s])]
print('functions',len(a),len(b),len(c),'| differ Debug/Release',len(diff),'| contain assert_configuration in DR',len(withbi))
print('differ but no builtin:',[s for s in diff if s not in withbi][:10])
print('builtin but no differ:',len([s for s in withbi if s not in diff]))
print('only in one: D^R',len(set(a)^set(b)),' D^DR', len(set(a)^set(c)), sorted(set(c)-set(a))[:5])
