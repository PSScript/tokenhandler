import os, requests, threading, time, json, sys
from concurrent.futures import ThreadPoolExecutor
from math import sqrt, log
TENANT=os.environ.get('GRAPH_TENANT_ID','<TENANT-ID>'); MBX=os.environ.get('GRAPH_MAILBOX','<mailbox@example.com>')
APPID=os.environ.get('GRAPH_APP_ID','<APP-ID>'); SECRET=os.environ.get('GRAPH_APP_SECRET','')
try:
    r=requests.post(f'https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token',
        data={'client_id':APPID,'client_secret':SECRET,'scope':'https://graph.microsoft.com/.default','grant_type':'client_credentials'},timeout=20)
    if r.status_code!=200: print("TOKEN_FAIL",r.status_code,r.text[:200]); sys.exit(2)
    TOKEN=r.json()['access_token']; print("TOKEN_OK",flush=True)
except Exception as e: print("NETWORK_FAIL",repr(e)[:200]); sys.exit(3)
sess=requests.Session(); sess.mount('https://',requests.adapters.HTTPAdapter(pool_connections=256,pool_maxsize=256))
URI=f'https://graph.microsoft.com/v1.0/users/{MBX}/mailFolders/inbox/messages?$top=25&$select=id,subject,body,receivedDateTime&$orderby=receivedDateTime desc'
HDR={'Authorization':f'Bearer {TOKEN}',"Prefer":"IdType='ImmutableId'",'Accept':'application/json'}
def burst(n):
    bar=threading.Barrier(n); res=[]; lk=threading.Lock()
    def one():
        try: bar.wait(timeout=10)
        except: pass
        t0=time.time()
        try:
            rr=sess.get(URI,headers=HDR,timeout=40); sc=rr.status_code; ra=rr.headers.get('Retry-After'); bd=(rr.text[:160] if sc>=400 else '')
        except Exception as e: sc=0; ra=None; bd=repr(e)[:80]
        dt=(time.time()-t0)*1000
        with lk: res.append((sc,ra,bd,dt))
    with ThreadPoolExecutor(max_workers=n) as ex: [ex.submit(one) for _ in range(n)]
    ok=conc=rate=e503=fail=0; ramax=0.0; lat=[]
    for sc,ra,bd,dt in res:
        lat.append(dt)
        if sc and sc<300: ok+=1
        elif sc in (429,503,504):
            rav=0.0
            if ra:
                try: rav=float(ra)
                except: rav=0.0
            ramax=max(ramax,rav)
            if sc in (503,504): e503+=1
            elif rav>0 or 'rate' in bd.lower(): rate+=1
            else: conc+=1
        else: fail+=1
    return dict(n=n,ok=ok,conc=conc,rate=rate,e503=e503,fail=fail,ramax=ramax,lat=lat,thr=(conc+rate+e503)>0)
def wilson(k,n,z=1.959964):
    if n==0: return 0,0,0
    p=k/n; z2=z*z; d=1+z2/n; c=(p+z2/(2*n))/d; h=(z*sqrt((p*(1-p)+z2/(4*n))/n))/d; return p,max(0,c-h),min(1,c+h)
def meansd(x):
    n=len(x); m=sum(x)/n if n else 0; sd=0.0 if n<2 else sqrt(sum((v-m)**2 for v in x)/(n-1)); return m,sd
TT={1:12.706,2:4.303,3:3.182,4:2.776,5:2.571,6:2.447,7:2.365,8:2.306,9:2.262,10:2.228}
MINN,MAXN,SW,CD=1,8,6,0.2; thr={n:0 for n in range(MINN,MAXN+1)}; latn={n:[] for n in range(MINN,MAXN+1)}
bnd=[]; cool=[]  # (consecutive_throttle_index, retry_after)
print(f"SWEEP N={MINN}..{MAXN} x{SW}",flush=True)
for k in range(1,SW+1):
    first=0; consec=0
    for n in range(MINN,MAXN+1):
        b=burst(n); latn[n].extend(b['lat'])
        if b['thr']:
            thr[n]+=1; consec+=1
            if b['ramax']>0: cool.append((consec,b['ramax']))
            if first==0: first=n
        else: consec=0
        if b['ramax']>0: time.sleep(min(8,b['ramax']))
        time.sleep(CD)
    bnd.append(first if first else MAXN+1)
    print(f"  sweep {k}: first-throttle={first if first else '>'+str(MAXN)}",flush=True)
bm,bsd=meansd(bnd); tc=TT.get(len(bnd)-1,1.96); se=bsd/sqrt(len(bnd)) if len(bnd)>1 else 0
blo,bhi=bm-tc*se,bm+tc*se; cens=sum(1 for x in bnd if x==MAXN+1)
levels=[]
for n in range(MINN,MAXN+1):
    p,lo,hi=wilson(thr[n],SW); la=sorted(latn[n]); p50=la[len(la)//2] if la else 0; p95=la[min(len(la)-1,int(len(la)*0.95))] if la else 0
    levels.append(dict(N=n,p=p,lo=lo,hi=hi,p50=round(p50),p95=round(p95),good=round(n*(1-p),2)))
peak=max(levels,key=lambda l:l['good'])
print("=== ERGEBNIS ===",flush=True)
for l in levels: print(f"  N={l['N']} p={l['p']:.0%} CI=[{l['lo']:.0%},{l['hi']:.0%}] p50={l['p50']}ms p95={l['p95']}ms good={l['good']}",flush=True)
print(f"Grenze N* Mittel={bm:.2f} SD={bsd:.2f} CI=[{blo:.2f},{bhi:.2f}] bnd={bnd} zensiert={cens}",flush=True)
print(f"Effizienz-Peak N={peak['N']}",flush=True)
print(f"Cooloff-Datenpunkte (consec,RA)={cool}",flush=True)
json.dump(dict(bnd=bnd,bm=bm,bsd=bsd,blo=blo,bhi=bhi,peakN=peak['N'],cens=cens,levels=levels,cool=cool),open('/tmp/real_calib.json','w'),indent=2)
print("DONE",flush=True)
